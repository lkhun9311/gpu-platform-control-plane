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

package bench

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
)

// ChecksumFile returns the hex-encoded sha256 of the file at path.
//
// The manifest records this checksum for its trace file, and LoadManifest recomputes it on load, so a trace edited after the checksum was frozen fails to load instead of silently letting arms be compared against different traffic.
//
// The file is streamed through the hasher rather than read whole, so a large trace does not have to fit in memory to be verified.
func ChecksumFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("hash %s: %w", path, err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// ReadTraceFileVerified reads the trace at path once, checks those bytes against want, and parses the same bytes.
//
// LoadManifest verifies the checksum by streaming the file and closing it, and a replay that then opened the file again could send a trace replaced in between under the verified checksum.
// Hashing and parsing one buffer closes that window, so the checksum stamped on every row describes the requests that were actually sent.
// The whole file is held in memory, which is fine because a trace is bounded at maxTraceRows rows.
func ReadTraceFileVerified(path, want string) ([]TraceRow, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read trace %s: %w", path, err)
	}
	if got := Checksum(b); got != want {
		return nil, fmt.Errorf("trace checksum mismatch: expected %s but the bytes read from %s hash to %s, so the trace changed after it was verified", want, path, got)
	}
	rows, err := ReadTrace(bytes.NewReader(b))
	if err != nil {
		return nil, fmt.Errorf("parse trace %s: %w", path, err)
	}
	return rows, nil
}

// Checksum returns the hex-encoded sha256 of b.
//
// The trace writer uses it to stamp a freshly generated trace's checksum into the manifest without a filesystem round trip, and it matches what ChecksumFile computes for the same bytes on disk.
func Checksum(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
