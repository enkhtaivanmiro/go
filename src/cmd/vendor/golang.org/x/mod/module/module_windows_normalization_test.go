package module

import "testing"

func TestCheckFilePathWindowsNormalizingNames(t *testing.T) {
	tests := []struct {
		path string
		ok   bool
	}{
		{path: "NUL", ok: false},
		{path: "NUL ", ok: true},
		{path: "NUL .txt", ok: true},
		{path: "CON", ok: false},
		{path: "CON ", ok: true},
		{path: "CON .txt", ok: true},
		{path: "go.mod", ok: true},
		{path: "go.mod ", ok: true},
		{path: "go.mod.", ok: false},
		{path: "go.mod. ", ok: true},
		{path: "pkg/file.go ", ok: true},
	}

	for _, tt := range tests {
		err := CheckFilePath(tt.path)
		if tt.ok && err != nil {
			t.Errorf("CheckFilePath(%q) = %v, want success", tt.path, err)
		}
		if !tt.ok && err == nil {
			t.Errorf("CheckFilePath(%q) succeeded, want error", tt.path)
		}
	}
}
