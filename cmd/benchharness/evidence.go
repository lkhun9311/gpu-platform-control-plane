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
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// partialSuffix and statusSuffix name the files beside a raw-evidence file.
//
// Neither ends in .jsonl, so a report globbing raw-*.jsonl never reads a half-written file or a record as rows.
const (
	partialSuffix = ".partial"
	statusSuffix  = ".status.json"
)

// The two statuses a completion record can carry.
const (
	statusComplete   = "complete"
	statusIncomplete = "incomplete"
)

// completionStatus is the record a replay writes after its raw file is final, and the one a report requires of current evidence.
//
// Rows alone cannot say a request is missing, so the record states how many were scheduled and pins the raw file's bytes.
type completionStatus struct {
	// Status is statusComplete only when every scheduled request has exactly one row and every row reached the live file.
	Status string `json:"status"`
	// Reasons says why a recording is incomplete; empty when it is complete.
	Reasons []string `json:"reasons,omitempty"`
	// Scheduled is the trace's request count and Recorded is the raw file's row count.
	Scheduled int `json:"scheduled"`
	Recorded  int `json:"recorded"`
	// Dispositions counts the rows by how their requests ended.
	Dispositions map[string]int `json:"dispositions"`
	// TraceChecksum is the trace the rows replayed, and RawSHA256 is the sha256 of the raw file as finalized.
	TraceChecksum string `json:"traceChecksum"`
	RawSHA256     string `json:"rawSha256"`
}

// completionFor decides whether a recording is complete: reconciled against its trace, with no live row lost.
func completionFor(trace []bench.TraceRow, rows []bench.RawRow, liveFailed int, liveErr error) completionStatus {
	st := completionStatus{Status: statusComplete, Scheduled: len(trace), Recorded: len(rows), Dispositions: map[string]int{}}
	for _, r := range rows {
		st.Dispositions[r.Disposition]++
	}
	if err := bench.ReconcileRecording(trace, rows); err != nil {
		st.Reasons = append(st.Reasons, err.Error())
	}
	if liveFailed > 0 || liveErr != nil {
		st.Reasons = append(st.Reasons, fmt.Sprintf("%d row(s) could not be appended to the live file; the first error: %v", liveFailed, liveErr))
	}
	if len(st.Reasons) > 0 {
		st.Status = statusIncomplete
	}
	return st
}

// evidenceFile is a raw-evidence path reserved before the first request and finalized once, without ever replacing a file.
type evidenceFile struct {
	final   string
	partial *os.File
}

// reserveEvidence refuses a destination that already holds evidence, and proves the destination writable, before anything is sent.
//
// The raw file used to be created with os.Create after the replay, which truncated an earlier run's evidence and discovered an unwritable destination only once the GPU time was spent.
// The partial file is created exclusively, so two replays cannot share a destination either.
func reserveEvidence(final string) (*evidenceFile, error) {
	for _, p := range []string{final, final + statusSuffix} {
		if _, err := os.Lstat(p); err == nil {
			return nil, fmt.Errorf("%s already exists; a replay never overwrites evidence, so choose a new --raw-out", p)
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("check %s: %w", p, err)
		}
	}
	f, err := os.OpenFile(final+partialSuffix, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, fmt.Errorf("%s already exists, from a replay that did not finish or one still running; keep or move it, then choose a new --raw-out", final+partialSuffix)
		}
		return nil, fmt.Errorf("reserve the raw evidence file: %w", err)
	}
	// A sync on the empty file proves the destination accepts durable writes before the run depends on it.
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(f.Name())
		return nil, fmt.Errorf("the raw evidence destination does not accept a sync: %w", err)
	}
	return &evidenceFile{final: final, partial: f}, nil
}

// abandon removes a reservation that never received a row, for a run refused before its first request.
func (e *evidenceFile) abandon() {
	_ = e.partial.Close()
	_ = os.Remove(e.partial.Name())
}

// finalize writes the rows, makes them durable, links them into place, and then writes the completion record the same way.
//
// os.Link fails if the destination exists, so a file that appeared at the final path meanwhile is never replaced; the rows then stay in the partial file.
// The record is written last, so a record on disk always describes a raw file that is already final.
func (e *evidenceFile) finalize(rows []bench.RawRow, st completionStatus) error {
	var buf bytes.Buffer
	if err := bench.WriteRawRows(&buf, rows); err != nil {
		_ = e.partial.Close()
		return err
	}
	st.RawSHA256 = bench.Checksum(buf.Bytes())
	if err := writeDurably(e.partial, buf.Bytes()); err != nil {
		return fmt.Errorf("write the raw evidence to %s: %w", e.partial.Name(), err)
	}
	if err := linkIntoPlace(e.partial.Name(), e.final); err != nil {
		return err
	}
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return writeExclusive(e.final+statusSuffix, append(b, '\n'))
}

// writeDurably writes b to f, syncs it and closes it, reporting the first failure of the three.
func writeDurably(f *os.File, b []byte) error {
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// writeExclusive writes b to path through an exclusive partial file, never replacing anything already at path.
func writeExclusive(path string, b []byte) error {
	f, err := os.OpenFile(path+partialSuffix, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return fmt.Errorf("create %s: %w", path+partialSuffix, err)
	}
	if err := writeDurably(f, b); err != nil {
		return fmt.Errorf("write %s: %w", f.Name(), err)
	}
	return linkIntoPlace(f.Name(), path)
}

// linkIntoPlace makes partial visible at final without ever replacing final, then drops the partial name and syncs the directory.
func linkIntoPlace(partial, final string) error {
	if err := os.Link(partial, final); err != nil {
		return fmt.Errorf("finalize %s: %w; the rows are kept in %s", final, err, partial)
	}
	if err := os.Remove(partial); err != nil {
		return fmt.Errorf("remove %s after finalizing %s: %w", partial, final, err)
	}
	return syncDir(filepath.Dir(final))
}

// syncDir makes a directory's new entries durable, which a file's own sync does not.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("open %s to sync it: %w", dir, err)
	}
	defer func() { _ = d.Close() }()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("sync %s: %w", dir, err)
	}
	return nil
}

// requireCompletionRecord refuses current evidence unless its completion record says complete and pins these exact bytes.
//
// Rows that carry a disposition come from a replay that always writes the record, so its absence means the file is not what the replay finalized.
// Historical rows carry no disposition and need no record, so a published study re-scores exactly as it did.
func requireCompletionRecord(path string, raw []byte, rows []bench.RawRow) error {
	current := false
	for _, r := range rows {
		current = current || r.Disposition != ""
	}
	b, err := os.ReadFile(path + statusSuffix)
	if errors.Is(err, os.ErrNotExist) {
		if current {
			return fmt.Errorf("%s holds rows from a replay that records completion, and has no %s beside it, so nothing says the recording is whole", path, statusSuffix)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("read the completion record of %s: %w", path, err)
	}
	var st completionStatus
	if err := json.Unmarshal(b, &st); err != nil {
		return fmt.Errorf("parse the completion record of %s: %w", path, err)
	}
	switch {
	case st.Status != statusComplete:
		return fmt.Errorf("%s was recorded %s: %v", path, st.Status, st.Reasons)
	case st.RawSHA256 != bench.Checksum(raw):
		return fmt.Errorf("%s is not the file its completion record pins (sha256 %s), so it changed after the replay finalized it", path, st.RawSHA256)
	case st.Recorded != len(rows) || st.Scheduled != len(rows):
		return fmt.Errorf("%s holds %d row(s) and its completion record says %d scheduled and %d recorded", path, len(rows), st.Scheduled, st.Recorded)
	}
	return nil
}

// readRawEvidence reads a raw file once and checks those same bytes against its completion record.
func readRawEvidence(path string) ([]bench.RawRow, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	rows, err := bench.ReadRawRows(bytes.NewReader(b))
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	if err := requireCompletionRecord(path, b, rows); err != nil {
		return nil, err
	}
	return rows, nil
}

// formatDispositions prints the disposition counts in a stable order for the run log.
func formatDispositions(d map[string]int) string {
	keys := make([]string, 0, len(d))
	for k := range d {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	for i, k := range keys {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%s %d", k, d[k])
	}
	return b.String()
}
