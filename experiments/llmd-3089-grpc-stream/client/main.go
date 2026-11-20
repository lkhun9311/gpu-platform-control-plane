// Command client drives the llm-d#3089 backend and prints one JSON line per call.
//
// In stream mode it calls StreamingOutputCall from -c concurrent goroutines.
// ttfm_ms is the time from the call to the first message.
// gaps_ms are the times between consecutive messages as the client received them.
// lag_ms is receive time minus the backend's send time, per message.
// before_done is the fraction of messages 1..n-1 received before the backend sent message n.
// Client and backend run on one kind node, so both read the same kernel clock.
//
// In unary mode it calls UnaryCall and prints digests of the response message, headers and trailers.
// In json mode it sends -requests POSTs per worker to /v1/chat/completions and prints one line per worker.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	testpb "google.golang.org/grpc/interop/grpc_testing"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
)

type result struct {
	Arm        string    `json:"arm"`
	Run        int       `json:"run"`
	C          int       `json:"c"`
	Worker     int       `json:"worker"`
	N          int       `json:"n"`
	TTFMms     float64   `json:"ttfm_ms"`
	TotalMs    float64   `json:"total_ms"`
	GapsMs     []float64 `json:"gaps_ms"`
	LagMs      []float64 `json:"lag_ms"`
	BeforeDone float64   `json:"before_done"`
	Err        string    `json:"err,omitempty"`
}

type unaryResult struct {
	Arm           string `json:"arm"`
	Run           int    `json:"run"`
	MessageSHA256 string `json:"message_sha256"`
	MessageBytes  int    `json:"message_bytes"`
	Header        string `json:"x_backend_header"`
	Trailer       string `json:"x_backend_trailer"`
	Err           string `json:"err,omitempty"`
}

type jsonResult struct {
	Arm       string    `json:"arm"`
	Run       int       `json:"run"`
	C         int       `json:"c"`
	Worker    int       `json:"worker"`
	OK        int       `json:"ok"`
	Bad       int       `json:"bad"`
	LatencyMs []float64 `json:"latency_ms"`
	BodySHA   string    `json:"body_sha256"`
	Err       string    `json:"err,omitempty"`
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func streamOnce(c testpb.TestServiceClient, n int, interval time.Duration) result {
	params := make([]*testpb.ResponseParameters, n)
	for i := range params {
		params[i] = &testpb.ResponseParameters{IntervalUs: int32(interval.Microseconds())}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	var res result
	var recv []time.Time
	var sent []time.Time
	start := time.Now()
	stream, err := c.StreamingOutputCall(ctx, &testpb.StreamingOutputCallRequest{ResponseParameters: params})
	if err == nil {
		var last time.Time
		for {
			msg, rerr := stream.Recv()
			if rerr == io.EOF {
				break
			}
			if rerr != nil {
				err = rerr
				break
			}
			now := time.Now()
			if res.N == 0 {
				res.TTFMms = ms(now.Sub(start))
			} else {
				res.GapsMs = append(res.GapsMs, ms(now.Sub(last)))
			}
			if ns, perr := strconv.ParseInt(string(msg.GetPayload().GetBody()), 10, 64); perr == nil {
				s := time.Unix(0, ns)
				res.LagMs = append(res.LagMs, ms(now.Sub(s)))
				sent = append(sent, s)
				recv = append(recv, now)
			}
			last = now
			res.N++
		}
	}
	res.TotalMs = ms(time.Since(start))
	if len(sent) >= 2 {
		done := sent[len(sent)-1]
		early := 0
		for _, r := range recv[:len(recv)-1] {
			if r.Before(done) {
				early++
			}
		}
		res.BeforeDone = float64(early) / float64(len(recv)-1)
	}
	if err != nil {
		res.Err = err.Error()
	}
	return res
}

func unaryOnce(c testpb.TestServiceClient, size int) unaryResult {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var header, trailer metadata.MD
	var res unaryResult
	resp, err := c.UnaryCall(ctx, &testpb.SimpleRequest{ResponseSize: int32(size)}, grpc.Header(&header), grpc.Trailer(&trailer))
	if err != nil {
		res.Err = err.Error()
		return res
	}
	wire, err := proto.Marshal(resp)
	if err != nil {
		res.Err = err.Error()
		return res
	}
	sum := sha256.Sum256(wire)
	res.MessageSHA256 = hex.EncodeToString(sum[:])
	res.MessageBytes = len(wire)
	res.Header = firstOf(header.Get("x-backend-header"))
	res.Trailer = firstOf(trailer.Get("x-backend-trailer"))
	return res
}

func firstOf(v []string) string {
	if len(v) == 0 {
		return ""
	}
	return v[0]
}

func jsonWorker(client *http.Client, url string, requests int) jsonResult {
	var res jsonResult
	body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
	for range requests {
		start := time.Now()
		resp, err := client.Post(url, "application/json", bytes.NewReader(body))
		if err != nil {
			res.Bad++
			res.Err = err.Error()
			continue
		}
		got, rerr := io.ReadAll(resp.Body)
		resp.Body.Close()
		if rerr != nil || resp.StatusCode != http.StatusOK {
			res.Bad++
			res.Err = fmt.Sprintf("status %d err %v", resp.StatusCode, rerr)
			continue
		}
		sum := sha256.Sum256(got)
		digest := hex.EncodeToString(sum[:])
		if res.BodySHA != "" && res.BodySHA != digest {
			res.Bad++
			res.Err = "response body changed between requests"
			continue
		}
		res.BodySHA = digest
		res.OK++
		res.LatencyMs = append(res.LatencyMs, ms(time.Since(start)))
	}
	return res
}

func main() {
	target := flag.String("target", "localhost:50051", "host:port")
	mode := flag.String("mode", "stream", "stream, unary or json")
	arm := flag.String("arm", "", "arm label")
	run := flag.Int("run", 0, "run index")
	conc := flag.Int("c", 1, "concurrent calls")
	n := flag.Int("n", 18, "messages per stream")
	interval := flag.Duration("interval", 80*time.Millisecond, "backend send interval")
	size := flag.Int("size", 100_000, "unary response payload bytes")
	requests := flag.Int("requests", 50, "JSON requests per worker")
	flag.Parse()

	enc := json.NewEncoder(os.Stdout)
	failed := false
	if *mode == "json" {
		transport := &http.Transport{MaxIdleConnsPerHost: *conc}
		client := &http.Client{Transport: transport, Timeout: 30 * time.Second}
		results := make([]jsonResult, *conc)
		var wg sync.WaitGroup
		for w := range *conc {
			wg.Go(func() { results[w] = jsonWorker(client, "http://"+*target+"/v1/chat/completions", *requests) })
		}
		wg.Wait()
		for w, r := range results {
			r.Arm, r.Run, r.C, r.Worker = *arm, *run, *conc, w
			failed = failed || r.Bad > 0
			_ = enc.Encode(r)
		}
		exit(failed)
	}

	conn, err := grpc.NewClient(*target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	c := testpb.NewTestServiceClient(conn)

	if *mode == "unary" {
		r := unaryOnce(c, *size)
		r.Arm, r.Run = *arm, *run
		_ = enc.Encode(r)
		exit(r.Err != "")
	}

	results := make([]result, *conc)
	var wg sync.WaitGroup
	for w := range *conc {
		wg.Go(func() { results[w] = streamOnce(c, *n, *interval) })
	}
	wg.Wait()
	for w, r := range results {
		r.Arm, r.Run, r.C, r.Worker = *arm, *run, *conc, w
		failed = failed || r.Err != ""
		_ = enc.Encode(r)
	}
	exit(failed)
}

func exit(failed bool) {
	if failed {
		os.Exit(1)
	}
	os.Exit(0)
}
