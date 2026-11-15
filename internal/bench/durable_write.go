package bench

import (
	"errors"
	"fmt"
	"os"
)

// WriteNewFileDurably creates path with data, refusing a path that exists, and returns only once both are durable.
//
// The data goes to path+".partial", is synced, and is then hard-linked to path, which fails rather than replace a file
// already there; the directory is synced last so the new name survives a crash too.
// So path never names a torn file: a crash leaves at most the partial, which the next write refuses as unfinished.
// An existing path is reported as os.ErrExist, so a caller can say why its record is never rewritten.
func WriteNewFileDurably(path string, data []byte) error {
	partial := path + ".partial"
	f, err := os.OpenFile(partial, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("%s exists, from a write that did not finish; inspect it before writing %s", partial, path)
		}
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return fmt.Errorf("write %s: %w", partial, err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("sync %s: %w", partial, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close %s: %w", partial, err)
	}
	if err := os.Link(partial, path); err != nil {
		if errors.Is(err, os.ErrExist) {
			_ = os.Remove(partial)
			return fmt.Errorf("%s: %w", path, os.ErrExist)
		}
		return fmt.Errorf("link %s into place: %w; the data is kept in %s", path, err, partial)
	}
	if err := os.Remove(partial); err != nil {
		return fmt.Errorf("remove %s after writing %s: %w", partial, path, err)
	}
	return syncDirOf(path)
}
