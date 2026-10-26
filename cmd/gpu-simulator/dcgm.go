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
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The fake DCGM is the kind rehearsal's stand-in for the two halves of DCGM the fault-reaction study touches
// (docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md): a field cache that `dcgmi test --inject`
// writes and `--introspect` reads, and a dcgm-exporter that serves a snapshot of that cache taken once per
// collection period.
//
// It is off unless FAKE_DCGM_ADDR is set, so the device plugin every other study runs is unchanged.
// What it does not model is said here rather than discovered later: there is no NVML, so nothing ever writes a
// field except an injection, and an injected value therefore persists whatever its offset; on a real card the
// smoke cell is what shows whether it does.

// fakeDCGMFields are the fields the fake knows, by DCGM field ID (dcgmlib/dcgm_fields.h) and exporter name.
var fakeDCGMFields = map[int]string{
	230: "DCGM_FI_DEV_XID_ERRORS",
	310: "DCGM_FI_DEV_ECC_SBE_VOL_TOTAL",
	311: "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL",
}

type fakeDCGMKey struct{ gpu, field int }

type fakeDCGMSample struct {
	value int64
	// at is the sample's DCGM timestamp: the injection time plus its offset, as dcgmi's --offset sets it.
	at time.Time
}

// fakeDCGM holds the cache and the exporter's last snapshot.
type fakeDCGM struct {
	mu       sync.Mutex
	hostname string
	gpus     int
	cache    map[fakeDCGMKey]fakeDCGMSample
	snapshot []byte
	now      func() time.Time
	// down makes /metrics answer 503, as an exporter that has gone away would leave its scraper failing.
	down bool
}

func newFakeDCGM(hostname string, gpus int, now func() time.Time) *fakeDCGM {
	d := &fakeDCGM{hostname: hostname, gpus: gpus, cache: map[fakeDCGMKey]fakeDCGMSample{}, now: now}
	for g := range gpus {
		for f := range fakeDCGMFields {
			d.cache[fakeDCGMKey{g, f}] = fakeDCGMSample{value: 0, at: now()}
		}
	}
	d.collect()
	return d
}

// inject writes a sample the way dcgmInjectFieldValue does, and keeps whichever sample is newest by timestamp.
//
// Newest by timestamp, not last written, is the reading the registration's fixed 900 s offset rests on; the
// fake implements that reading so that the runner's offsets are exercised, not so that it is confirmed.
func (d *fakeDCGM) inject(gpu, field int, value int64, offset time.Duration) error {
	if _, ok := fakeDCGMFields[field]; !ok {
		return fmt.Errorf("field %d is not one the fake knows", field)
	}
	if gpu < 0 || gpu >= d.gpus {
		return fmt.Errorf("gpu %d does not exist; this node has %d", gpu, d.gpus)
	}
	if value < 0 {
		return fmt.Errorf("value %d is negative", value)
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	s := fakeDCGMSample{value: value, at: d.now().Add(offset)}
	k := fakeDCGMKey{gpu, field}
	if cur, ok := d.cache[k]; ok && cur.at.After(s.at) {
		return fmt.Errorf("an existing sample at %s is newer than this one at %s, so the cache would not show it",
			cur.at.Format(time.RFC3339Nano), s.at.Format(time.RFC3339Nano))
	}
	d.cache[k] = s
	return nil
}

func (d *fakeDCGM) introspect(gpu, field int) (int64, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	s, ok := d.cache[fakeDCGMKey{gpu, field}]
	return s.value, ok
}

// collect takes the exporter's snapshot, as dcgm-exporter does once per collection interval.
func (d *fakeDCGM) collect() {
	d.mu.Lock()
	defer d.mu.Unlock()
	ids := make([]int, 0, len(fakeDCGMFields))
	for f := range fakeDCGMFields {
		ids = append(ids, f)
	}
	sort.Ints(ids)
	var b strings.Builder
	for _, f := range ids {
		name := fakeDCGMFields[f]
		fmt.Fprintf(&b, "# HELP %s fake DCGM field %d.\n# TYPE %s gauge\n", name, f, name)
		for g := range d.gpus {
			fmt.Fprintf(&b, "%s{gpu=\"%d\",UUID=\"fake-gpu-%d\",device=\"nvidia%d\",modelName=\"gpu-simulator\",Hostname=%q} %d\n",
				name, g, g, g, d.hostname, d.cache[fakeDCGMKey{g, f}].value)
		}
	}
	d.snapshot = []byte(b.String())
}

func (d *fakeDCGM) isDown() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.down
}

func (d *fakeDCGM) setDown(down bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.down = down
}

func (d *fakeDCGM) metrics() []byte {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.snapshot
}

// ServeHTTP is the exporter's /metrics and the two dcgmi verbs the study uses.
//
// POST /inject?gpu=G&field=F&value=V[&offset=S] and GET /introspect?gpu=G&field=F, each answering one line.
func (d *fakeDCGM) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	intArg := func(name string, def int64, required bool) (int64, error) {
		raw := q.Get(name)
		if raw == "" {
			if required {
				return 0, fmt.Errorf("%s is required", name)
			}
			return def, nil
		}
		return strconv.ParseInt(raw, 10, 64)
	}
	switch r.URL.Path {
	case "/metrics":
		if d.isDown() {
			http.Error(w, "the fake exporter is down", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write(d.metrics())
	case "/exporter":
		// The stale-signal checks take the exporter away while the operator runs; on a real node that is the
		// exporter Pod leaving, here it is this switch, so the device plugin keeps the node's capacity meanwhile.
		state := q.Get("state")
		if r.Method != http.MethodPost || (state != "up" && state != "down") {
			http.Error(w, "POST /exporter?state=up|down", http.StatusBadRequest)
			return
		}
		d.setDown(state == "down")
		_, _ = fmt.Fprintf(w, "exporter %s\n", state)
	case "/health":
		_, _ = w.Write([]byte("ok\n"))
	case "/inject":
		if r.Method != http.MethodPost {
			http.Error(w, "inject writes the cache; POST it", http.StatusMethodNotAllowed)
			return
		}
		gpu, err1 := intArg("gpu", 0, true)
		field, err2 := intArg("field", 0, true)
		value, err3 := intArg("value", 0, true)
		// dcgmi's own default offset is 1 s.
		offset, err4 := intArg("offset", 1, false)
		if err := errors.Join(err1, err2, err3, err4); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := d.inject(int(gpu), int(field), value, time.Duration(offset)*time.Second); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		_, _ = fmt.Fprintf(w, "injected gpu=%d field=%d value=%d offset=%d\n", gpu, field, value, offset)
	case "/introspect":
		gpu, err1 := intArg("gpu", 0, true)
		field, err2 := intArg("field", 0, true)
		if err := errors.Join(err1, err2); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		v, ok := d.introspect(int(gpu), int(field))
		if !ok {
			http.Error(w, "no such gpu or field", http.StatusNotFound)
			return
		}
		_, _ = fmt.Fprintf(w, "%d\n", v)
	default:
		http.NotFound(w, r)
	}
}

// fakeDCGMConfig reads FAKE_DCGM_ADDR and FAKE_DCGM_COLLECT_MS; an empty address means the fake is off.
func fakeDCGMConfig(getenv func(string) string) (string, time.Duration, error) {
	addr := getenv("FAKE_DCGM_ADDR")
	if addr == "" {
		return "", 0, nil
	}
	if _, _, err := net.SplitHostPort(addr); err != nil {
		return "", 0, fmt.Errorf("FAKE_DCGM_ADDR %q: %w", addr, err)
	}
	// 1,000 ms by default, the -c the study's exporter is run with.
	ms := int64(1000)
	if raw := getenv("FAKE_DCGM_COLLECT_MS"); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v <= 0 {
			return "", 0, fmt.Errorf("FAKE_DCGM_COLLECT_MS %q must be a positive whole number of milliseconds", raw)
		}
		ms = v
	}
	return addr, time.Duration(ms) * time.Millisecond, nil
}

// serveFakeDCGM runs the fake until ctx ends.
func serveFakeDCGM(ctx context.Context, d *fakeDCGM, addr string, collect time.Duration) error {
	srv := &http.Server{Addr: addr, Handler: d, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		t := time.NewTicker(collect)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				_ = srv.Close()
				return
			case <-t.C:
				d.collect()
			}
		}
	}()
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
