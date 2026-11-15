package bench

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestWriteNewFileDurablyNeverShowsAPartialFile: the final name appears only with the whole content, and a refused write changes nothing.
func TestWriteNewFileDurablyNeverShowsAPartialFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bundle.json")
	if err := WriteNewFileDurably(path, []byte("one\n")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "one\n" {
		t.Fatalf("content %q", b)
	}
	if _, err := os.Stat(path + ".partial"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the partial name was left: %v", err)
	}
	if err := WriteNewFileDurably(path, []byte("two\n")); !errors.Is(err, os.ErrExist) {
		t.Fatalf("an existing file was not refused as existing: %v", err)
	}
	if b, _ := os.ReadFile(path); string(b) != "one\n" {
		t.Fatalf("a refused write changed the file to %q", b)
	}
	if _, err := os.Stat(path + ".partial"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused write left its partial: %v", err)
	}
}

// TestWriteNewFileDurablyRefusesAnUnfinishedWrite: a partial left by a crash is evidence of a write that never finished, not something to overwrite.
func TestWriteNewFileDurablyRefusesAnUnfinishedWrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.yaml")
	if err := os.WriteFile(path+".partial", []byte("torn"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := WriteNewFileDurably(path, []byte("whole\n"))
	if err == nil || !strings.Contains(err.Error(), "did not finish") {
		t.Fatalf("a leftover partial was overwritten: %v", err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the final name appeared beside an unfinished write: %v", err)
	}
	if b, _ := os.ReadFile(path + ".partial"); string(b) != "torn" {
		t.Fatalf("the leftover partial was changed to %q", b)
	}
}
