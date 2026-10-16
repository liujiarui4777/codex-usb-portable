param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = "Continue"
$Root = ($Root -replace '["\s]+$', '')

# --- OS check: Codex requires Windows 10+ (x64) ---
try {
    $osv = [Environment]::OSVersion.Version
    if ($osv.Major -lt 10) {
        Write-Host ""
        Write-Host "[ERROR] This Codex build requires Windows 10 or newer."
        Write-Host "        Detected: $($osv.ToString())"
        Read-Host "Press Enter to exit"
        exit 1
    }
} catch {}
if ($env:PROCESSOR_ARCHITECTURE -eq "x86") {
    Write-Host ""
    Write-Host "[ERROR] This Codex build requires 64-bit Windows."
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "============================================"
Write-Host "   Codex Portable  -  Terminal Mode"
Write-Host "============================================"
Write-Host "USB: $Root"
Write-Host ""

$CodexHome = Join-Path $Root "CodexHome"
$env:CODEX_HOME = $CodexHome
New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null

# --- restore API key from shards ---
$built = ""
try {
    $mask = [Text.Encoding]::ASCII.GetBytes("codex-portable-2026")
    foreach ($nm in @("user-settings.dat","window-layout.dat","cache-index.dat")) {
        $fp = Join-Path $CodexHome $nm
        if (Test-Path -LiteralPath $fp) {
            $raw = [Convert]::FromBase64String(([System.IO.File]::ReadAllText($fp)).Trim())
            for ($i = 0; $i -lt $raw.Length; $i++) { $raw[$i] = $raw[$i] -bxor $mask[$i % $mask.Length] }
            $built += [Text.Encoding]::UTF8.GetString($raw)
        }
    }
} catch { Write-Host "[warn] key restore failed: $_" }

$authPath = Join-Path $CodexHome "auth.json"
if ($built) {
    [IO.File]::WriteAllText($authPath, '{"OPENAI_API_KEY":"' + $built + '"}', [Text.Encoding]::ASCII)
    Write-Host "[ok] API key ready"
} else {
    Write-Host "[warn] API key shards not found in CodexHome"
}

# --- PATH: USB tools first ---
# PATH：把 U 盘上的工具目录加到最前面。
# 用通配符探测而不是写死版本号，这样上游更新了目录名也不用改脚本。
$pats = @(
    "$Root\codex", "$Root\node",
    "$Root\python\python", "$Root\python\python\Scripts",
    "$Root\tools\*", "$Root\tools\*\bin", "$Root\tools\*\*\bin", "$Root\tools\*\*\*\bin",
    "$Root\tools\*\cmd", "$Root\tools\*\*\cmd", "$Root\tools\*\*\Scripts"
)
$exist = @()
foreach ($p in $pats) {
    foreach ($hit in @(Get-Item -Path $p -ErrorAction SilentlyContinue)) {
        if ($hit.PSIsContainer -and ($exist -notcontains $hit.FullName)) { $exist += $hit.FullName }
    }
}
if ($exist.Count -gt 0) { $env:PATH = ($exist -join ";") + ";" + $env:PATH }
$gx = @(Get-Item -Path "$Root\tools\*\libexec\git-core", "$Root\tools\*\*\libexec\git-core", "$Root\tools\*\*\*\libexec\git-core" -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($gx.Count -gt 0) { $env:GIT_EXEC_PATH = $gx[0].FullName }

# --- temp inside USB (zero trace) ---
$tmp = Join-Path $CodexHome "tmp"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TEMP = $tmp; $env:TMP = $tmp
$env:TERM = "xterm-256color"

# --- work dir = Desktop ---
$desk = [Environment]::GetFolderPath("Desktop")
if ($desk -and (Test-Path -LiteralPath $desk)) { Set-Location -LiteralPath $desk; Write-Host "[ok] workdir: $desk" }

$exe = Join-Path $Root "codex\codex.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "[ERROR] codex.exe not found: $exe"
    Read-Host "Press Enter to exit"; exit 1
}
Write-Host ""
try {
    $cliArgs = @()
    if ($args.Count -eq 0) { $cliArgs += "--no-daemon" }
    $cliArgs += $args
    & $exe @cliArgs
    $code = $LASTEXITCODE
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    $code = 1
} finally {
    if (Test-Path -LiteralPath $authPath) { Remove-Item -LiteralPath $authPath -Force -ErrorAction SilentlyContinue }
}
if ($code -ne 0 -and $code -ne $null) { Write-Host ""; Write-Host "[codex exited with code $code]"; }