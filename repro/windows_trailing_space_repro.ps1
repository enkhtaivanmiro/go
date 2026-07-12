param(
    [ValidateSet("file", "http")]
    [string]$Transport = "file",

    [ValidateSet("space", "dot-space")]
    [string]$Variant = "space"
)

$ErrorActionPreference = "Stop"

function Show-FileIfPresent {
    param(
        [string]$Label,
        [string]$Path
    )

    Write-Host "=== $Label ==="
    if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path
    } else {
        Write-Host "<absent>"
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
$workRoot = Join-Path $env:RUNNER_TEMP ("go-windows-repro-" + $Transport + "-" + $Variant)
$proxyRoot = Join-Path $workRoot "proxy"
$clientDir = Join-Path $workRoot "client"
$modCache = Join-Path $workRoot "modcache"
$goExe = Join-Path $workRoot "go-local.exe"
$serverExe = Join-Path $workRoot "static-proxy-server.exe"
$serverLog = Join-Path $workRoot "http-server.log"
$transcript = Join-Path $workRoot "session.log"
$resultJson = Join-Path $workRoot "result.json"
$resultTxt = Join-Path $workRoot "result.txt"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $workRoot
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
New-Item -ItemType Directory -Force -Path $clientDir | Out-Null
Start-Transcript -LiteralPath $transcript | Out-Null

Push-Location $repoRoot
try {
    $env:GOTOOLCHAIN = "local"
    $env:GOROOT = $repoRoot

    Write-Host "=== build local cmd/go ==="
    Push-Location (Join-Path $repoRoot "src/cmd")
    try {
        go build -o $goExe cmd/go
    } finally {
        Pop-Location
    }

    Write-Host "=== build proxy contents ==="
    go run .\repro\trailing_space_proxy_builder.go -root $proxyRoot -variant $Variant

    $proxyURL = ""
    $httpServer = $null
    if ($Transport -eq "file") {
        $proxyURL = "file:///" + ($proxyRoot -replace "\\", "/")
    } else {
        $port = 8123
        Write-Host "=== start local proxy server ==="
        go build -o $serverExe .\repro\static_proxy_server.go
        $httpServer = Start-Process -FilePath $serverExe -ArgumentList @("-addr", "127.0.0.1:$port", "-root", $proxyRoot) -WorkingDirectory $repoRoot -RedirectStandardOutput $serverLog -RedirectStandardError $serverLog -PassThru
        Start-Sleep -Seconds 2
        $proxyURL = "http://127.0.0.1:$port"
    }

    try {
        Set-Content -LiteralPath (Join-Path $clientDir "go.mod") -Value @"
module client.example

go 1.27
"@

        $env:GOTOOLCHAIN = "local"
        $env:GOSUMDB = "off"
        $env:GOPROXY = $proxyURL
        $env:GOMODCACHE = $modCache

        Write-Host "=== environment ==="
        Write-Host "GOPROXY=$env:GOPROXY"
        Write-Host "GOMODCACHE=$env:GOMODCACHE"
        Write-Host "VARIANT=$Variant"

        $downloadOutput = ""
        $listOutput = ""
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

        Write-Host "=== existence checks ==="
        Write-Host ("go.mod => " + (Test-Path -LiteralPath (Join-Path $dir "go.mod")))
        Write-Host ("go.mod(space) => " + (Test-Path -LiteralPath (Join-Path $dir "go.mod ")))
        Write-Host ("go.mod(dot-space) => " + (Test-Path -LiteralPath (Join-Path $dir "go.mod. ")))
        Write-Host ("download exit => " + $downloadExit)
        Write-Host ("list exit => " + $listExit)

        $goModPath = Join-Path $dir "go.mod"
        $goModSpacePath = Join-Path $dir "go.mod "
        $goModDotSpacePath = Join-Path $dir "go.mod. "
        $downloadModPath = Join-Path $downloadDir "v1.0.0.mod"

        $result = [ordered]@{
            transport = $Transport
            variant = $Variant
            goproxy = $proxyURL
            work_root = $workRoot
            module_dir = $dir
            downloaded_mod_path = $downloadModPath
            downloaded_mod_exists = (Test-Path -LiteralPath $downloadModPath)
            extracted_go_mod_exists = (Test-Path -LiteralPath $goModPath)
            extracted_go_mod_space_exists = (Test-Path -LiteralPath $goModSpacePath)
            extracted_go_mod_dot_space_exists = (Test-Path -LiteralPath $goModDotSpacePath)
            download_exit_code = $downloadExit
            list_exit_code = $listExit
            downloaded_mod_content = (Get-FileContentOrNull $downloadModPath)
            extracted_go_mod_content = (Get-FileContentOrNull $goModPath)
            extracted_go_mod_space_content = (Get-FileContentOrNull $goModSpacePath)
            extracted_go_mod_dot_space_content = (Get-FileContentOrNull $goModDotSpacePath)
            download_output = $downloadOutput
            list_output = $listOutput
        }

        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultJson

        @(
            "transport=$Transport"
            "variant=$Variant"
            "goproxy=$proxyURL"
            "download_exit_code=$downloadExit"
            "list_exit_code=$listExit"
            "downloaded_mod_exists=$($result.downloaded_mod_exists)"
            "extracted_go_mod_exists=$($result.extracted_go_mod_exists)"
            "extracted_go_mod_space_exists=$($result.extracted_go_mod_space_exists)"
            "extracted_go_mod_dot_space_exists=$($result.extracted_go_mod_dot_space_exists)"
        ) | Set-Content -LiteralPath $resultTxt
    } finally {
        Stop-ProcessIfRunning $httpServer
        if (Test-Path -LiteralPath $serverLog) {
            Write-Host "=== http server log ==="
            Get-Content -LiteralPath $serverLog
        }
    }
} finally {
    Pop-Location
    Stop-Transcript | Out-Null
}
