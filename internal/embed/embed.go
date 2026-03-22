package embed

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Extract writes all files from the given FS to a temporary directory,
// preserving the directory structure. .sh files are made executable.
// Returns the tmpdir path, a cleanup function, and any error.
func Extract(assets fs.FS) (string, func(), error) {
	tmpDir, err := os.MkdirTemp("", "kickstart-")
	if err != nil {
		return "", nil, fmt.Errorf("create tmpdir: %w", err)
	}

	cleanup := func() { os.RemoveAll(tmpDir) }

	err = fs.WalkDir(assets, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		target := filepath.Join(tmpDir, path)

		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}

		data, err := fs.ReadFile(assets, path)
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}

		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", filepath.Dir(target), err)
		}

		perm := os.FileMode(0o644)
		if strings.HasSuffix(path, ".sh") {
			perm = 0o755
		}

		if err := os.WriteFile(target, data, perm); err != nil {
			return fmt.Errorf("write %s: %w", target, err)
		}

		return nil
	})

	if err != nil {
		cleanup()
		return "", nil, fmt.Errorf("extract assets: %w", err)
	}

	return tmpDir, cleanup, nil
}
