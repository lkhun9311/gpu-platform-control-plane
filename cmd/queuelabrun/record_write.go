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
	"fmt"
	"os"
	"path/filepath"
)

// writeRecord persists the record so a crash leaves either the previous state or a complete document.
//
// Temp-file-plus-rename makes the replacement atomic within the directory, and the directory fsync is what
// makes the rename itself durable: without it a crash can leave the rename unrecorded even though the file
// contents were flushed.
func writeRecord(path string, v any) error {
	b, err := encodeRecord(v)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, ".record-*")
	if err != nil {
		return fmt.Errorf("create temp record in %s: %w", dir, err)
	}
	tmp := f.Name()
	// Any failure past this point must not leave the temporary file behind for a reader to find.
	defer func() { _ = os.Remove(tmp) }()

	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return fmt.Errorf("write temp record: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("sync temp record: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close temp record: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("rename record into place: %w", err)
	}
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("open record directory: %w", err)
	}
	defer func() { _ = d.Close() }()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("sync record directory: %w", err)
	}
	return nil
}
