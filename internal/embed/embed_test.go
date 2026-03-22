package embed_test

import (
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"

	kickembed "github.com/dpanic/os-kickstart/internal/embed"
)

func TestExtract_CreatesFilesInTmpDir(t *testing.T) {
	t.Parallel()
	fs := fstest.MapFS{
		"lib.sh":                     {Data: []byte("#!/bin/bash\necho lib")},
		"modules/shell/install.sh":   {Data: []byte("#!/bin/bash\necho shell")},
		"modules/docker/daemon.json": {Data: []byte(`{"log-driver":"json-file"}`)},
	}

	tmpDir, cleanup, err := kickembed.Extract(fs)
	if err != nil {
		t.Fatalf("Extract failed: %v", err)
	}
	defer cleanup()

	if _, err := os.Stat(filepath.Join(tmpDir, "lib.sh")); err != nil {
		t.Error("lib.sh not found in tmpdir")
	}
	if _, err := os.Stat(filepath.Join(tmpDir, "modules", "shell", "install.sh")); err != nil {
		t.Error("modules/shell/install.sh not found")
	}
	if _, err := os.Stat(filepath.Join(tmpDir, "modules", "docker", "daemon.json")); err != nil {
		t.Error("modules/docker/daemon.json not found")
	}
}

func TestExtract_ShFilesAreExecutable(t *testing.T) {
	t.Parallel()
	fs := fstest.MapFS{
		"modules/test/run.sh": {Data: []byte("#!/bin/bash\necho hi")},
		"modules/test/config": {Data: []byte("key=val")},
	}

	tmpDir, cleanup, err := kickembed.Extract(fs)
	if err != nil {
		t.Fatalf("Extract failed: %v", err)
	}
	defer cleanup()

	info, err := os.Stat(filepath.Join(tmpDir, "modules", "test", "run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&0o111 == 0 {
		t.Error(".sh file should be executable")
	}

	info2, err := os.Stat(filepath.Join(tmpDir, "modules", "test", "config"))
	if err != nil {
		t.Fatal(err)
	}
	if info2.Mode()&0o111 != 0 {
		t.Error("non-.sh file should not be executable")
	}
}

func TestExtract_CleanupRemovesDir(t *testing.T) {
	t.Parallel()
	fs := fstest.MapFS{
		"lib.sh": {Data: []byte("#!/bin/bash")},
	}

	tmpDir, cleanup, err := kickembed.Extract(fs)
	if err != nil {
		t.Fatalf("Extract failed: %v", err)
	}

	cleanup()

	if _, err := os.Stat(tmpDir); !os.IsNotExist(err) {
		t.Error("tmpdir should be removed after cleanup")
	}
}
