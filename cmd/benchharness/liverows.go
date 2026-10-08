package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// liveRows appends each finished request's row to a file and syncs it, so a row exists on disk as soon as its
// request ends rather than when the whole replay does.
//
// It is a second copy, beside the raw file written whole at the end, and not a replacement: the raw file keeps its
// order and its readers, and this one exists for the evidence sidecar to upload during the replay.
type liveRows struct {
	f      *os.File
	failed int
	first  error
}

func openLiveRows(path string) (*liveRows, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open the live row file %s: %w", path, err)
	}
	return &liveRows{f: f}, nil
}

// write is the replay's OnRow; Replay serialises the calls. A nil liveRows writes nothing, so a study that does not
// record timing can pass its method without a branch.
func (l *liveRows) write(r bench.RawRow) {
	if l == nil {
		return
	}
	b, err := json.Marshal(r)
	if err == nil {
		_, err = l.f.Write(append(b, '\n'))
	}
	if err == nil {
		err = l.f.Sync()
	}
	if err != nil {
		l.failed++
		if l.first == nil {
			l.first = err
		}
	}
}

// close closes the file and returns how many rows failed and the first error.
func (l *liveRows) close() (int, error) {
	if err := l.f.Close(); err != nil && l.first == nil {
		l.failed++
		l.first = err
	}
	return l.failed, l.first
}
