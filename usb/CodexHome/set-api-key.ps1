param(
    [string]$CodexHome = $PSScriptRoot,
    [string]$Mask = "codex-portable-2026"
)

# ============================================================
#  Codex 便携版 · API 密钥分片生成
#  作用：把 API Key 拆成 3 个混淆分片存进 CodexHome，
#        启动器开机时还原成 auth.json（用完即删）。
#  算法：按字节切 3 段 → 每段独立与 $Mask 循环 XOR → 各自 Base64。
#        必须与启动器（launch-*.ps1）保持一致。
# ============================================================

$ErrorActionPreference = "Stop"
Write-Host "============================================"
Write-Host "   Codex 便携版 · 设置 API 密钥"
Write-Host "============================================"
Write-Host "目标目录: $CodexHome"
Write-Host ""

if (-not (Test-Path -LiteralPath $CodexHome)) { New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null }

$sec = Read-Host "请粘贴你的 API Key（输入时不显示，回车确认）" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$key = ""
try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

if ([string]::IsNullOrWhiteSpace($key)) { Write-Host "[错误] 没有输入内容，未做任何修改。"; exit 1 }
$key = $key.Trim()
if ($key.Length -lt 8) { Write-Host "[错误] 这个 Key 太短，请检查后重试。"; exit 1 }

# --- 生成 3 个分片 ---
$bytes = [Text.Encoding]::UTF8.GetBytes($key)
$maskBytes = [Text.Encoding]::ASCII.GetBytes($Mask)
$n = $bytes.Length
$third = [int][Math]::Floor(($n + 2) / 3)
$segments = @()
for ($i = 0; $i -lt 3; $i++) {
    $start = $i * $third
    if ($start -ge $n) { $segments += ,@(); continue }
    $len = [Math]::Min($third, $n - $start)
    $segments += ,@($bytes[$start..($start + $len - 1)])
}

$names = @("user-settings.dat", "window-layout.dat", "cache-index.dat")
for ($k = 0; $k -lt 3; $k++) {
    $seg = $segments[$k]
    $x = New-Object byte[] $seg.Length
    for ($i = 0; $i -lt $seg.Length; $i++) { $x[$i] = $seg[$i] -bxor $maskBytes[$i % $maskBytes.Length] }
    $b64 = [Convert]::ToBase64String($x)
    [IO.File]::WriteAllText((Join-Path $CodexHome $names[$k]), $b64, [Text.Encoding]::ASCII)
    Write-Host ("  [写入] " + $names[$k] + "  (" + $b64.Length + " 字符)")
}

# --- 自校验：按启动器的算法还原一遍 ---
try {
    $chk = ""
    foreach ($nm in $names) {
        $raw = [Convert]::FromBase64String(([IO.File]::ReadAllText((Join-Path $CodexHome $nm))).Trim())
        for ($i = 0; $i -lt $raw.Length; $i++) { $raw[$i] = $raw[$i] -bxor $maskBytes[$i % $maskBytes.Length] }
        $chk += [Text.Encoding]::UTF8.GetString($raw)
    }
    if ($chk -eq $key) { Write-Host ""; Write-Host "[成功] 自校验通过：3 个分片能正确还原出你的密钥。" }
    else { Write-Host ""; Write-Host "[警告] 自校验不一致，请重跑一次。" }
} catch {
    Write-Host ""; Write-Host ("[警告] 自校验失败：" + $_.Exception.Message)
}

Write-Host ""
Write-Host "提示：分片只是混淆、不是加密。密钥能还原，请妥善保管这个 U 盘。"
Write-Host "      （不想把密钥放 U 盘的人，可以改用官方账号登录：codex login）"
