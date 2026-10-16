param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = "Continue"
$Root = ($Root -replace '["\s]+$', '')

Write-Host "============================================"
Write-Host "   Codex 便携版  ·  本机环境自检"
Write-Host "============================================"
Write-Host "U 盘: $Root"
Write-Host ""

$script:ok = 0; $script:warn = 0; $script:fail = 0
function Report($level, $text) {
    switch ($level) {
        "OK"   { Write-Host "  [OK]   $text"; $script:ok++ }
        "WARN" { Write-Host "  [注意] $text"; $script:warn++ }
        "FAIL" { Write-Host "  [不行] $text"; $script:fail++ }
    }
}

try {
    $v = [Environment]::OSVersion.Version
    if ($v.Major -ge 10) { Report "OK" "Windows 版本 $($v.ToString())（需要 Win10 及以上）" }
    else { Report "FAIL" "Windows 版本 $($v.ToString()) 过低，Codex 需要 Windows 10/11" }
} catch { Report "WARN" "无法读取系统版本" }

if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64" -or $env:PROCESSOR_ARCHITECTURE -eq "ARM64") { Report "OK" "64 位系统（$env:PROCESSOR_ARCHITECTURE）" }
elseif ($env:PROCESSOR_ARCHITECTURE -eq "x86") { Report "FAIL" "系统是 32 位，本套 Codex 需要 64 位 Windows" }
else { Report "WARN" "未知架构 $env:PROCESSOR_ARCHITECTURE" }

$userBase = Join-Path $env:USERPROFILE "CodexPortable"
try {
    New-Item -ItemType Directory -Force -Path $userBase | Out-Null
    $probe = Join-Path $userBase ".w"
    [IO.File]::WriteAllText($probe, "x"); Remove-Item $probe -Force -ErrorAction SilentlyContinue
    Report "OK" "用户目录可写：$userBase"
} catch { Report "FAIL" "用户目录不可写（$userBase）：$($_.Exception.Message)" }

try {
    $di = New-Object System.IO.DriveInfo((Split-Path -Qualifier $userBase))
    $freeGB = [math]::Round($di.AvailableFreeSpace / 1GB, 1)
    if ($freeGB -ge 4) { Report "OK" "系统盘剩余 $freeGB GB（需要约 3 GB）" }
    else { Report "FAIL" "系统盘剩余仅 $freeGB GB，不足以缓存程序（需要约 3 GB）" }
} catch { Report "WARN" "无法读取磁盘剩余空间" }

$need = @("_internal\app\ChatGPT.exe", "codex\codex.exe", "CodexHome\config.toml", "python\python\python.exe")
$miss = @()
foreach ($n in $need) { if (-not (Test-Path -LiteralPath (Join-Path $Root $n))) { $miss += $n } }
if ($miss.Count -eq 0) { Report "OK" "U 盘关键文件完整" } else { foreach ($m in $miss) { Report "FAIL" "缺少文件：$m" } }

if ($PSVersionTable.PSVersion.Major -ge 2) { Report "OK" "PowerShell $($PSVersionTable.PSVersion)" } else { Report "FAIL" "PowerShell 版本过低" }
Report "WARN" "若双击后没反应，检查杀毒软件是否拦截了 U 盘上的程序（需允许运行）"

Write-Host ""
Write-Host "============================================"
Write-Host ("  结果: 通过 {0} 项, 注意 {1} 项, 不通过 {2} 项" -f $script:ok, $script:warn, $script:fail)
Write-Host "============================================"
if ($script:fail -eq 0) {
    Write-Host "  可以在这台电脑上使用！双击【Windows】启动 Codex(桌面版).cmd"
    Write-Host "  首次启动约 1-2 分钟（建立本机缓存），之后 5-15 秒。"
} else {
    Write-Host "  存在不满足的条件，请看上面标 [不行] 的项。"
}
Write-Host ""
Read-Host "按回车关闭"