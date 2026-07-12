//go:build !windows

package zip

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/mod/module"
)

func TestUnzipKeepsWindowsNormalizingNamesLiteralOnNonWindows(t *testing.T) {
	t.Parallel()

	zipFile := buildZipForUnzipTest(t, map[string]string{
		"go.mod ": "module example.com/p\n\ngo 999.0\n" + strings.Repeat("x", MaxGoMod+1024),
		"p.go":    "package p\n",
	})

	dir := filepath.Join(t.TempDir(), "mod")
	mod := module.Version{Path: "example.com/p", Version: "v1.0.0"}
	if err := Unzip(dir, mod, zipFile); err != nil {
		t.Fatalf("Unzip returned error: %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "go.mod")); !os.IsNotExist(err) {
		t.Fatalf("stat(%q) = %v, want not exist", filepath.Join(dir, "go.mod"), err)
	}
	spacePath := filepath.Join(dir, "go.mod ")
	if _, err := os.Stat(spacePath); err != nil {
		t.Fatalf("stat(%q) = %v, want success", spacePath, err)
	}
	data, err := os.ReadFile(spacePath)
	if err != nil {
		t.Fatalf("ReadFile(%q): %v", spacePath, err)
	}
	if !strings.Contains(string(data), "go 999.0") {
		t.Fatalf("literal go.mod space file did not contain crafted manifest")
	}
}

func buildZipForUnzipTest(t *testing.T, files map[string]string) string {
	t.Helper()

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	prefix := "example.com/p@v1.0.0/"
	for name, body := range files {
		w, err := zw.Create(prefix + name)
		if err != nil {
			t.Fatalf("Create(%q): %v", name, err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatalf("Write(%q): %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("Close zip: %v", err)
	}

	tmp, err := os.CreateTemp(t.TempDir(), "unzip-nonwindows-*.zip")
	if err != nil {
		t.Fatalf("CreateTemp: %v", err)
	}
	if _, err := tmp.Write(buf.Bytes()); err != nil {
		tmp.Close()
		t.Fatalf("Write temp zip: %v", err)
	}
	if err := tmp.Close(); err != nil {
		t.Fatalf("Close temp zip: %v", err)
	}
	return tmp.Name()
}
