package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

// stubPilotLog makes the stub engine write the prospective-admission pilot's step log, so the kind rehearsal
// exercises the pilot's capture and eligibility rules rather than refusing them or going around them.
//
// The stub has no scheduler, so its steps are invented: one prefill step per request and one decode step per output
// token after the first. Each step is written, under one lock, as a pilot_step_logger.py "sched" record AND as a
// vLLM iteration line with the matching index, timestamp format and token total, so the alignment check between
// the two logs has the shape the real engine gives it (design page, "The arm's step log is complete"). What it
// cannot rehearse is vLLM itself: the request-ID transformation and the real priority field are checked by the
// CPU rehearsal with the real engine.
type stubPilotLog struct {
	mu       sync.Mutex
	steps    io.Writer
	iters    io.Writer
	path     string
	seq      int
	step     int
	sentinel int64
}

// openStubPilotLog appends to the step log at path, and prints iteration lines to iters.
func openStubPilotLog(path string, iters io.Writer) (*stubPilotLog, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open the stub's pilot step log %s: %w", path, err)
	}
	return &stubPilotLog{steps: f, iters: iters, path: path}, nil
}

// write appends one record with the next sequence number; the caller holds the lock.
func (l *stubPilotLog) write(rec map[string]any) {
	l.seq++
	rec["seq"] = l.seq
	b, _ := json.Marshal(rec)
	_, _ = l.steps.Write(append(b, '\n'))
}

// add records a request's arrival at the "scheduler", with the priority it carried.
func (l *stubPilotLog) add(id string, priority *int, prompt int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	first := l.seq + 1
	var p any
	if priority != nil {
		p = *priority
	}
	l.write(map[string]any{"ev": "add", "id": id, "priority": p, "prompt": prompt, "mono": time.Now().UnixNano()})
	l.flushRecord(first)
}

// stepFor records one step that scheduled n tokens of request id, which had computed tokens before it, and prints
// the matching iteration line.
func (l *stubPilotLog) stepFor(id string, n, computed int, prefill bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	first := l.seq + 1
	l.step++
	now := time.Now()
	anchor := []int64{now.UnixNano(), now.UnixNano(), now.UnixNano()}
	l.write(map[string]any{"ev": "sched", "step": l.step, "t0": now.UnixNano(), "t1": now.UnixNano(),
		"anchor": anchor, "tokens": map[string]int{id: n}, "computed": map[string]int{id: computed}})
	l.write(map[string]any{"ev": "done", "step": l.step, "t2": now.UnixNano(), "t3": now.UnixNano()})
	l.flushRecord(first)
	ctxReq, ctxTok, genReq, genTok := 0, 0, 1, n
	if prefill {
		ctxReq, ctxTok, genReq, genTok = 1, n, 0, 0
	}
	_, _ = fmt.Fprintf(l.iters, "(APIServer pid=1) INFO %s [loggers.py:182] Engine 000: Iteration(%d): %d context requests, "+
		"%d context tokens, %d generation requests, %d generation tokens, iteration elapsed time: 1.00 ms, "+
		"GPU KV cache usage: 0.1%%\n", now.Format("01-02 15:04:05"), l.step-1, ctxReq, ctxTok, genReq, genTok)
}

// flushRecord closes the records from first to the current sequence number, as the plugin's writer does.
func (l *stubPilotLog) flushRecord(first int) {
	b, _ := json.Marshal(map[string]any{"ev": "flush", "records": l.seq - first + 1, "first_seq": first, "last_seq": l.seq})
	_, _ = l.steps.Write(append(b, '\n'))
}

// watchSentinel writes a terminal record whenever the sentinel file appears or changes, until stop is closed.
// Every record is written as it is produced, so the terminal record always says everything was written.
func (l *stubPilotLog) watchSentinel(stop <-chan struct{}) {
	t := time.NewTicker(200 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		fi, err := os.Stat(l.path + ".sentinel")
		if err != nil {
			continue
		}
		m := fi.ModTime().UnixNano()
		l.mu.Lock()
		if m != l.sentinel {
			l.sentinel = m
			b, _ := json.Marshal(map[string]any{"ev": "terminal", "seq_written": l.seq, "seq_produced": l.seq,
				"buffered": 0, "last_step": l.step, "wall": time.Now().UnixNano(), "sentinel_mtime": m})
			_, _ = l.steps.Write(append(b, '\n'))
		}
		l.mu.Unlock()
	}
}

// stubPilotRequest is what the pilot's stub reads from a request body: its priority and its output caps.
type stubPilotRequest struct {
	Priority  *int `json:"priority"`
	MaxTokens int  `json:"max_tokens"`
	MinTokens int  `json:"min_tokens"`
}
