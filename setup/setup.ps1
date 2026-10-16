param(
    [string]$UsbRoot = "",
    [switch]$Minimal,        # 只装终端版（最小最快，约 160 MB）
    [switch]$NoDesktop,      # 不装桌面版
    [switch]$NoWeb,          # 不装浏览器版（含 Node）
    [switch]$WithPython,     # 额外装便携 Python（做 Excel/PPT/PDF 用）
    [switch]$WithTools,      # 额外装 pandoc / ffmpeg / poppler / uv / jq
    [switch]$SkipDownload,   # 只检查，不下载
    [switch]$KeepDownloads,  # 保留下载的压缩包
    [switch]$Force,          # 目标盘不是可移动盘时也继续
    [switch]$NoMirror,       # 不用第三方镜像，只走 GitHub 直连
    [string]$Mirror = ""     # 指定镜像前缀，例如 https://gh-proxy.com/
)

# ============================================================================
#  Codex 便携版 · 一键装配
#  从各上游官方地址下载程序组件，自动解压、摆放、校验，装完即可直接使用。
#
#  用法（在 U 盘上双击「一键装配.cmd」即可，等价于）：
#    powershell -ExecutionPolicy Bypass -File setup.ps1
#    powershell -ExecutionPolicy Bypass -File setup.ps1 -UsbRoot E:\ -Minimal
#    powershell -ExecutionPolicy Bypass -File setup.ps1 -WithPython -WithTools
#
#  说明：本脚本只从各上游官方发布处下载并摆放程序，不修改、不再分发它们。
#        各组件请遵守其上游许可（Codex / lusipad 重打包 / Node / Python / ...）。
# ============================================================================

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Repo = Split-Path -Parent $PSScriptRoot
$CR = [char]13

function Say($m) { Write-Host $m }
function Title($m) { Say ""; Say ("== " + $m + " ==") }
function MB($b) { return [math]::Round($b / 1MB, 1) }

# ---------- 目标位置：默认取「本仓库所在的那块盘的根目录」 ----------
if (-not $UsbRoot) {
    $q = Split-Path -Qualifier $PSScriptRoot
    if (-not $q) { Say "[错误] 无法判断盘符，请用 -UsbRoot 指定 U 盘根目录（例如 -UsbRoot E:\）"; exit 1 }
    $UsbRoot = $q + "\"
}
$UsbRoot = ($UsbRoot -replace '["\s]+$', '')
if (-not $UsbRoot.EndsWith("\")) { $UsbRoot += "\" }
if (-not (Test-Path -LiteralPath $UsbRoot)) {
    try { New-Item -ItemType Directory -Force -Path $UsbRoot -ErrorAction Stop | Out-Null }
    catch { Say "[错误] 目标路径不存在且无法创建：$UsbRoot"; exit 1 }
}

$drive = $null
try {
    $q2 = Split-Path -Qualifier $UsbRoot
    if ($q2) { $drive = New-Object System.IO.DriveInfo($q2) }
} catch { }
Say "============================================"
Say "   Codex 便携版 · 一键装配"
Say "============================================"
Say ("仓库目录 : " + $Repo)
if ($drive) {
    Say ("目标位置 : " + $UsbRoot + "  (" + $drive.DriveFormat + "，剩余 " + (MB $drive.AvailableFreeSpace) + " MB)")
} else {
    Say ("目标位置 : " + $UsbRoot)
}
if ($drive -and $drive.DriveType -ne "Removable" -and -not $Force) {
    Say ""
    Say "[注意] 这个盘不是可移动盘。装配会往里写约 2 GB 的程序。"
    Say "       确认要装到这里就加 -Force 参数重跑。"
    exit 2
}
Say ""

# ---------------------------------------------------------------------------
#  下载层
#  GitHub 在中国大陆直连常常只有几十 KB/s，而镜像能到几百 KB/s，所以：
#    1) 先对每个候选源做 5 秒测速，挑最快的那个；
#    2) 下载完用官方 SHA-256 校验（来自 GitHub Release API 的 digest 字段），
#       所以即使经过第三方镜像，也能保证拿到的字节和官方完全一致；
#    3) 下载停滞超过 60 秒就换下一个源。
#  不想用第三方镜像：加 -NoMirror ；想指定镜像：-Mirror https://xxx/
# ---------------------------------------------------------------------------
$script:Mirrors = @(
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
    "https://hub.gitmirror.com/"
)
if ($Mirror) { $script:Mirrors = @($Mirror) }
if ($NoMirror) { $script:Mirrors = @() }

function Get-CandidateUrls($Url) {
    $list = @()
    if ($Url -like "https://github.com/*") {
        foreach ($m in $script:Mirrors) { $list += ($m + $Url) }
    }
    $list += $Url
    return $list
}

function Test-Sha256($Path, $Expect) {
    try {
        $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        return ($h -eq $Expect.ToLower())
    } catch { return $false }
}

# 测速：拉前 1 MB 看速度（KB/s），拿不到就算 0
function Measure-Source($Url, $Seconds = 5) {
    $in = $null; $resp = $null
    try {
        $probe = 1MB
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = "codex-usb-portable-setup"
        $req.Timeout = 8000
        $req.ReadWriteTimeout = 8000
        try { $req.AddRange(0, $probe - 1) } catch { }
        $resp = $req.GetResponse()
        $in = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        $got = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $Seconds -and $got -lt $probe) {
            $n = $in.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $got += $n
        }
        $sw.Stop()
        $in.Close(); $resp.Close()
        if ($got -lt 32KB -or $sw.Elapsed.TotalSeconds -le 0) { return 0 }
        return [int](($got / 1KB) / $sw.Elapsed.TotalSeconds)
    } catch {
        if ($in) { try { $in.Close() } catch {} }
        return 0
    }
}

# 单源下载（带进度、停滞保护、大小校验）
function Download-One($Url, $Dest, $Label) {
    $out = $null; $in = $null; $resp = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = "codex-usb-portable-setup"
        $req.Timeout = 15000
        $req.ReadWriteTimeout = 30000
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $total = $resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($Dest)
        $buf = New-Object byte[] 1MB
        $done = 0; $last = Get-Date; $lastBytes = 0; $stall = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $n = 0
            try { $n = $in.Read($buf, 0, $buf.Length) } catch { $n = 0 }
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $done += $n
            if (((Get-Date) - $last).TotalSeconds -ge 2) {
                $last = Get-Date
                $spd = 0; if ($sw.Elapsed.TotalSeconds -gt 0) { $spd = ($done / 1MB) / $sw.Elapsed.TotalSeconds }
                if ($done -le $lastBytes) { $stall += 2 } else { $stall = 0 }
                $lastBytes = $done
                $line = "      " + $Label + "  " + [math]::Round($done / 1MB) + " MB"
                if ($total -gt 0) { $line = $line + " / " + [math]::Round($total / 1MB) + " MB (" + [math]::Round(100 * $done / $total) + "%)" }
                Write-Host ([char]13 + $line + "  " + [math]::Round($spd, 2) + " MB/s         ") -NoNewline
                if ($stall -ge 60) { throw "下载停滞超过 60 秒" }
            }
        }
        $out.Close(); $out = $null
        $in.Close(); $in = $null
        $resp.Close(); $resp = $null
        Say ""
        if ($total -gt 0 -and $done -lt ($total * 0.99)) { throw ("下载不完整 " + $done + " / " + $total + " 字节") }
        if ($done -lt 1MB) { throw "下载到的数据太少" }
        return $true
    } catch {
        if ($out) { try { $out.Close() } catch {} }
        if ($in) { try { $in.Close() } catch {} }
        if ($resp) { try { $resp.Close() } catch {} }
        throw
    }
}

# 对外的下载入口：缓存复用 → 测速选源 → 下载 → 校验
function Get-Download($Url, $Dest, $Label, $Sha256 = "") {
    if (Test-Path -LiteralPath $Dest) {
        $sz = (Get-Item -LiteralPath $Dest).Length
        if ($sz -gt 1MB -and (-not $Sha256 -or (Test-Sha256 $Dest $Sha256))) {
            Say ("  [复用] 已有下载缓存 " + (MB $sz) + " MB")
            return $true
        }
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    }
    $cands = @(Get-CandidateUrls $Url)
    if ($cands.Count -gt 1) {
        Say ("  [测速] " + $cands.Count + " 个来源各探 5 秒 ...")
        $scored = @()
        foreach ($c in $cands) {
            $hname = ([Uri]$c).Host
            $kb = Measure-Source $c
            if ($kb -gt 0) { Say ("    " + $hname + " : " + $kb + " KB/s"); $scored += [pscustomobject]@{ U = $c; K = $kb } }
            else { Say ("    " + $hname + " : 不可用") }
        }
        if ($scored.Count -gt 0) { $cands = @($scored | Sort-Object K -Descending | ForEach-Object { $_.U }) }
    }
    foreach ($c in $cands) {
        Say ("  [下载] " + $Label + "  ←  " + ([Uri]$c).Host)
        try {
            $null = Download-One $c $Dest $Label
            if ($Sha256) {
                if (Test-Sha256 $Dest $Sha256) { Say ("    [校验] SHA-256 与官方一致（" + $Sha256.Substring(0, 12) + "...）"); return $true }
                Say "    [校验失败] 内容与官方不一致，换下一个来源重试"
                Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
            } else {
                Say "    [完成] 该来源未提供官方校验值，已按大小做完整性检查"
                return $true
            }
        } catch {
            Say ("    [失败] " + $_.Exception.Message)
            Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        }
    }
    return $false
}

# 从 GitHub API 解析最新发布的资产地址 + 官方 SHA-256（资产名带版本号，不能写死）
function Get-GitHubAsset($RepoName, $Regex) {
    try {
        $api = "https://api.github.com/repos/" + $RepoName + "/releases/latest"
        $j = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "codex-usb-portable-setup" } -TimeoutSec 60
        $hit = $j.assets | Where-Object { $_.name -match $Regex } | Select-Object -First 1
        if ($hit) {
            $sha = ""
            if ($hit.digest -and ($hit.digest -like "sha256:*")) { $sha = $hit.digest.Substring(7) }
            return [pscustomobject]@{ Url = $hit.browser_download_url; Sha256 = $sha; Name = $hit.name; Tag = $j.tag_name; SizeMB = [math]::Round($hit.size / 1MB, 1) }
        }
    } catch { }
    return $null
}

# ---------- 解压与摆放 ----------
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
function Expand-Zip($ZipPath, $DestDir) {
    if (Test-Path -LiteralPath $DestDir) { Remove-Item -LiteralPath $DestDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
}
function Get-SingleTopDir($Dir) {
    $all = @(Get-ChildItem -LiteralPath $Dir -Force)
    if ($all.Count -eq 1 -and $all[0].PSIsContainer) { return $all[0].FullName }
    return $Dir
}
function Install-Payload {
    param($ZipPath, $ProbeName, $UsbDest, [int]$UpLevels = 0, [switch]$StripTop, $WorkDir)
    Expand-Zip $ZipPath $WorkDir
    $root = $WorkDir
    if ($StripTop) { $root = Get-SingleTopDir $root }
    $found = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $ProbeName -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($found.Count -eq 0) { throw ("解压后没找到 " + $ProbeName) }
    $dir = Split-Path $found[0].FullName -Parent
    for ($i = 0; $i -lt $UpLevels; $i++) { $dir = Split-Path $dir -Parent }
    if (Test-Path -LiteralPath $UsbDest) { Remove-Item -LiteralPath $UsbDest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $UsbDest | Out-Null
    robocopy $dir $UsbDest /E /R:1 /W:1 /MT:16 /NFL /NDL /NP /NJH /NJS | Out-Null
    return $dir
}

# ============================================================================
#  1/4  铺启动器脚本
# ============================================================================
Title "1/4 铺启动器脚本"
$srcUsb = Join-Path $Repo "usb"
if (Test-Path -LiteralPath $srcUsb) {
    robocopy $srcUsb $UsbRoot /E /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
    Say ("  已写入 " + $UsbRoot)
} else {
    Say "  [警告] 仓库里没有 usb\ 目录，跳过。"
}
$homeDir = Join-Path $UsbRoot "CodexHome"
New-Item -ItemType Directory -Force -Path $homeDir | Out-Null
foreach ($f in @("config.toml", "AGENTS.md")) {
    $t = Join-Path $srcUsb ("CodexHome\" + $f)
    $d = Join-Path $homeDir $f
    if ((Test-Path -LiteralPath $t) -and -not (Test-Path -LiteralPath $d)) {
        Copy-Item -LiteralPath $t -Destination $d -Force
        Say ("  放入模板：" + $f + "（已存在的不覆盖）")
    }
}

# ============================================================================
#  2/4  组件装配
# ============================================================================
Title "2/4 组件装配"
$cache = Join-Path $env:TEMP "codex-usb-setup"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$needDesktop = -not ($Minimal -or $NoDesktop)
$needWeb = -not ($Minimal -or $NoWeb)

# --- A. Codex 命令行版（必需）---
$codexExe = Join-Path $UsbRoot "codex\codex.exe"
if (Test-Path -LiteralPath $codexExe) {
    Say "  [已有] Codex 命令行版"
} elseif ($SkipDownload) {
    Say "  [缺少] Codex 命令行版（-SkipDownload，未下载）"
} else {
    Say "  [查询] Codex 命令行版最新发布 ..."
    $zip = Join-Path $cache "codex-cli.zip"
    $asset = Get-GitHubAsset "openai/codex" "codex-x86_64-pc-windows-msvc\.exe\.zip$"
    if (-not $asset) {
        Say "    [失败] 查不到下载地址（网络问题？），请手动到 https://github.com/openai/codex/releases 下载"
    } elseif (Get-Download $asset.Url $zip "codex-cli" $asset.Sha256) {
        try {
            Expand-Zip $zip (Join-Path $cache "codex-cli-x")
            $dest = Join-Path $UsbRoot "codex"
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            robocopy (Join-Path $cache "codex-cli-x") $dest /E /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
            $longName = Join-Path $dest "codex-x86_64-pc-windows-msvc.exe"
            if (Test-Path -LiteralPath $longName) { Move-Item -LiteralPath $longName -Destination (Join-Path $dest "codex.exe") -Force }
            if (Test-Path -LiteralPath (Join-Path $dest "codex.exe")) { Say "    [完成] codex\codex.exe 就位" }
            else { Say "    [失败] 没找到解压出来的 exe" }
        } catch { Say ("    [失败] " + $_.Exception.Message) }
    }
}

# --- B. 桌面版 ---
if ($needDesktop) {
    if (Test-Path -LiteralPath (Join-Path $UsbRoot "_internal\app\ChatGPT.exe")) {
        Say "  [已有] 桌面版程序"
    } elseif ($SkipDownload) {
        Say "  [缺少] 桌面版程序（-SkipDownload，未下载）"
    } else {
        Say "  [查询] 桌面版最新发布 ..."
        $asset = Get-GitHubAsset "lusipad/unofficial-codex-app-offline" "portable\.zip$"
        if (-not $asset) {
            Say "    [失败] 查不到下载地址。请手动到 https://github.com/lusipad/unofficial-codex-app-offline/releases"
            Say "           下载 portable.zip，解压后把含 app\ChatGPT.exe 的那层目录改名为 _internal 放进 U 盘根目录。"
        } else {
            Say ("  [下载] 桌面版程序（" + [math]::Round($asset.SizeMB) + " MB，解压后约 2.3 GB，最慢的一步）...")
            $zip = Join-Path $cache "desktop.zip"
            if (Get-Download $asset.Url $zip "desktop" $asset.Sha256) {
                try {
                    Say "    [解压] 解压中，请耐心等（这一步要几分钟）..."
                    $null = Install-Payload -ZipPath $zip -ProbeName "ChatGPT.exe" -UsbDest (Join-Path $UsbRoot "_internal") -UpLevels 1 -WorkDir (Join-Path $cache "desktop-x")
                    Say "    [完成] _internal\app\ChatGPT.exe 就位"
                } catch { Say ("    [失败] " + $_.Exception.Message) }
            }
        }
    }
}

# --- C. 浏览器界面 + Node ---
if ($needWeb) {
    if (Test-Path -LiteralPath (Join-Path $UsbRoot "web\start-web.mjs")) {
        Say "  [已有] 浏览器界面"
    } elseif ($SkipDownload) {
        Say "  [缺少] 浏览器界面（-SkipDownload，未下载）"
    } else {
        $asset = Get-GitHubAsset "lusipad/unofficial-codex-app-offline" "web\.zip$"
        if (-not $asset) { Say "    [跳过] 查不到 web 包地址" }
        else {
            Say "  [下载] 浏览器界面（约 217 MB）..."
            $zip = Join-Path $cache "web.zip"
            if (Get-Download $asset.Url $zip "web" $asset.Sha256) {
                try {
                    $null = Install-Payload -ZipPath $zip -ProbeName "start-web.mjs" -UsbDest (Join-Path $UsbRoot "web") -UpLevels 0 -StripTop -WorkDir (Join-Path $cache "web-x")
                    Say "    [完成] web\start-web.mjs 就位"
                } catch { Say ("    [失败] " + $_.Exception.Message) }
            }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $UsbRoot "node\node.exe")) {
        Say "  [已有] 便携 Node"
    } elseif ($SkipDownload) {
        Say "  [缺少] 便携 Node（-SkipDownload，未下载）"
    } else {
        Say "  [下载] 便携 Node LTS（约 30 MB）..."
        $zip = Join-Path $cache "node.zip"
        if (Get-Download "https://nodejs.org/dist/latest-lts/win-x64/node.zip" $zip "node") {
            try {
                $null = Install-Payload -ZipPath $zip -ProbeName "node.exe" -UsbDest (Join-Path $UsbRoot "node") -UpLevels 0 -StripTop -WorkDir (Join-Path $cache "node-x")
                Say "    [完成] node\node.exe 就位"
            } catch { Say ("    [失败] " + $_.Exception.Message) }
        }
    }
}

# --- D. 便携 Python（可选）---
if ($WithPython) {
    if (Test-Path -LiteralPath (Join-Path $UsbRoot "python\python\python.exe")) {
        Say "  [已有] 便携 Python"
    } elseif ($SkipDownload) {
        Say "  [缺少] 便携 Python（-SkipDownload，未下载）"
    } else {
        Say "  [查询] 可用的 Python embed 包 ..."
        $pyUrl = ""
        foreach ($v in @("3.13.9", "3.13.8", "3.13.7", "3.12.11", "3.12.10", "3.12.9")) {
            $u = "https://www.python.org/ftp/python/" + $v + "/python-" + $v + "-embed-amd64.zip"
            try {
                $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 30
                if ($r.StatusCode -eq 200) { $pyUrl = $u; break }
            } catch { }
        }
        if (-not $pyUrl) { Say "    [跳过] 找不到可用的 Python embed 包，请手动到 python.org 下载后解压到 python\python\" }
        else {
            Say ("    " + $pyUrl)
            $zip = Join-Path $cache "python.zip"
            if (Get-Download $pyUrl $zip "python") {
                try {
                    $dest = Join-Path $UsbRoot "python\python"
                    New-Item -ItemType Directory -Force -Path $dest | Out-Null
                    Expand-Zip $zip $dest
                    Say "    [完成] python\python\python.exe 就位"
                    Say "    [提示] 装常用库：python\python\python.exe -m pip install openpyxl python-docx python-pptx reportlab pdfplumber"
                } catch { Say ("    [失败] " + $_.Exception.Message) }
            }
        }
    }
}

# --- E. 工具链（可选）---
if ($WithTools) {
    $toolPlan = @(
        @{ Name = "uv";      Probe = "uv.exe";     Dest = "tools\uv";      Url = ""; Gh = "astral-sh/uv"; GhRe = "uv-x86_64-pc-windows-msvc\.zip$" },
        @{ Name = "pandoc";  Probe = "pandoc.exe"; Dest = "tools\pandoc";  Url = ""; Gh = "jgm/pandoc"; GhRe = "windows-x86_64\.zip$" },
        @{ Name = "poppler"; Probe = "pdftoppm.exe"; Dest = "tools\poppler"; Url = ""; Gh = "oschwartz10612/poppler-windows"; GhRe = "Release-.*\.zip$" },
        @{ Name = "ffmpeg";  Probe = "ffmpeg.exe"; Dest = "tools\ffmpeg";  Url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"; Gh = ""; GhRe = "" }
    )
    foreach ($t in $toolPlan) {
        if (Test-Path -LiteralPath (Join-Path $UsbRoot $t.Dest)) { Say ("  [已有] " + $t.Name); continue }
        if ($SkipDownload) { Say ("  [缺少] " + $t.Name + "（-SkipDownload）"); continue }
        $sha = ""
        if ($t.Gh) {
            $a = Get-GitHubAsset $t.Gh $t.GhRe
            if ($a) { $t.Url = $a.Url; $sha = $a.Sha256 }
        }
        if (-not $t.Url) { Say ("  [跳过] " + $t.Name + "：查不到地址，可手动下载后放进 " + $t.Dest); continue }
        Say ("  [下载] " + $t.Name + " ...")
        $zip = Join-Path $cache ($t.Name + ".zip")
        if (Get-Download $t.Url $zip $t.Name $sha) {
            try {
                $destFull = Join-Path $UsbRoot $t.Dest
                Expand-Zip $zip (Join-Path $cache ($t.Name + "-x"))
                $root = Join-Path $cache ($t.Name + "-x")
                $top = Get-SingleTopDir $root
                New-Item -ItemType Directory -Force -Path $destFull | Out-Null
                robocopy $top $destFull /E /R:1 /W:1 /MT:16 /NFL /NDL /NP /NJH /NJS | Out-Null
                Say ("    [完成] " + $t.Dest)
            } catch { Say ("    [失败] " + $_.Exception.Message) }
        }
    }
    $jqDir = Join-Path $UsbRoot "tools\jq"
    if (-not (Test-Path -LiteralPath (Join-Path $jqDir "jq.exe")) -and -not $SkipDownload) {
        Say "  [下载] jq ..."
        New-Item -ItemType Directory -Force -Path $jqDir | Out-Null
        $jqa = Get-GitHubAsset "jqlang/jq" "jq-windows-amd64\.exe$"
        $jqUrl = "https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
        $jqSha = ""
        if ($jqa) { $jqUrl = $jqa.Url; $jqSha = $jqa.Sha256 }
        if (Get-Download $jqUrl (Join-Path $jqDir "jq.exe") "jq" $jqSha) {
            Say "    [完成] tools\jq\jq.exe"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $UsbRoot "tools\7zip"))) {
        Say "  [可选] 7-Zip 请手动装：从 https://www.7-zip.org/ 下载后把 7z.exe / 7z.dll 放进 tools\7zip\"
    }
}

# ============================================================================
#  3/4  收尾
# ============================================================================
Title "3/4 收尾"
New-Item -ItemType Directory -Force -Path (Join-Path $homeDir "tmp") | Out-Null
if (-not $KeepDownloads) {
    $keep = @("codex-cli.zip", "desktop.zip", "web.zip", "node.zip", "python.zip")
    foreach ($f in (Get-ChildItem -LiteralPath $cache -File -ErrorAction SilentlyContinue)) {
        if ($keep -notcontains $f.Name) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
    Say ("  下载缓存保留在 " + $cache + "（加 -KeepDownloads 可保留全部压缩包）")
}

# ============================================================================
#  4/4  自检
# ============================================================================
Title "4/4 自检"
$checks = @(
    @{ N = "终端入口 codex\codex.exe";              P = "codex\codex.exe";              Must = $true },
    @{ N = "终端启动器 codex\launch-cli.ps1";        P = "codex\launch-cli.ps1";         Must = $true },
    @{ N = "桌面入口 _internal\app\ChatGPT.exe";     P = "_internal\app\ChatGPT.exe";    Must = (-not $Minimal) },
    @{ N = "桌面启动器 _internal\launch-desktop.ps1"; P = "_internal\launch-desktop.ps1"; Must = (-not $Minimal) },
    @{ N = "浏览器界面 web\start-web.mjs";           P = "web\start-web.mjs";            Must = $false },
    @{ N = "便携 Node node\node.exe";                P = "node\node.exe";                Must = $false },
    @{ N = "配置模板 CodexHome\config.toml";         P = "CodexHome\config.toml";        Must = $true },
    @{ N = "密钥工具 CodexHome\set-api-key.ps1";     P = "CodexHome\set-api-key.ps1";    Must = $true }
)
$fail = 0
foreach ($c in $checks) {
    $ok = Test-Path -LiteralPath (Join-Path $UsbRoot $c.P)
    if ($ok) { Say ("  [OK]   " + $c.N) }
    elseif ($c.Must) { Say ("  [缺少] " + $c.N); $fail++ }
    else { Say ("  [未装] " + $c.N + "（可选）") }
}
$codexExe = Join-Path $UsbRoot "codex\codex.exe"
if (Test-Path -LiteralPath $codexExe) {
    try {
        $env:CODEX_HOME = Join-Path $UsbRoot "CodexHome"
        $v = & $codexExe --version 2>&1 | Select-Object -First 1
        Say ("  [验证] codex --version → " + $v)
    } catch { Say ("  [验证] 可执行性检查失败：" + $_.Exception.Message) }
}
Say ""
Say "============================================"
if ($fail -eq 0) {
    Say "  装配完成，可以用了。接下来："
    Say "  1) 双击 CodexHome\设置API密钥.cmd   把 API Key 存进分片"
    Say "     （不想放 Key 就改用官方账号：在 U 盘根目录执行  codex login）"
    Say "  2) 双击 【Windows】启动 Codex(桌面版).cmd 开始使用"
    Say "     想秒开就用 【Windows】启动 Codex(终端).cmd"
} else {
    Say ("  还缺 " + $fail + " 个必需项，见上面的 [缺少]，重新运行本脚本即可续装。")
}
Say "============================================"
