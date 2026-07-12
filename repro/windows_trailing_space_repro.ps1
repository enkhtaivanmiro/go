param(
    [ValidateSet("file", "http")]
    [string]$Transport = "file",

    [ValidateSet("space", "dot-space")]
    [string]$Variant = "space",

    [ValidateSet("gomod-loud", "gomod-silent", "pgo-collision")]
    [string]$Payload = "gomod-loud"
)

$ErrorActionPreference = "Stop"

function Show-FileIfPresent {
    param(
        [string]$Label,
        [string]$Path
    )

    Write-Host "=== $Label ==="
    Write-Host "Path: <$Path>"

    try {
        $exists = Test-Path -LiteralPath $Path
        Write-Host "Exists=$exists"

        if ($exists) {
            Get-Content -LiteralPath $Path -Raw
        } else {
            Write-Host "<absent>"
        }
    }
    catch {
        Write-Host $_
    }
}

function Get-FileContentOrNull {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return [string](Get-Content -LiteralPath $Path -Raw)
    }
    return $null
}

function Stop-ProcessIfRunning {
    param([System.Diagnostics.Process]$Process)

    if ($null -ne $Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        $Process.WaitForExit()
    }
}

function Invoke-GoCommand {
    param(
        [string]$Label,
        [string[]]$Arguments
    )

    Write-Host "=== $Label ==="
    Write-Host ($goExe + " " + ($Arguments -join " "))
    & $goExe @Arguments
    $exitCode = $LASTEXITCODE
    Write-Host ("exit code: " + $exitCode)
    return $exitCode
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workRoot = Join-Path $env:RUNNER_TEMP ("go-windows-repro-" + $Transport + "-" + $Variant + "-" + $Payload)
$proxyRoot = Join-Path $workRoot "proxy"
$clientDir = Join-Path $workRoot "client"
$modCache = Join-Path $workRoot "modcache"
$serverExe = Join-Path $workRoot "static-proxy-server.exe"
$serverOutLog = Join-Path $workRoot "http-server-stdout.log"
$serverErrLog = Join-Path $workRoot "http-server-stderr.log"
$transcript = Join-Path $workRoot "session.log"
$resultJson = Join-Path $workRoot "result.json"
$resultTxt = Join-Path $workRoot "result.txt"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $workRoot
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
New-Item -ItemType Directory -Force -Path $clientDir | Out-Null
Start-Transcript -LiteralPath $transcript | Out-Null

Push-Location $repoRoot
try {
    # --- Capture the bootstrap toolchain's GOROOT BEFORE touching any env vars ---
    # This must happen while the system `go` (installed by actions/setup-go) is
    # still the one on PATH, with its own untouched GOROOT.
    $bootstrapGoRoot = (& go env GOROOT).Trim()
    Write-Host "=== bootstrap toolchain ==="
    Write-Host "GOROOT_BOOTSTRAP=$bootstrapGoRoot"
    & go version

    # --- Build the checked-out tree's own toolchain via make.bat ---
    # This is the officially supported way to compile Go from source with a
    # different (older) bootstrap compiler. It does NOT go through the
    # `go.mod` minimum-version gate that a plain `go build` would hit, and it
    # does NOT require setting GOROOT to the source tree beforehand — make.bat
    # handles that internally.
    Write-Host "=== build local toolchain via make.bat ==="
    $env:GOROOT_BOOTSTRAP = $bootstrapGoRoot
    Push-Location (Join-Path $repoRoot "src")
    try {
        cmd /c ".\make.bat" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "make.bat failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    $goExe = Join-Path $repoRoot "bin\go.exe"
    if (-not (Test-Path -LiteralPath $goExe)) {
        throw "expected built go.exe not found at $goExe"
    }

    # Now that the tree's own toolchain is actually built, it's safe to point
    # GOROOT at the tree for all subsequent invocations of $goExe.
    $env:GOROOT = $repoRoot
    $env:GOTOOLCHAIN = "local"

    Write-Host "=== built toolchain version ==="
    & $goExe version
    if ($LASTEXITCODE -ne 0) { throw "built go.exe failed to run" }

    Write-Host "=== build proxy contents ==="
    & $goExe run .\repro\trailing_space_proxy_builder.go -root $proxyRoot -variant $Variant -payload $Payload
    if ($LASTEXITCODE -ne 0) { throw "trailing_space_proxy_builder.go failed with exit code $LASTEXITCODE" }

    $proxyURL = ""
    $httpServer = $null
    if ($Transport -eq "file") {
        $proxyURL = "file:///" + ($proxyRoot -replace "\\", "/")
    } else {
        $port = 8123
        Write-Host "=== start local proxy server ==="
        & $goExe build -o $serverExe .\repro\static_proxy_server.go
        if ($LASTEXITCODE -ne 0) { throw "static_proxy_server.go build failed with exit code $LASTEXITCODE" }

        $httpServer = Start-Process -FilePath $serverExe `
            -ArgumentList @("-addr", "127.0.0.1:$port", "-root", $proxyRoot) `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $serverOutLog `
            -RedirectStandardError $serverErrLog `
            -PassThru
        Start-Sleep -Seconds 2
        $proxyURL = "http://127.0.0.1:$port"
    }

    try {
        Set-Content -LiteralPath (Join-Path $clientDir "go.mod") -Value @"
module client.example

go 1.21

require example.com/p v1.0.0
"@

        if ($Payload -eq "pgo-collision") {
            Set-Content -LiteralPath (Join-Path $clientDir "main.go") -Value @"
package main

import (
	"fmt"
	"example.com/p"
)

func main() {
	fmt.Printf("Label=%s\n", p.Label())
	fmt.Printf("X=%d\n", p.X)
}
"@
        }

        $env:GOSUMDB = "off"
        $env:GOPROXY = $proxyURL
        $env:GOMODCACHE = $modCache

        Write-Host "=== environment ==="
        Write-Host "GOPROXY=$env:GOPROXY"
        Write-Host "GOMODCACHE=$env:GOMODCACHE"
        Write-Host "VARIANT=$Variant"
        Write-Host "PAYLOAD=$Payload"

        $downloadOutput = ""
        $listOutput = ""
        $runOutput = ""
        $runExit = 0
        Push-Location $clientDir
        try {
            Write-Host "=== go mod download ==="
            $downloadOutput = (& $goExe mod download -json example.com/p@v1.0.0 2>&1 | Out-String)
            $downloadExit = $LASTEXITCODE
            Write-Host $downloadOutput
            Write-Host ("exit code: " + $downloadExit)

            Write-Host "=== go list -m ==="
            $listOutput = (& $goExe list -m -json example.com/p@v1.0.0 2>&1 | Out-String)
            $listExit = $LASTEXITCODE
            Write-Host $listOutput
            Write-Host ("exit code: " + $listExit)

            if ($Payload -eq "pgo-collision" -and $downloadExit -eq 0) {
                Write-Host "=== go run main.go ==="
                $runOutput = (& $goExe run main.go 2>&1 | Out-String)
                $runExit = $LASTEXITCODE
                Write-Host $runOutput
                Write-Host ("exit code: " + $runExit)
            }
        } finally {
            Pop-Location
        }

        $dir = Join-Path $modCache "example.com\p@v1.0.0"
        Write-Host "=== extracted dir listing ==="
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -Force | ForEach-Object {
                Write-Host ("[" + $_.Name + "]")
            }
        } else {
            Write-Host "<module dir absent>"
        }

        $downloadDir = Join-Path $modCache "cache\download\example.com\p\@v"
        Show-FileIfPresent -Label "downloaded .mod" -Path (Join-Path $downloadDir "v1.0.0.mod")
        Show-FileIfPresent -Label "extracted go.mod" -Path (Join-Path $dir "go.mod")
        Show-FileIfPresent -Label "extracted go.mod(space)" -Path (Join-Path $dir "go.mod ")
        Show-FileIfPresent -Label "extracted go.mod(dot-space)" -Path (Join-Path $dir "go.mod. ")
        Show-FileIfPresent -Label "extracted p.go" -Path (Join-Path $dir "p.go")
        Show-FileIfPresent -Label "extracted p.go(space)" -Path (Join-Path $dir "p.go ")
        Show-FileIfPresent -Label "extracted p.go(dot-space)" -Path (Join-Path $dir "p.go. ")

        Write-Host "=== existence checks ==="
        Write-Host ("go.mod => " + (Test-Path -LiteralPath (Join-Path $dir "go.mod")))
        Write-Host ("go.mod(space) => " + (Test-Path -LiteralPath (Join-Path $dir "go.mod ")))
        Write-Host ("go.mod(dot-space) => " + (Test-Path -LiteralPath (Join-Path $dir "go.mod. ")))
        Write-Host ("p.go => " + (Test-Path -LiteralPath (Join-Path $dir "p.go")))
        Write-Host ("p.go(space) => " + (Test-Path -LiteralPath (Join-Path $dir "p.go ")))
        Write-Host ("p.go(dot-space) => " + (Test-Path -LiteralPath (Join-Path $dir "p.go. ")))
        Write-Host ("download exit => " + $downloadExit)
        Write-Host ("list exit => " + $listExit)

        $goModPath = Join-Path $dir "go.mod"
        $goModSpacePath = Join-Path $dir "go.mod "
        $goModDotSpacePath = Join-Path $dir "go.mod. "
        $pGoPath = Join-Path $dir "p.go"
        $pGoSpacePath = Join-Path $dir "p.go "
        $pGoDotSpacePath = Join-Path $dir "p.go. "
        $downloadModPath = Join-Path $downloadDir "v1.0.0.mod"

        $result = [ordered]@{
            transport = $Transport
            variant = $Variant
            payload = $Payload
            goproxy = $proxyURL
            work_root = $workRoot
            module_dir = $dir
            downloaded_mod_path = $downloadModPath
            downloaded_mod_exists = (Test-Path -LiteralPath $downloadModPath)
            extracted_go_mod_exists = (Test-Path -LiteralPath $goModPath)
            extracted_go_mod_space_exists = (Test-Path -LiteralPath $goModSpacePath)
            extracted_go_mod_dot_space_exists = (Test-Path -LiteralPath $goModDotSpacePath)
            extracted_p_go_exists = (Test-Path -LiteralPath $pGoPath)
            extracted_p_go_space_exists = (Test-Path -LiteralPath $pGoSpacePath)
            extracted_p_go_dot_space_exists = (Test-Path -LiteralPath $pGoDotSpacePath)
            download_exit_code = $downloadExit
            list_exit_code = $listExit
            downloaded_mod_content = (Get-FileContentOrNull $downloadModPath)
            extracted_go_mod_content = (Get-FileContentOrNull $goModPath)
            extracted_go_mod_space_content = (Get-FileContentOrNull $goModSpacePath)
            extracted_go_mod_dot_space_content = (Get-FileContentOrNull $goModDotSpacePath)
            extracted_p_go_content = (Get-FileContentOrNull $pGoPath)
            extracted_p_go_space_content = (Get-FileContentOrNull $pGoSpacePath)
            extracted_p_go_dot_space_content = (Get-FileContentOrNull $pGoDotSpacePath)
            download_output = $downloadOutput
            list_output = $listOutput
            run_output = $runOutput
            run_exit_code = $runExit
        }

        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultJson

        @(
            "transport=$Transport"
            "variant=$Variant"
            "payload=$Payload"
            "goproxy=$proxyURL"
            "download_exit_code=$downloadExit"
            "list_exit_code=$listExit"
            "downloaded_mod_exists=$($result.downloaded_mod_exists)"
            "extracted_go_mod_exists=$($result.extracted_go_mod_exists)"
            "extracted_go_mod_space_exists=$($result.extracted_go_mod_space_exists)"
            "extracted_go_mod_dot_space_exists=$($result.extracted_go_mod_dot_space_exists)"
            "extracted_p_go_exists=$($result.extracted_p_go_exists)"
            "extracted_p_go_space_exists=$($result.extracted_p_go_space_exists)"
            "extracted_p_go_dot_space_exists=$($result.extracted_p_go_dot_space_exists)"
            "run_exit_code=$runExit"
            "run_output=$($runOutput.Trim())"
        ) | Set-Content -LiteralPath $resultTxt
    } finally {
        Stop-ProcessIfRunning $httpServer
        if (Test-Path -LiteralPath $serverOutLog) {
            Write-Host "=== http server stdout ==="
            Get-Content -LiteralPath $serverOutLog
        }
        if (Test-Path -LiteralPath $serverErrLog) {
            Write-Host "=== http server stderr ==="
            Get-Content -LiteralPath $serverErrLog
        }
    }
} finally {
    Pop-Location
    Stop-Transcript | Out-Null
}