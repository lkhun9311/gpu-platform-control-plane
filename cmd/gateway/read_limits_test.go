/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

// startAPIServer serves h through newAPIServer on a loopback listener and returns its address.
func startAPIServer(t *testing.T, h http.Handler, readHeader, read time.Duration) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := newAPIServer("", h, readHeader, read)
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	return ln.Addr().String()
}

// TestAPIServerKeepsAStreamLongerThanItsReadTimeout pins what the read limit must not do.
// The gateway's whole job is proxying generations that stream for minutes, so a read timeout that ended the
// request context or the connection once the request had been read would cut every one of them.
// Go 1.26 does not, and this test is what notices if a later Go or a later edit makes it so.
func TestAPIServerKeepsAStreamLongerThanItsReadTimeout(t *testing.T) {
	const chunks = 8
	read := 200 * time.Millisecond
	cancelled := make(chan struct{}, 1)
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		for range chunks {
			select {
			case <-r.Context().Done():
				cancelled <- struct{}{}
				return
			case <-time.After(read / 2):
			}
			_, _ = io.WriteString(w, "x")
			w.(http.Flusher).Flush()
		}
	})
	addr := startAPIServer(t, h, read, read)

	resp, err := http.Post("http://"+addr+"/", "application/json", strings.NewReader(`{"model":"m"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(resp.Body)
	if err != nil || len(b) != chunks {
		t.Fatalf("a %v stream behind a %v read timeout ended with %d of %d chunks, err %v",
			time.Duration(chunks)*read/2, read, len(b), chunks, err)
	}
	select {
	case <-cancelled:
		t.Fatal("the request context was cancelled while the response was still streaming")
	default:
	}
}

// TestAPIServerClosesAConnectionThatNeverFinishesItsHeaders pins the limit itself: without ReadHeaderTimeout a
// client that sends half a request line and stops holds the connection open indefinitely.
func TestAPIServerClosesAConnectionThatNeverFinishesItsHeaders(t *testing.T) {
	readHeader := 200 * time.Millisecond
	addr := startAPIServer(t, http.NotFoundHandler(), readHeader, time.Minute)

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	if _, err := io.WriteString(conn, "POST / HTTP/1.1\r\nHost: gw\r\n"); err != nil {
		t.Fatal(err)
	}
	// The client's own deadline is far past the server's, so a read that ends early was ended by the server.
	if err := conn.SetReadDeadline(time.Now().Add(20 * readHeader)); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	_, err = io.ReadAll(conn)
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatalf("the connection was still open after %v with its headers unfinished", time.Since(start))
	}
}
