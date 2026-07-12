package zip

import (
	"archive/zip"
	"bytes"
	"os"
	"strings"
	"testing"

	"golang.org/x/mod/module"
)

func TestCheckZipAcceptsWindowsNormalizingGoModNames(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name      string
		entryName string
		body      string
	}{
		{
			name:      "go_mod_space",
			entryName: "go.mod ",
			body:      "module example.com/p\n\ngo 999.0\n",
		},
		{
			name:      "go_mod_dot_space",
			entryName: "go.mod. ",
			body:      "module example.com/p\n\ngo 999.0\n",
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			cf, err := checkZipFixture(t, map[string]string{
				tc.entryName: tc.body,
				"p.go":       "package p\n",
			})
			if err != nil {
				t.Fatalf("CheckZip returned error: %v", err)
			}
			if got := cf.Err(); got != nil {
				t.Fatalf("CheckedFiles.Err() = %v, want nil", got)
			}
			if len(cf.Invalid) != 0 {
				t.Fatalf("CheckZip Invalid = %v, want none", cf.Invalid)
			}
		})
	}
}

func TestCheckZipBypassesGoModSizeForWindowsNormalizingNames(t *testing.T) {
	t.Parallel()

	bigBody := "module example.com/p\n\ngo 999.0\n" + strings.Repeat("x", MaxGoMod+1024)
	for _, entryName := range []string{"go.mod ", "go.mod. "} {
		entryName := entryName
		t.Run(entryName, func(t *testing.T) {
			t.Parallel()

			cf, err := checkZipFixture(t, map[string]string{
				entryName: bigBody,
				"p.go":    "package p\n",
			})
			if err != nil {
				t.Fatalf("CheckZip returned error: %v", err)
			}
			if got := cf.Err(); got != nil {
				t.Fatalf("CheckedFiles.Err() = %v, want nil", got)
			}
			if cf.SizeError != nil {
				t.Fatalf("SizeError = %v, want nil", cf.SizeError)
			}
			if len(cf.Invalid) != 0 {
				t.Fatalf("CheckZip Invalid = %v, want none", cf.Invalid)
			}
		})
	}
}

func TestCheckZipAcceptsWindowsNormalizingCollisions(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name  string
		files map[string]string
	}{
		{
			name: "go_mod_and_go_mod_space",
			files: map[string]string{
				"go.mod":  "module example.com/p\n\ngo 1.21\n",
				"go.mod ": "module example.com/p\n\ngo 999.0\n",
				"p.go":    "package p\n",
			},
		},
		{
			name: "p_go_and_p_go_space",
			files: map[string]string{
				"go.mod": "module example.com/p\n\ngo 1.21\n",
				"p.go":   "package p\n",
				"p.go ":  "package p\nconst X = 1\n",
			},
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			cf, err := checkZipFixture(t, tc.files)
			if err != nil {
				t.Fatalf("CheckZip returned error: %v", err)
			}
			if got := cf.Err(); got != nil {
				t.Fatalf("CheckedFiles.Err() = %v, want nil", got)
			}
			if len(cf.Invalid) != 0 {
				t.Fatalf("CheckZip Invalid = %v, want none", cf.Invalid)
			}
		})
	}
}

func checkZipFixture(t *testing.T, files map[string]string) (CheckedFiles, error) {
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

	tmp, err := os.CreateTemp(t.TempDir(), "windows-normalization-*.zip")
	if err != nil {
		t.Fatalf("CreateTemp: %v", err)
	}
	defer tmp.Close()
	if _, err := tmp.Write(buf.Bytes()); err != nil {
		t.Fatalf("Write temp zip: %v", err)
	}

	return CheckZip(module.Version{Path: "example.com/p", Version: "v1.0.0"}, tmp.Name())
}
