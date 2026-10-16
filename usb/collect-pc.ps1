param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [switch]$NoBench,
    [string]$LocalBenchDir = "",
    [switch]$Quiet
)

# ===========================================================================
#  Codex 便携版 · 宿主电脑环境档案采集器   v1.1   (2026-10-13)
# ---------------------------------------------------------------------------
#  怎么用：把 U 盘插到任意一台 Windows 电脑上，双击
#          【Windows】收集本机环境档案.cmd
#  干什么：采集这台电脑的硬件 / 系统 / 兼容性 / 实测性能，写回 U 盘的
#          电脑档案\ 目录，作为后续优化「便携版 Codex」的依据。
#  安全：  不需要管理员权限；不联网；不读取任何个人文件内容；
#          用户名打码；机器序列号只保存哈希；测速用的临时文件跑完即删。
#  输出：  <U盘>\电脑档案\索引.md
#          <U盘>\电脑档案\<时间>_<机器名>.md
#          <U盘>\电脑档案\raw\<时间>_<机器名>.json
# ===========================================================================

$ErrorActionPreference = "Continue"
$Root = ($Root -replace '["\s]+$', '')
$script:Quiet = $Quiet.IsPresent
$CollectorVersion = "1.1"
$CRLF = ([char]13 + [char]10)

# ---------- 小工具 ----------
function Say([string]$m) { if (-not $script:Quiet) { Write-Host $m } }
function Head([string]$m) { Say ""; Say ("== " + $m + " ==") }
function Note([string]$m) { Say ("   " + $m) }

function Get-Safe {
    param([scriptblock]$Block, $Default = $null)
    try {
        $r = & $Block
        if ($null -eq $r) { return $Default }
        return $r
    } catch { return $Default }
}

function Get-Hash([string]$Text, [int]$Len = 16) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        $sb = New-Object System.Text.StringBuilder
        foreach ($b in $bytes) { [void]$sb.Append($b.ToString("x2")) }
        $s = $sb.ToString()
        if ($s.Length -lt $Len) { return $s }
        return $s.Substring(0, $Len)
    } catch { return "" }
}

function Fmt-Size($Bytes) {
    if ($null -eq $Bytes) { return "?" }
    try { $b = [double]$Bytes } catch { return "?" }
    if ($b -ge 1GB) { return ("{0:N1} GB" -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ("{0:N1} MB" -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ("{0:N0} KB" -f ($b / 1KB)) }
    return ("{0:N0} B" -f $b)
}

function Fmt-Text($v, $Default = "-") {
    if ($null -eq $v) { return $Default }
    $s = [string]$v
    if ($s.Trim() -eq "") { return $Default }
    return $s.Trim()
}

# ===========================================================================
#  开场
# ===========================================================================
$t0 = Get-Date
Say "============================================"
Say "  Codex 便携版 · 宿主电脑环境档案采集 v$CollectorVersion"
Say "============================================"
Say "U 盘位置 : $Root"
Say "开始时间 : $($t0.ToString('yyyy-MM-dd HH:mm:ss'))"
Say ""

if (-not (Test-Path -LiteralPath $Root)) { Say "[错误] 找不到 U 盘目录：$Root"; exit 1 }
if (-not (Test-Path -LiteralPath (Join-Path $Root "CodexHome"))) {
    Say "[警告] 这个目录不像是本 U 盘（没有 CodexHome）。仍会继续，但请确认 -Root 参数。"
}

# 后台大写入进程会让测速失真（交接文件坑 8：曾误判 U 盘掉速）
$busyProcs = Get-Safe { @(Get-Process -Name robocopy,7za,xcopy,FastCopy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique) } @()
if ($busyProcs.Count -gt 0) { Say "[注意] 检测到后台写入进程：$($busyProcs -join ', ')  → 本次将跳过测速，避免数据失真。" }

# ===========================================================================
#  1/7  机器身份
# ===========================================================================
Head "1/7 机器身份"
$cs     = Get-Safe { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
$csProd = Get-Safe { Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop }
$bios   = Get-Safe { Get-CimInstance Win32_BIOS -ErrorAction Stop }
$board  = Get-Safe { Get-CimInstance Win32_BaseBoard -ErrorAction Stop }
$os     = Get-Safe { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }

$computerName = Fmt-Text $env:COMPUTERNAME "UNKNOWN"
$mfg   = Fmt-Text $cs.Manufacturer ""
$model = Fmt-Text $cs.Model ""
$vmHints = "VMware|VirtualBox|QEMU|Xen|Parallels|Virtual|Hyper-V|Bochs|KVM|vbox"
$isVirtual = $false
if (($mfg + " " + $model) -match $vmHints) { $isVirtual = $true }
$hypervisor = $false
if ($cs -and $cs.HypervisorPresent -eq $true) { $hypervisor = $true }

$serial = ""
if ($csProd) { $serial = Fmt-Text $csProd.UUID "" }
if (-not $serial -and $bios) { $serial = Fmt-Text $bios.SerialNumber "" }
$machineKey = Get-Hash ($computerName + "|" + $serial)
if (-not $machineKey) { $machineKey = Get-Hash $computerName }

$userMasked = ""
try {
    $u = [string]$env:USERNAME
    if ($u.Length -ge 2) { $userMasked = $u.Substring(0,1) + ("*" * ([Math]::Min(6, $u.Length - 1))) }
    elseif ($u.Length -eq 1) { $userMasked = "*" }
} catch { $userMasked = "*" }

$isAdmin = Get-Safe {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
} $false

$pcType = "-"
if ($cs) {
    if ($cs.PCSystemType -eq 2) { $pcType = "笔记本/平板" } elseif ($cs.PCSystemType -eq 1) { $pcType = "台式机" }
}
$osInstall = "-"
if ($os -and $os.InstallDate) { $osInstall = ([datetime]$os.InstallDate).ToString("yyyy-MM-dd") }

Note ("机器名   : " + $computerName + "    (标识 " + $machineKey + ")")
Note ("品牌型号 : " + (Fmt-Text ($mfg + " " + $model) "-") + "    " + $pcType)
Note ("系统安装 : " + $osInstall + "    虚拟机: " + $(if ($isVirtual) { "是" } else { "否" }) + "    Hypervisor: " + [string]$hypervisor + "    会话: " + (Fmt-Text $env:SESSIONNAME "-"))
Note ("当前用户 : " + $userMasked + "    管理员权限: " + $(if ($isAdmin) { "有" } else { "无（不需要，正常）" }))

# ===========================================================================
#  2/7  系统与策略
# ===========================================================================
Head "2/7 系统与策略"
$cv = Get-Safe { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop }
$fsReg = Get-Safe { Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction Stop }
$cpReg = Get-Safe { Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction Stop }
$uacReg = Get-Safe { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop }
$pwshPol = Get-Safe { Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell' -ErrorAction Stop }

$osCaption = Fmt-Text $os.Caption "-"
$osVersion = Fmt-Text $os.Version "-"
$osBuild   = Fmt-Text $os.BuildNumber "-"
$osUbr     = Fmt-Text $cv.UBR ""
$edition   = Fmt-Text $cv.EditionID "-"
$dispVer   = Fmt-Text $cv.DisplayVersion ""
$osArch    = Fmt-Text $os.OSArchitecture "-"
$productType = "-"
if ($os) { if ($os.ProductType -eq 1) { $productType = "工作站" } elseif ($os.ProductType -eq 2) { $productType = "域控" } elseif ($os.ProductType -eq 3) { $productType = "服务器" } }

$locale = "-"; $uiLang = "-"; $sysLocale = "-"; $tz = "-"
Get-Safe { $script:localeTmp = [System.Globalization.CultureInfo]::CurrentCulture.Name } | Out-Null
if ($script:localeTmp) { $locale = $script:localeTmp }
Get-Safe { $script:uiTmp = (Get-UICulture).Name } | Out-Null
if ($script:uiTmp) { $uiLang = $script:uiTmp }
Get-Safe { $script:sysLocTmp = (Get-WinSystemLocale).Name } | Out-Null
if ($script:sysLocTmp) { $sysLocale = $script:sysLocTmp }
Get-Safe { $script:tzTmp = (Get-TimeZone).Id } | Out-Null
if ($script:tzTmp) { $tz = $script:tzTmp }

$acp = Fmt-Text $cpReg.ACP ""; $oemcp = Fmt-Text $cpReg.OEMCP ""
$longPaths = 0
if ($fsReg -and $null -ne $fsReg.LongPathsEnabled) { $longPaths = [int]$fsReg.LongPathsEnabled }

$epEff = Fmt-Text (Get-Safe { (Get-ExecutionPolicy).ToString() } "?") "?"
$epList = Get-Safe { @(Get-ExecutionPolicy -List | ForEach-Object { $_.Scope.ToString() + "=" + $_.ExecutionPolicy.ToString() }) } @()
$epMachinePolicy = Fmt-Text $pwshPol.ExecutionPolicy ""

$uacLua = "-"; $uacConsent = "-"
if ($uacReg) {
    if ($null -ne $uacReg.EnableLUA) { $uacLua = [string]$uacReg.EnableLUA }
    if ($null -ne $uacReg.ConsentPromptBehaviorAdmin) { $uacConsent = [string]$uacReg.ConsentPromptBehaviorAdmin }
}

$hiberboot = Fmt-Text (Get-Safe { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled } "") ""
$powerRaw = Fmt-Text (Get-Safe { (powercfg /getactivescheme) -join " " } "") ""
$powerName = ""
if ($powerRaw -match '\(([^()]+)\)\s*$') { $powerName = $matches[1] }

$bats = Get-Safe { @(Get-CimInstance Win32_Battery -ErrorAction Stop) } @()
$hasBattery = ($bats.Count -gt 0)
$onAc = "-"
if ($hasBattery) {
    $st = Get-Safe { [int]$bats[0].BatteryStatus } $null
    if ($null -ne $st) { if ($st -eq 2) { $onAc = "接通电源" } else { $onAc = "使用电池（状态码 " + $st + "）" } }
}

$licDesc = Fmt-Text (Get-Safe { (Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop | Where-Object { $_.PartialProductKey -and $_.Name -like "Windows*" } | Select-Object -First 1).Description } "") ""

$psVer = Fmt-Text $PSVersionTable.PSVersion ""
$psEd = Fmt-Text $PSVersionTable.PSEdition "Desktop"

Note ("系统     : " + $osCaption + "  (" + $osVersion + "." + $osUbr + ", " + $edition + " " + $dispVer + ")")
Note ("地区语言 : " + $locale + " / " + $uiLang + "    代码页 ACP=" + $acp + " OEM=" + $oemcp)
Note ("长路径   : " + $longPaths + "    脚本策略: " + $epEff + "    机器策略: " + (Fmt-Text $epMachinePolicy "未设置"))
Note ("电源     : " + (Fmt-Text $powerName "?") + "    " + $onAc)
if ($epMachinePolicy -and ($epMachinePolicy -ne "Undefined") -and ($epMachinePolicy -ne "Unrestricted") -and ($epMachinePolicy -ne "RemoteSigned")) {
    Note "[风险] 组策略锁定了 PowerShell 执行策略 = $epMachinePolicy，启动器可能被拒绝运行"
}

# ===========================================================================
#  3/7  硬件
# ===========================================================================
Head "3/7 硬件"
$cpu = Get-Safe { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
$cpuName = Fmt-Text $cpu.Name "-"
$cpuCores = 0; $cpuThreads = 0; $cpuMHz = 0; $cpuL3 = 0; $cpuVirt = "-"
if ($cpu) {
    $cpuCores = [int]$cpu.NumberOfCores
    $cpuThreads = [int]$cpu.NumberOfLogicalProcessors
    $cpuMHz = [int]$cpu.MaxClockSpeed
    if ($null -ne $cpu.L3CacheSize) { $cpuL3 = [int]$cpu.L3CacheSize }
    if ($null -ne $cpu.VirtualizationFirmwareEnabled) { $cpuVirt = [string]$cpu.VirtualizationFirmwareEnabled }
}

$avx2 = $null
Get-Safe {
    if (-not ("Win32.CpuFeat" -as [type])) {
        Add-Type -Namespace Win32 -Name CpuFeat -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f);
"@ -ErrorAction Stop
    }
    $script:avx2v = [bool][Win32.CpuFeat]::IsProcessorFeaturePresent(40)
} | Out-Null
if ($null -ne $script:avx2v) { $avx2 = $script:avx2v }

$ramBytes = $null
if ($cs) { $ramBytes = $cs.TotalPhysicalMemory }
$ramMods = Get-Safe { @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop) } @()
$ramGroups = [ordered]@{}
foreach ($m in $ramMods) {
    $typeName = ""
    if ($null -ne $m.SMBIOSMemoryType) {
        switch ([int]$m.SMBIOSMemoryType) {
            26 { $typeName = "DDR4" } 34 { $typeName = "DDR5" } 24 { $typeName = "DDR3" } 21 { $typeName = "DDR2" }
            30 { $typeName = "LPDDR4" } 35 { $typeName = "LPDDR5" } 29 { $typeName = "LPDDR3" } 28 { $typeName = "LPDDR2" } 27 { $typeName = "LPDDR" }
            default { $typeName = "类型" + [int]$m.SMBIOSMemoryType }
        }
    }
    $spd = ""
    if ($null -ne $m.ConfiguredClockSpeed) { $spd = [string]$m.ConfiguredClockSpeed + "MHz" }
    elseif ($null -ne $m.Speed) { $spd = [string]$m.Speed + "MHz" }
    $label = ((Fmt-Size $m.Capacity) + " " + $typeName + " " + $spd).Trim()
    if ($ramGroups.Contains($label)) { $ramGroups[$label] = $ramGroups[$label] + 1 } else { $ramGroups[$label] = 1 }
}
$ramList = @()
foreach ($k in $ramGroups.Keys) { $ramList += ([string]$ramGroups[$k] + " x " + $k) }

$gpus = Get-Safe { @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } @()
$gpuList = @(); $resList = @(); $monitors = 0
foreach ($g in $gpus) {
    $gpuList += (Fmt-Text $g.Name "-")
    if ($g.CurrentHorizontalResolution -and $g.CurrentVerticalResolution -and [int]$g.CurrentHorizontalResolution -gt 0) {
        $resList += ([string]$g.CurrentHorizontalResolution + "x" + [string]$g.CurrentVerticalResolution)
        $monitors++
    }
}

$ldisks = Get-Safe { @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop) } @()
$diskList = @()
foreach ($d in $ldisks) {
    $diskList += [ordered]@{
        drive = [string]$d.DeviceID
        fs    = [string]$d.FileSystem
        total = Fmt-Size $d.Size
        free  = Fmt-Size $d.FreeSpace
        totalBytes = [double]$d.Size
        freeBytes  = [double]$d.FreeSpace
    }
}

$pdisks = Get-Safe { @(Get-PhysicalDisk -ErrorAction Stop) } @()
$pdiskList = @()
foreach ($p in $pdisks) {
    $pdiskList += [ordered]@{
        model    = Fmt-Text $p.FriendlyName "-"
        media    = Fmt-Text $p.MediaType "-"
        bus      = Fmt-Text $p.BusType "-"
        size     = Fmt-Size $p.Size
        sizeBytes = [double]$p.Size
    }
}

$sysDiskMedia = "-"; $sysDiskBus = "-"; $sysDiskName = "-"
$sysLetter = ([string]$env:SystemDrive).TrimEnd(':'); if (-not $sysLetter) { $sysLetter = "C" }
$sysDiskObj = Get-Safe { Get-Partition -DriveLetter $sysLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop } $null
if ($sysDiskObj) {
    $sysDiskName = Fmt-Text $sysDiskObj.FriendlyName "-"
    if ($null -ne $sysDiskObj.MediaType) { $sysDiskMedia = [string]$sysDiskObj.MediaType }
    if ($null -ne $sysDiskObj.BusType) { $sysDiskBus = [string]$sysDiskObj.BusType }
}
if (($sysDiskMedia -eq "-" -or -not $sysDiskMedia) -and $sysDiskName -ne "-") {
    foreach ($pd2 in $pdiskList) { if ($pd2.model -eq $sysDiskName -and $pd2.media -ne "-") { $sysDiskMedia = $pd2.media } }
}
if (($sysDiskMedia -eq "-" -or -not $sysDiskMedia) -and $sysDiskBus -match "NVMe") { $sysDiskMedia = "SSD（NVMe 必为固态）" }

Note ("CPU      : " + $cpuName)
Note ("           " + $cpuCores + " 核 " + $cpuThreads + " 线程 / " + $cpuMHz + " MHz / L3 " + [string][math]::Round($cpuL3/1024.0,1) + " MB / AVX2=" + $(if ($null -eq $avx2) { "未知" } else { [string]$avx2 }))
Note ("内存     : " + (Fmt-Size $ramBytes) + "  (" + ($ramList -join " + ") + ")")
Note ("显卡     : " + ($gpuList -join " / ") + "    显示器 " + $monitors + " 台 " + ($resList -join " / "))
Note ("系统盘   : " + $sysDiskName + "  " + $sysDiskMedia + " / " + $sysDiskBus)
foreach ($d in $diskList) { Note ("磁盘 " + $d.drive + "  : " + $d.fs + " 共 " + $d.total + "，剩余 " + $d.free) }

# ===========================================================================
#  4/7  兼容性 / 运行环境
# ===========================================================================
Head "4/7 兼容性（能否跑起来的关键）"
$coreDlls = @("ucrtbase.dll","d3d11.dll","windowscodecs.dll","bcrypt.dll","dwrite.dll","opengl32.dll","shcore.dll","winmm.dll","comctl32.dll")
$sysDlls = @()
foreach ($dn in $coreDlls) {
    $fp = Join-Path $env:SystemRoot ("System32\" + $dn)
    $sysDlls += [ordered]@{ name = $dn; present = (Test-Path -LiteralPath $fp) }
}
$missingDll = @(); foreach ($x in $sysDlls) { if (-not $x.present) { $missingDll += $x.name } }
$optDlls = @()
foreach ($dn in @("vcruntime140.dll","msvcp140.dll")) {
    $fp2 = Join-Path $env:SystemRoot ("System32\" + $dn)
    $optDlls += [ordered]@{ name = $dn; present = (Test-Path -LiteralPath $fp2) }
}
$optMissing = @(); foreach ($x in $optDlls) { if (-not $x.present) { $optMissing += $x.name } }
$apiSetPresent = (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\api-ms-win-crt-runtime-l1-1-0.dll"))

$vcRedist = @()
Get-Safe {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $script:vcTmp = @(foreach ($k in $keys) { Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Visual C++*" } | ForEach-Object { [string]$_.DisplayName } })
} | Out-Null
if ($script:vcTmp) { $vcRedist = @($script:vcTmp) }

$usbPyVc = $false
foreach ($cand in @("python\python\vcruntime140.dll","python\vcruntime140.dll")) {
    if (Test-Path -LiteralPath (Join-Path $Root $cand)) { $usbPyVc = $true; break }
}

$net4 = Fmt-Text (Get-Safe { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release } "") ""

$def = Get-Safe { Get-MpComputerStatus -ErrorAction Stop } $null
$defRT = "-"; $defAM = "-"
if ($def) {
    if ($null -ne $def.RealTimeProtectionEnabled) { $defRT = [string]$def.RealTimeProtectionEnabled }
    if ($null -ne $def.AMServiceEnabled) { $defAM = [string]$def.AMServiceEnabled }
}
$defExcl = Get-Safe { @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ -is [string] -and ($_ -match "^[A-Za-z]:" ) }) } @()

$avs = Get-Safe { @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) } @()
$avList = @()
foreach ($a in $avs) {
    $avName = Fmt-Text $a.displayName "-"
    if ($avName -notmatch "Windows Defender") { $avList += $avName }
}
$fws = Get-Safe { @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop) } @()
$fwList = @(); foreach ($a in $fws) { $fwList += (Fmt-Text $a.displayName "-") }

$appLocker = Get-Safe { Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2' } $false
$wdacKey = Get-Safe { Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' } $false
$smartScreen = Fmt-Text (Get-Safe { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -ErrorAction Stop).EnableSmartScreen } "") ""

$appx = Get-Safe { @(Get-AppxPackage -ErrorAction Stop | Where-Object { $_.Name -match "Codex|ChatGPT|OpenAI" }) } @()
$appxList = @(); foreach ($a in $appx) { $appxList += ([string]$a.Name + " " + [string]$a.Version) }

$apps = @()
Get-Safe {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $script:appsTmp = @(foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "Codex|ChatGPT|OpenAI|Node\.js|^Python|Anaconda|Git for Windows|PowerShell|7-Zip|VC_redist" } |
            ForEach-Object { ([string]$_.DisplayName + " " + [string]$_.DisplayVersion).Trim() }
    })
} | Out-Null
if ($script:appsTmp) { $apps = @($script:appsTmp | Sort-Object -Unique) }

$runProcs = @()
Get-Safe {
    $script:procTmp = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "^(ChatGPT|codex|Codex)$" } | ForEach-Object { $_.ProcessName + " (PID " + $_.Id + ")" })
} | Out-Null
if ($script:procTmp) { $runProcs = @($script:procTmp) }
$runProcsShow = "无"
if ($runProcs.Count -gt 3) { $runProcsShow = ($runProcs[0..2] -join ", ") + " 等 " + $runProcs.Count + " 个进程" }
elseif ($runProcs.Count -gt 0) { $runProcsShow = ($runProcs -join ", ") }

$portBusy = @()
$netstat = Get-Safe { @(netstat -ano) } @()
foreach ($ln in $netstat) {
    if ($ln -match ":(15721|15722)\s") { $portBusy += $ln.Trim() }
}

Note ("系统 DLL : " + $(if ($missingDll.Count -eq 0) { "关键系统 DLL 齐全" } else { "缺少 " + ($missingDll -join ", ") }) + "    VC++运行库DLL: " + $(if ($optMissing.Count -eq 0) { "齐全" } else { "缺少 " + ($optMissing -join ", ") }) + "    api-set 转发DLL: " + $(if ($apiSetPresent) { "有" } else { "无（正常）" }))
Note ("VC++     : " + $(if ($vcRedist.Count -eq 0) { "未装 VC++ 运行库（便携版不需要）" } else { ($vcRedist -join " / ") }))
Note (".NET 4   : Release " + (Fmt-Text $net4 "?") + "    U盘自带 vcruntime140: " + $(if ($usbPyVc) { "有" } else { "无" }))
Note ("杀毒     : Defender 实时=" + $defRT + " / 服务=" + $defAM + "    第三方: " + $(if ($avList.Count -eq 0) { "无" } else { ($avList -join ", ") }) + "    防火墙: " + $(if ($fwList.Count -eq 0) { "系统自带" } else { ($fwList -join ", ") }))
if ($defExcl.Count -gt 0) { Note ("           Defender 排除项: " + ($defExcl -join " ; ")) }
Note ("管控     : AppLocker=" + [string]$appLocker + "  WDAC策略键=" + [string]$wdacKey + "  SmartScreen策略=" + (Fmt-Text $smartScreen "未设置"))
Note ("已装 Codex: " + $(if ($appxList.Count -eq 0) { "无（无单实例冲突风险）" } else { ($appxList -join ", ") + "  ← 与本机 Codex 并存，靠独立 APPDATA 规避冲突" }))
if ($apps.Count -gt 0) { Note ("相关软件 : " + ($apps -join " ; ")) }
if ($runProcs.Count -gt 0) { Note ("正在运行 : " + $runProcsShow) }
if ($portBusy.Count -gt 0) { Note ("端口占用 : " + ($portBusy -join " | ")) }

# ===========================================================================
#  5/7  运行环境（缓存能不能落在这台机器上）
# ===========================================================================
Head "5/7 本机运行环境"
$usbId = Fmt-Text (Get-Safe { ([System.IO.File]::ReadAllText((Join-Path $Root ".usb-id"))).Trim() } "") ""
$cacheBase = Join-Path $env:USERPROFILE "CodexPortable"
if ($usbId) { $cacheDir = Join-Path $cacheBase $usbId } else { $cacheDir = Join-Path $cacheBase "default" }
$cacheExe  = Join-Path $cacheDir "_internal\app\ChatGPT.exe"
$cacheExists = Test-Path -LiteralPath $cacheExe

$writeOK = $false; $writeErr = ""
try {
    $probeDir = Join-Path $cacheBase (".probe_" + $PID)
    New-Item -ItemType Directory -Force -Path $probeDir -ErrorAction Stop | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $probeDir "w.txt"), "ok", [System.Text.Encoding]::ASCII)
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    $writeOK = $true
} catch { $writeErr = [string]$_.Exception.Message }

$upDrive = Fmt-Text (Split-Path -Qualifier $env:USERPROFILE) ""
$upFree = $null; $upTotal = $null
Get-Safe {
    $di = New-Object System.IO.DriveInfo($upDrive)
    $script:upFreeTmp = $di.AvailableFreeSpace
    $script:upTotalTmp = $di.TotalSize
} | Out-Null
if ($null -ne $script:upFreeTmp) { $upFree = $script:upFreeTmp; $upTotal = $script:upTotalTmp }

$cacheFiles = 0; $cacheMB = 0
if ($cacheExists) {
    Get-Safe {
        $m = Get-ChildItem -LiteralPath $cacheDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        $script:cacheFilesTmp = [int]$m.Count
        $script:cacheMBTmp = [math]::Round([double]$m.Sum / 1MB, 1)
    } | Out-Null
    if ($null -ne $script:cacheFilesTmp) { $cacheFiles = $script:cacheFilesTmp; $cacheMB = $script:cacheMBTmp }
}

$deskUsr = Fmt-Text (Get-Safe { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).Desktop } "") ""
$deskReal = ""
if ($deskUsr) { $deskReal = [System.Environment]::ExpandEnvironmentVariables($deskUsr) }
$deskApi = Fmt-Text (Get-Safe {
    if (-not ("Win32.ShellFolders" -as [type])) {
        Add-Type -Namespace Win32 -Name ShellFolders -MemberDefinition @"
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SHGetFolderPath(IntPtr hwnd, int csidl, IntPtr hToken, int dwFlags, System.Text.StringBuilder pszPath);
"@ -ErrorAction Stop
    }
    $sb = New-Object System.Text.StringBuilder 260
    [void][Win32.ShellFolders]::SHGetFolderPath([IntPtr]::Zero, 0, [IntPtr]::Zero, 0, $sb)
    $sb.ToString()
} "") ""
$deskDefault = Join-Path $env:USERPROFILE "Desktop"
$deskRedirected = $false
$deskCmp = $deskApi
if (-not $deskCmp) { $deskCmp = $deskReal }
if ($deskCmp -and $deskCmp.TrimEnd('\').ToLower() -ne $deskDefault.TrimEnd('\').ToLower()) { $deskRedirected = $true }

$pathHasCodex = [bool]($env:PATH -match "(?i)codex")
$pathHasNode = [bool]($env:PATH -match "(?i)node")

Note ("用户目录 : " + $env:USERPROFILE + "   (" + $upDrive + " 剩余 " + (Fmt-Size $upFree) + " / 共 " + (Fmt-Size $upTotal) + ")")
Note ("可写测试 : " + $(if ($writeOK) { "通过" } else { "失败 → " + $writeErr }))
Note ("缓存路径 : " + $cacheDir)
Note ("本机缓存 : " + $(if ($cacheExists) { "已存在（$cacheFiles 个文件 / $cacheMB MB）→ 下次启动是热启动" } else { "不存在 → 下次启动要做首次缓存" }))
Note ("桌面路径 : " + (Fmt-Text $deskApi (Fmt-Text $deskReal "-")) + $(if ($deskRedirected) { "   [已重定向，非默认位置]" } else { "   [默认位置]" }))
Note ("环境变量 : CODEX_HOME=" + (Fmt-Text $env:CODEX_HOME "未设置") + "  PATH含codex=" + [string]$pathHasCodex + " 含node=" + [string]$pathHasNode)

# ===========================================================================
#  6/7  U 盘信息 + 实测性能
# ===========================================================================
Head "6/7 U 盘信息与实测性能"
$usbLetter = Fmt-Text (Split-Path -Qualifier $Root) ""
if ($usbLetter) { $usbLetter = $usbLetter.TrimEnd('\') }
$usbVol = $null
Get-Safe { $script:usbVolTmp = New-Object System.IO.DriveInfo($usbLetter) } | Out-Null
if ($script:usbVolTmp) { $usbVol = $script:usbVolTmp }
$usbFs = Fmt-Text (Get-Safe { $usbVol.DriveFormat } "") ""
$usbFree = Get-Safe { $usbVol.AvailableFreeSpace } $null
$usbTotal = Get-Safe { $usbVol.TotalSize } $null
$usbLabel = Fmt-Text (Get-Safe { $usbVol.VolumeLabel } "") ""
$usbDevModel = "-"; $usbDevBus = "-"
Get-Safe {
    $ltr = ""
    if ([string]$usbLetter -match "^([A-Za-z]):") { $ltr = $matches[1] }
    $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $ltr + ":'") -ErrorAction Stop
    if (-not $ld) { throw "logical disk not found" }
    $assoc = Get-CimAssociatedInstance -InputObject $ld -Association Win32_LogicalDiskToPartition -ErrorAction Stop
    $drv = Get-CimAssociatedInstance -InputObject $assoc -ResultClassName Win32_DiskDrive -ErrorAction Stop
    if ($drv) { $script:usbDevTmp = [string]$drv.Model; $script:usbBusTmp = [string]$drv.InterfaceType }
} | Out-Null
if (-not $script:usbDevTmp) {
    Get-Safe {
        $dd = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.InterfaceType -eq "USB" })
        if ($dd.Count -gt 0) { $script:usbDevTmp = [string]$dd[0].Model; $script:usbBusTmp = "USB" }
    } | Out-Null
}
if ($script:usbDevTmp) { $usbDevModel = $script:usbDevTmp }
if ($script:usbBusTmp) { $usbDevBus = $script:usbBusTmp }

$usbControllers = Get-Safe { @(Get-CimInstance Win32_USBController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) } @()
$usb3Hint = $false
foreach ($c in $usbControllers) { if ($c -match "3\.0|xHCI|USB 3|SuperSpeed") { $usb3Hint = $true } }

Note ("U 盘卷   : " + $usbLetter + " " + $usbFs + " 标签=" + (Fmt-Text $usbLabel "-") + " 剩余 " + (Fmt-Size $usbFree) + " / " + (Fmt-Size $usbTotal))
Note ("U 盘设备 : " + $usbDevModel + "  接口: " + $usbDevBus + "  USB控制器: " + ($usbControllers -join " / "))
Note ("USB3 迹象: " + $(if ($usb3Hint) { "有（xHCI/3.0 控制器存在）" } else { "未见 3.0 标识" }))

$bench = [ordered]@{
    skipped = $true; reason = ""; method = ""
    usbSmallFilesPerSec = $null; usbSmallMBps = $null; usbSmallRounds = @(); readMode = ""
    usbSeqWriteMBps = $null; usbSeqReadMBps = $null; localSeqWriteMBps = $null
    baselineSmallFilesPerSec = 50.0; baselineSeqWriteMBps = 20.6; baselineSeqReadMBps = 31.1; baselineLocalWriteMBps = 744.0
    baselineNote = "本机 + 本盘，2026-10-13 同一测法（更早一次用缓冲写测法得 58.4 MB/s，仅供参考）"
    estFirstCacheSecBytes = $null; estFirstCacheSecFiles = $null
}

$skipBench = $false; $skipReason = ""
if ($NoBench) { $skipBench = $true; $skipReason = "指定了 -NoBench" }
elseif ($busyProcs.Count -gt 0) { $skipBench = $true; $skipReason = "检测到后台写入进程：" + ($busyProcs -join ", ") }

if ($skipBench) {
    $bench.reason = $skipReason
    Note ("测速     : 跳过（" + $skipReason + "）")
} else {
    $bench.skipped = $false
    $bench.method = "先读后写：顺序读=U 盘大文件前 64MB; 小文件=60 x 8KB 每文件 FlushFileBuffers; 顺序写=64MB/1MB 块 + FlushFileBuffers; 本机盘写=64MB"
    $benchDir = Join-Path $Root ("_speedtest_" + $PID)
    $ok = $true
    try {
        New-Item -ItemType Directory -Force -Path $benchDir -ErrorAction Stop | Out-Null
    } catch { $ok = $false; Note ("测速失败：无法在 U 盘建测试目录 - " + [string]$_.Exception.Message) }
    if ($ok) {
        # --- 顺序读（无缓冲直读，绕过系统缓存；最接近首次缓存的真实读速）---
        Start-Sleep -Seconds 1
        try {
            $readSrc = ""
            foreach ($cand in @("codex\codex.exe","_internal\app\ChatGPT.exe")) {
                $p2 = Join-Path $Root $cand
                if (Test-Path -LiteralPath $p2) { $readSrc = $p2; break }
            }
            if ($readSrc) {
                $readMB = 64
                $script:directGot = 0
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                Get-Safe {
                    if (-not ("Win32.DirectRead" -as [type])) {
                        Add-Type -Namespace Win32 -Name DirectRead -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(string f, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr tpl);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool ReadFile(IntPtr h, IntPtr buf, uint n, out uint read, IntPtr ov);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr h);
"@ -ErrorAction Stop
                    }
                    $h = [Win32.DirectRead]::CreateFileW($readSrc, [uint32]2147483648, [uint32]1, [IntPtr]::Zero, [uint32]3, [uint32]671088640, [IntPtr]::Zero)
                    if ($h -eq [IntPtr]::Zero -or $h.ToInt64() -eq -1) { throw "CreateFile 失败" }
                    $blockSize = 1MB
                    $rawPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($blockSize + 4096)
                    $aligned = [IntPtr]((($rawPtr.ToInt64() + 4095) -band (-bnot 4095)))
                    try {
                        $left = $readMB * 1MB
                        while ($left -gt 0) {
                            $want = [uint32][Math]::Min($left, $blockSize)
                            $got = [uint32]0
                            $okr = [Win32.DirectRead]::ReadFile($h, $aligned, $want, [ref]$got, [IntPtr]::Zero)
                            if (-not $okr -or $got -le 0) { break }
                            $script:directGot = $script:directGot + [int]$got
                            $left = $left - [int]$got
                        }
                    } finally {
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($rawPtr)
                        [void][Win32.DirectRead]::CloseHandle($h)
                    }
                } | Out-Null
                $sw.Stop()
                $sec = $sw.Elapsed.TotalSeconds
                if ($sec -le 0) { $sec = 0.001 }
                if ($script:directGot -gt 1MB) {
                    $bench.usbSeqReadMBps = [math]::Round(($script:directGot / 1MB) / $sec, 1)
                    $bench.readMode = "无缓冲直读（绕过系统缓存）"
                    Note ("顺序读   : {0:N1} MB/s   （无缓冲直读，读自 {1}）" -f $bench.usbSeqReadMBps, (Split-Path -Leaf $readSrc))
                } else {
                    $bench.readMode = "不可用"
                    Note "顺序读   : 跳过（这台电脑不支持无缓冲直读，改用顺序写速度估算）"
                }
            } else {
                $bench.readMode = "无可用大文件"
                Note "顺序读   : 跳过（U 盘上找不到可读的大文件）"
            }
        } catch { Note ("顺序读测速失败：" + [string]$_.Exception.Message) }

        # --- 小文件写（两轮取平均；这块盘波动较大）---
        try {
            $n = 60; $size = 8192
            $buf = New-Object byte[] $size
            (New-Object System.Random 12345).NextBytes($buf)
            $rounds = @()
            for ($round = 1; $round -le 2; $round++) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                for ($i = 0; $i -lt $n; $i++) {
                    $fp = Join-Path $benchDir ("s{0}_{1:d4}.bin" -f $round, $i)
                    $fs = New-Object System.IO.FileStream($fp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    $fs.Write($buf, 0, $size)
                    $fs.Flush($true)
                    $fs.Close(); $fs.Dispose()
                }
                $sw.Stop()
                $sec = $sw.Elapsed.TotalSeconds
                if ($sec -le 0) { $sec = 0.001 }
                $rounds += [math]::Round($n / $sec, 1)
            }
            $avg = [math]::Round((($rounds[0] + $rounds[1]) / 2.0), 1)
            $bench.usbSmallFilesPerSec = $avg
            $bench.usbSmallRounds = @($rounds)
            $bench.usbSmallMBps = [math]::Round((($avg * $size) / 1MB), 2)
            Note ("小文件写 : {0:N1} 文件/秒 （两轮 {1:N1} / {2:N1}，各 60 个 8KB）" -f $avg, $rounds[0], $rounds[1])
        } catch { Note ("小文件写测速失败：" + [string]$_.Exception.Message) }

        # --- 顺序写 ---
        try {
            $totalMB = 64
            $big = Join-Path $benchDir "seq.bin"
            $chunk = New-Object byte[] (1MB)
            (New-Object System.Random 777).NextBytes($chunk)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $fs = New-Object System.IO.FileStream($big, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            for ($i = 0; $i -lt $totalMB; $i++) { $fs.Write($chunk, 0, $chunk.Length) }
            $fs.Flush($true)
            $fs.Close(); $fs.Dispose()
            $sw.Stop()
            $sec = $sw.Elapsed.TotalSeconds
            if ($sec -le 0) { $sec = 0.001 }
            $bench.usbSeqWriteMBps = [math]::Round($totalMB / $sec, 1)
            Note ("顺序写   : {0:N1} MB/s   [基准 20.6 MB/s]" -f $bench.usbSeqWriteMBps)
        } catch { Note ("顺序写测速失败：" + [string]$_.Exception.Message) }

        # --- 本机盘顺序写（缓存落地的上限）---
        try {
            $localDir = $LocalBenchDir
            if (-not $localDir) { $localDir = $cacheBase }
            New-Item -ItemType Directory -Force -Path $localDir | Out-Null
            $pf = Join-Path $localDir (".codx_speed_" + $PID + ".bin")
            $totalMB = 64
            $chunk = New-Object byte[] (1MB)
            (New-Object System.Random 999).NextBytes($chunk)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $fs = New-Object System.IO.FileStream($pf, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            for ($i = 0; $i -lt $totalMB; $i++) { $fs.Write($chunk, 0, $chunk.Length) }
            $fs.Flush($true)
            $fs.Close(); $fs.Dispose()
            $sw.Stop()
            Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
            $sec = $sw.Elapsed.TotalSeconds
            if ($sec -le 0) { $sec = 0.001 }
            $bench.localSeqWriteMBps = [math]::Round($totalMB / $sec, 1)
            Note ("本机盘写 : {0:N1} MB/s   （缓存目标盘：{1}）" -f $bench.localSeqWriteMBps, (Split-Path -Qualifier $localDir))
        } catch { Note ("本机盘写测速失败（不影响使用）：" + [string]$_.Exception.Message) }

        # --- 预估首次缓存耗时 ---
        try {
            $progMB = 1896.0
            $readRate = $bench.usbSeqReadMBps
            if ($null -eq $readRate) { $readRate = $bench.usbSeqWriteMBps }
            $wr = $bench.localSeqWriteMBps
            $eff = $readRate
            if ($null -ne $wr -and $null -ne $eff -and $wr -lt $eff) { $eff = $wr }
            if ($null -ne $eff -and $eff -gt 0) {
                $bench.estFirstCacheSecBytes = [math]::Round(($progMB / $eff) * 1.15, 0)
            }
            if ($null -ne $bench.usbSmallFilesPerSec -and $bench.usbSmallFilesPerSec -gt 0) {
                $bench.estFirstCacheSecFiles = [math]::Round(7020 / $bench.usbSmallFilesPerSec, 0)
            }
            if ($null -ne $bench.estFirstCacheSecBytes) {
                Note ("预估首次缓存: 约 {0:N0} 秒（按本机+本盘实测 60-75 秒标定）" -f $bench.estFirstCacheSecBytes)
            }
            if ($null -ne $bench.estFirstCacheSecFiles) {
                Note ("              串行逐文件估计 {0:N0} 秒（偏保守，实际 /MT:16 并行会快很多）" -f $bench.estFirstCacheSecFiles)
            }
        } catch { }
    }
    if (Test-Path -LiteralPath $benchDir) {
        Get-Safe { Remove-Item -LiteralPath $benchDir -Recurse -Force -ErrorAction SilentlyContinue } | Out-Null
        if (Test-Path -LiteralPath $benchDir) { Note "[注意] 测速目录未能删除，请手动删除：$benchDir" }
    }
}

# ===========================================================================
#  7/7  结论
# ===========================================================================
Head "7/7 结论与建议"
$blockers = @(); $warnings = @(); $notes = @()

$osMajor = 0
Get-Safe { $script:osMajorTmp = [int]([Environment]::OSVersion.Version.Major) } | Out-Null
if ($script:osMajorTmp) { $osMajor = $script:osMajorTmp }
if ($osMajor -lt 10) { $blockers += "系统版本低于 Windows 10，无法运行" }
if ($env:PROCESSOR_ARCHITECTURE -eq "x86") { $blockers += "32 位系统，无法运行（需要 64 位）" }
if (-not $writeOK) { $blockers += "用户目录不可写，无法建立本机缓存：" + $writeErr }
if ($null -ne $upFree -and $upFree -lt 4GB) { $blockers += ("缓存所在盘剩余空间不足（" + (Fmt-Size $upFree) + "，需要约 4 GB）") }
$epBad = @("Restricted","AllSigned")
if ($epMachinePolicy -and ($epBad -contains $epMachinePolicy)) { $blockers += ("组策略锁定 PowerShell 执行策略为 " + $epMachinePolicy + "，启动器会被拒绝") }

if ($appLocker) { $warnings += "检测到 AppLocker 策略，U 盘上的程序可能被拦截" }
if ($defRT -eq "True") { $warnings += "Defender 实时防护开启（首次缓存会慢 30-60%，属正常）" }
if ($avList.Count -gt 0) { $warnings += ("第三方杀毒：" + ($avList -join ", ") + "（可能拦截 U 盘程序，需允许）") }
if ($appxList.Count -gt 0) { $warnings += "本机已装 Codex/ChatGPT（靠独立 APPDATA 规避单实例冲突）" }
if ($hasBattery -and $onAc -ne "接通电源") { $warnings += "笔记本正在用电池，插电源可明显提速" }
if ($powerName -match "节能|Power saver|Saver") { $warnings += "当前电源计划是节能模式，插电并切到高性能更快" }
if ($isVirtual) { $notes += "运行在虚拟机/虚拟化环境，性能数据不代表真实机器" }
elseif ($hypervisor) { $notes += "HypervisorPresent=True（多为内核隔离/VBS 或 Hyper-V 平台，不代表是虚拟机）" }
if ($deskRedirected) { $notes += "桌面已被重定向（OneDrive 等），启动器会自动识别" }
if ($acp -eq "936") { $notes += "中文系统（GBK 代码页 936），.cmd 已按 ANSI 保存，无影响" }
if ($acp -and $acp -ne "936" -and $acp -ne "65001") { $notes += "非 936 代码页（ACP=" + $acp + "），注意 .cmd 中文兼容性" }
if ($missingDll.Count -gt 0) { $warnings += ("系统缺少 " + ($missingDll -join ", ") + "，程序可能无法启动") }
if ($null -eq $cs -or $null -eq $os) { $notes += "WMI/CIM 查询受限，多项硬件/系统信息缺失（请在正常用户上下文下重跑一次）" }
if (-not $apiSetPresent) { $notes += "api-ms-win-crt-* 转发 DLL 不在 System32（Win10+ 用 apiset 机制解析，属正常）" }
if ($cacheExists) { $notes += "本机已有程序缓存（$cacheFiles 个文件 / $cacheMB MB），下次是热启动" }
if ($bench.skipped -eq $false -and $null -ne $bench.usbSeqWriteMBps -and $bench.usbSeqWriteMBps -lt 20) { $warnings += "U 盘写速偏低（<20 MB/s），首次缓存会较慢，建议换 SSD 型 U 盘" }
if ($bench.skipped -eq $false -and $null -ne $bench.usbSmallFilesPerSec -and $bench.usbSmallFilesPerSec -lt 15) { $warnings += "U 盘小文件写速偏低（<15 文件/秒），大量碎文件操作会很慢" }

$canRun = ($blockers.Count -eq 0)
Note ("能否运行 : " + $(if ($canRun) { "可以（无阻塞项）" } else { "不行，见阻塞项" }))
foreach ($b in $blockers) { Note ("  [阻塞] " + $b) }
foreach ($w in $warnings) { Note ("  [注意] " + $w) }
foreach ($n in $notes)    { Note ("  [记录] " + $n) }

# ===========================================================================
#  写文件
# ===========================================================================
$archive = Join-Path $Root "电脑档案"
$rawDir  = Join-Path $archive "raw"
$writeErr2 = ""
try {
    New-Item -ItemType Directory -Force -Path $rawDir -ErrorAction Stop | Out-Null
} catch { $writeErr2 = [string]$_.Exception.Message }

if ($writeErr2) {
    Say ""
    Say "[错误] 无法在 U 盘上创建档案目录：$archive"
    Say "       原因：$writeErr2"
    Say "       请确认 U 盘没有写保护、已正确插入。"
    exit 2
}

$stamp = $t0.ToString("yyyyMMdd-HHmmss")
$san = ($computerName -replace '[^\w\-\.]', '_')
$baseName = $stamp + "_" + $san
$jsonPath = Join-Path $rawDir ($baseName + ".json")
$mdPath   = Join-Path $archive ($baseName + ".md")

$data = [ordered]@{
    schemaVersion = 1
    collector = ("collect-pc.ps1 v" + $CollectorVersion)
    collectedAt = $t0.ToString("yyyy-MM-dd HH:mm:ss")
    usb = [ordered]@{ root = $Root; id = $usbId; letter = $usbLetter; label = $usbLabel; fileSystem = $usbFs; freeBytes = $usbFree; totalBytes = $usbTotal; deviceModel = $usbDevModel; deviceBus = $usbDevBus; usb3Hint = $usb3Hint }
    identity = [ordered]@{ computerName = $computerName; machineKey = $machineKey; manufacturer = $mfg; model = $model; pcType = $pcType; isVirtual = $isVirtual; sessionName = (Fmt-Text $env:SESSIONNAME ""); userMasked = $userMasked; isAdmin = $isAdmin; osInstallDate = $osInstall; domain = (Fmt-Text $cs.Domain "") }
    os = [ordered]@{ caption = $osCaption; version = $osVersion; build = $osBuild; ubr = $osUbr; displayVersion = $dispVer; editionId = $edition; architecture = $osArch; productType = $productType; hypervisorPresent = $hypervisor; locale = $locale; uiLanguage = $uiLang; systemLocale = $sysLocale; timeZone = $tz; ansiCodePage = $acp; oemCodePage = $oemcp; longPathsEnabled = $longPaths; psVersion = $psVer; psEdition = $psEd; executionPolicyEffective = $epEff; executionPolicyList = $epList; executionPolicyMachinePolicy = $epMachinePolicy; uacEnableLua = $uacLua; uacConsentPrompt = $uacConsent; fastStartup = $hiberboot; powerPlan = $powerName; hasBattery = $hasBattery; acState = $onAc; license = $licDesc }
    hardware = [ordered]@{ cpu = $cpuName; cpuCores = $cpuCores; cpuThreads = $cpuThreads; cpuMHz = $cpuMHz; cpuL3KB = $cpuL3; cpuVirtualizationFirmware = $cpuVirt; avx2 = $avx2; ramBytes = $ramBytes; ramModules = $ramList; gpus = $gpuList; resolutions = $resList; monitorCount = $monitors; logicalDisks = $diskList; physicalDisks = $pdiskList; systemDisk = [ordered]@{ name = $sysDiskName; mediaType = $sysDiskMedia; busType = $sysDiskBus } }
    compat = [ordered]@{ systemDlls = $sysDlls; optionalDlls = $optDlls; missingDlls = $missingDll; apiSetForwarder = $apiSetPresent; vcRedist = $vcRedist; dotnet4Release = $net4; usbPythonVcruntime = $usbPyVc; defenderRealtime = $defRT; defenderService = $defAM; defenderExclusions = $defExcl; antivirus = $avList; firewallProducts = $fwList; appLocker = $appLocker; wdacPolicyKey = $wdacKey; smartScreenPolicy = $smartScreen; codexAppx = $appxList; relatedApps = $apps; runningCodex = $runProcs; portBusy = $portBusy }
    environment = [ordered]@{ userProfile = $env:USERPROFILE; safeUserFolder = $cacheBase; safeUserFolderWritable = $writeOK; writeError = $writeErr; userDriveLetter = $upDrive; userDriveFreeBytes = $upFree; userDriveTotalBytes = $upTotal; cachePath = $cacheDir; cacheExists = $cacheExists; cacheFileCount = $cacheFiles; cacheMB = $cacheMB; desktopApi = $deskApi; desktopRegistry = $deskReal; desktopRedirected = $deskRedirected; appData = $env:APPDATA; localAppData = $env:LOCALAPPDATA; temp = $env:TEMP; pathHasCodex = $pathHasCodex; pathHasNode = $pathHasNode }
    bench = $bench
    verdict = [ordered]@{ canRun = $canRun; blockers = $blockers; warnings = $warnings; notes = $notes }
}

$jsonErr = ""
try {
    $json = $data | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))
} catch { $jsonErr = [string]$_.Exception.Message }

# ---------- Markdown 报告 ----------
$L = New-Object System.Collections.ArrayList
function W([string]$s) { [void]$L.Add($s) }

W ("# 宿主电脑档案 · " + $computerName)
W ""
W ("> 采集时间：" + $data.collectedAt + "   |   采集器：collect-pc.ps1 v" + $CollectorVersion + "   |   机器标识：" + $machineKey)
W "> 本文件由 U 盘上的「收集本机环境档案」自动生成，用于优化便携版 Codex。"
W ""
W "## 结论"
W ""
W ("- **能否运行**：" + $(if ($canRun) { "可以（无阻塞项）" } else { "**不行**" }))
foreach ($b in $blockers) { W ("- 阻塞：" + $b) }
foreach ($w in $warnings) { W ("- 注意：" + $w) }
foreach ($n in $notes)    { W ("- 记录：" + $n) }
W ""
W "## 1. 机器与系统"
W ""
W "| 项目 | 值 |"
W "|---|---|"
W ("| 机器名 | " + $computerName + " |")
W ("| 品牌型号 | " + (Fmt-Text ($mfg + " " + $model) "-") + " |")
W ("| 类型 | " + $pcType + " / " + $(if ($isVirtual) { "虚拟化环境" } else { "物理机" }) + " |")
W ("| 用户（打码） | " + $userMasked + " |")
W ("| 系统 | " + $osCaption + " |")
W ("| 版本号 | " + $osVersion + " (Build " + $osBuild + "." + $osUbr + ") " + $dispVer + " |")
W ("| 版本类型 | " + $edition + " / " + $productType + " / " + $osArch + " |")
W ("| 授权 | " + (Fmt-Text $licDesc "-") + " |")
W ("| 系统安装日期 | " + $osInstall + " |")
W ("| 区域/语言 | " + $locale + " / " + $uiLang + " |")
W ("| 代码页 | ACP=" + $acp + " OEM=" + $oemcp + " |")
W ("| 长路径支持 | " + $longPaths + " |")
W ("| PowerShell | " + $psVer + " (" + $psEd + ") |")
W ("| 执行策略 | 生效=" + $epEff + "；机器策略=" + (Fmt-Text $epMachinePolicy "未设置") + " |")
W ("| 执行策略明细 | " + ($epList -join "; ") + " |")
W ("| UAC | EnableLUA=" + $uacLua + " ConsentPrompt=" + $uacConsent + " |")
W ("| 快速启动 | " + (Fmt-Text $hiberboot "-") + " |")
W ("| 电源计划 | " + (Fmt-Text $powerName "?") + " / " + $onAc + " |")
W ("| 时区 | " + $tz + " |")
W ""
W "## 2. 硬件"
W ""
W "| 项目 | 值 |"
W "|---|---|"
W ("| CPU | " + $cpuName + " |")
W ("| 核心/线程 | " + $cpuCores + " 核 / " + $cpuThreads + " 线程 |")
W ("| 主频 / L3 | " + $cpuMHz + " MHz / " + [string][math]::Round($cpuL3/1024.0,1) + " MB |")
W ("| AVX2 指令集 | " + $(if ($null -eq $avx2) { "未知" } else { [string]$avx2 }) + " |")
W ("| 内存 | " + (Fmt-Size $ramBytes) + " |")
W ("| 内存条 | " + (Fmt-Text ($ramList -join " + ") "-") + " |")
W ("| 显卡 | " + (Fmt-Text ($gpuList -join " / ") "-") + " |")
W ("| 显示器 | " + $monitors + " 台 " + (Fmt-Text ($resList -join " / ") "-") + " |")
W ("| 系统盘 | " + $sysDiskName + " / " + $sysDiskMedia + " / " + $sysDiskBus + " |")
W ""
W "### 磁盘"
W ""
W "| 盘符 | 文件系统 | 容量 | 剩余 |"
W "|---|---|---|---|"
foreach ($d in $diskList) { W ("| " + $d.drive + " | " + $d.fs + " | " + $d.total + " | " + $d.free + " |") }
W ""
if ($pdiskList.Count -gt 0) {
    W "| 物理盘 | 介质 | 总线 | 容量 |"
    W "|---|---|---|---|"
    foreach ($p in $pdiskList) { W ("| " + $p.model + " | " + $p.media + " | " + $p.bus + " | " + $p.size + " |") }
    W ""
}
W "## 3. 兼容性与运行环境"
W ""
W "| 项目 | 值 |"
W "|---|---|"
W ("| 系统 DLL | " + $(if ($missingDll.Count -eq 0) { "关键系统 DLL 齐全" } else { "缺少 " + ($missingDll -join ", ") }) + " |")
W ("| VC++ 运行库 DLL | " + $(if ($optMissing.Count -eq 0) { "vcruntime140 / msvcp140 齐全" } else { "缺少 " + ($optMissing -join ", ") + "（便携版不需要：Python 用 U 盘自带的）" }) + " |")
W ("| api-set 转发 DLL | " + $(if ($apiSetPresent) { "有" } else { "无（Win10+ 由 apiset 机制解析，属正常）" }) + " |")
W ("| VC++ 运行库 | " + (Fmt-Text ($vcRedist -join " / ") "未安装（便携版不需要）") + " |")
W ("| .NET Framework 4 | Release " + (Fmt-Text $net4 "?") + " |")
W ("| U 盘自带 vcruntime140 | " + $(if ($usbPyVc) { "有" } else { "无" }) + " |")
W ("| Defender | 实时=" + $defRT + " 服务=" + $defAM + " |")
W ("| 第三方杀毒 | " + (Fmt-Text ($avList -join ", ") "无") + " |")
W ("| 第三方防火墙 | " + (Fmt-Text ($fwList -join ", ") "无（系统自带）") + " |")
W ("| AppLocker | " + [string]$appLocker + " |")
W ("| WDAC 策略键 | " + [string]$wdacKey + " |")
W ("| SmartScreen 策略 | " + (Fmt-Text $smartScreen "未设置") + " |")
W ("| 已装 Codex/ChatGPT | " + (Fmt-Text ($appxList -join ", ") "无") + " |")
W ("| 正在运行的 Codex | " + $runProcsShow + " |")
W ("| 端口 15721/15722 | " + (Fmt-Text ($portBusy -join " | ") "未占用") + " |")
W ""
if ($apps.Count -gt 0) {
    W "已安装的相关软件："
    W ""
    foreach ($a in $apps) { W ("- " + $a) }
    W ""
}
W "## 4. 运行环境（本机缓存）"
W ""
W "| 项目 | 值 |"
W "|---|---|"
W ("| 用户目录 | " + $env:USERPROFILE + " |")
W ("| 用户目录可写 | " + $(if ($writeOK) { "通过" } else { "失败：" + $writeErr }) + " |")
W ("| 缓存路径 | " + $cacheDir + " |")
W ("| 缓存状态 | " + $(if ($cacheExists) { "已存在（$cacheFiles 文件 / $cacheMB MB）" } else { "不存在（下次为首次缓存）" }) + " |")
W ("| 用户盘空间 | 剩余 " + (Fmt-Size $upFree) + " / 共 " + (Fmt-Size $upTotal) + " |")
W ("| 桌面（API） | " + (Fmt-Text $deskApi "-") + " |")
W ("| 桌面（注册表） | " + (Fmt-Text $deskReal "-") + " |")
W ("| 桌面是否重定向 | " + [string]$deskRedirected + " |")
W ("| APPDATA | " + (Fmt-Text $env:APPDATA "-") + " |")
W ("| LOCALAPPDATA | " + (Fmt-Text $env:LOCALAPPDATA "-") + " |")
W ("| TEMP | " + (Fmt-Text $env:TEMP "-") + " |")
W ("| PATH 含 codex | " + [string]$pathHasCodex + " |")
W ("| PATH 含 node | " + [string]$pathHasNode + " |")
W ""
W "## 5. U 盘与实测性能"
W ""
W "| 项目 | 值 |"
W "|---|---|"
W ("| U 盘 | " + $usbLetter + " " + $usbFs + " 标签=" + (Fmt-Text $usbLabel "-") + " |")
W ("| U 盘空间 | 剩余 " + (Fmt-Size $usbFree) + " / 共 " + (Fmt-Size $usbTotal) + " |")
W ("| U 盘设备 | " + $usbDevModel + "（接口 " + $usbDevBus + "） |")
W ("| USB 控制器 | " + (Fmt-Text ($usbControllers -join " / ") "-") + " |")
W ("| USB3 迹象 | " + [string]$usb3Hint + " |")
W ""
if ($bench.skipped) {
    W ("测速：**跳过**（" + $bench.reason + "）")
} else {
    W ("基准（" + (Fmt-Text $bench.baselineNote "-") + "）：小文件写 50.0 文件/秒，顺序读 31.1 MB/s，顺序写 20.6 MB/s，本机盘写 744 MB/s")
    W ""
    W "| 指标 | 本机 | 基准 | 比值 |"
    W "|---|---|---|---|"
    $r1 = "?"; if ($bench.usbSmallFilesPerSec) { $r1 = "{0:N2}x" -f ($bench.usbSmallFilesPerSec / $bench.baselineSmallFilesPerSec) }
    $r2 = "?"; if ($bench.usbSeqWriteMBps) { $r2 = "{0:N2}x" -f ($bench.usbSeqWriteMBps / $bench.baselineSeqWriteMBps) }
    $r3 = "?"; if ($bench.usbSeqReadMBps) { $r3 = "{0:N2}x" -f ($bench.usbSeqReadMBps / $bench.baselineSeqReadMBps) }
    $r4 = "?"; if ($bench.localSeqWriteMBps) { $r4 = "{0:N2}x" -f ($bench.localSeqWriteMBps / $bench.baselineLocalWriteMBps) }
    W ("| U 盘小文件写 | " + (Fmt-Text $bench.usbSmallFilesPerSec "未测") + " 文件/秒 | 50.0 文件/秒 | " + $r1 + " |")
    W ("| U 盘顺序读（无缓冲） | " + (Fmt-Text $bench.usbSeqReadMBps "未测") + " MB/s | 31.1 MB/s | " + $r3 + " |")
    W ("| U 盘顺序写 | " + (Fmt-Text $bench.usbSeqWriteMBps "未测") + " MB/s | 20.6 MB/s | " + $r2 + " |")
    W ("| 本机盘顺序写 | " + (Fmt-Text $bench.localSeqWriteMBps "未测") + " MB/s | 744 MB/s | " + $r4 + " |")
    W ""
    W ("- 预估首次缓存（按本机+本盘实测的 60-75 秒标定）：约 " + (Fmt-Text $bench.estFirstCacheSecBytes "?") + " 秒")
    W ("- 串行逐文件估计（偏保守）：约 " + (Fmt-Text $bench.estFirstCacheSecFiles "?") + " 秒")
    W ("- 顺序读方式：" + (Fmt-Text $bench.readMode "未测"))
    if (@($bench.usbSmallRounds).Count -gt 0) { W ("- 小文件写两轮：" + ((@($bench.usbSmallRounds) | ForEach-Object { [string]$_ }) -join " / ") + " 文件/秒") }
    W ("- 测速方法：" + $bench.method)
}
W ""
W "## 6. 原始数据"
W ""
W ("- JSON：raw\" + $baseName + ".json")
W ""

$mdErr = ""
try {
    [System.IO.File]::WriteAllText($mdPath, ($L -join $CRLF), (New-Object System.Text.UTF8Encoding($true)))
} catch { $mdErr = [string]$_.Exception.Message }

Say ""
Say "--------------------------------------------"
if ($jsonErr) { Say "[警告] JSON 写入失败：$jsonErr" }
if ($mdErr)   { Say "[警告] 报告写入失败：$mdErr" }
Say "报告已写入 : $mdPath"
Say "原始数据   : $jsonPath"
Say ("本次耗时   : {0:N0} 秒" -f ((Get-Date) - $t0).TotalSeconds)

# ===========================================================================
#  重建索引
# ===========================================================================
$idxErr = ""
try {
    $all = @()
    foreach ($f in (Get-ChildItem -LiteralPath $rawDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $j = $null
        try { $j = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { continue }
        if ($null -eq $j) { continue }
        $all += [pscustomobject]@{ File = $f; Data = $j }
    }

    $I = New-Object System.Collections.ArrayList
    function IW([string]$s) { [void]$I.Add($s) }
    IW "# U 盘 Codex · 宿主电脑档案索引"
    IW ""
    IW "> 这个目录记录了 U 盘插过的每一台电脑的硬件、系统、兼容性与实测性能，"
    IW "> 用来优化「便携版 Codex」（首次缓存耗时、能否运行、拦截风险）。"
    IW "> 采集器：collect-pc.ps1 ｜ 每台机器的完整报告见本目录，原始数据见 raw\ 目录。"
    IW ""
    IW "## 怎么用"
    IW ""
    IW "1. 把 U 盘插到一台新电脑，双击【Windows】收集本机环境档案.cmd（约 30 秒）"
    IW "2. 结果自动写回本目录"
    IW "3. 在 Codex 对话里说：读一下 电脑档案\索引.md 和 raw\ 里的 JSON，帮我优化便携版"
    IW ""
    IW "## 汇总（同一台机器只显示最近一次）"
    IW ""
    IW "| 机器 | 采集时间 | 系统 | CPU | 内存 | 系统盘 | U盘小文件写 | U盘顺序读 | U盘顺序写 | 预估首次缓存 | 结论 |"
    IW "|---|---|---|---|---|---|---|---|---|---|---|"
    $byKey = @{}
    foreach ($it in $all) {
        $k = [string]$it.Data.identity.machineKey
        if (-not $k) { $k = [string]$it.Data.identity.computerName }
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @() }
        $byKey[$k] = @($byKey[$k]) + @($it)
    }
    $rows = @()
    foreach ($k in $byKey.Keys) {
        $items = @($byKey[$k] | Sort-Object { $_.Data.collectedAt })
        $latest = $items[$items.Count - 1]
        $d = $latest.Data
        $sysShort = ([string]$d.os.caption -replace "^Microsoft ", "")
        $cpuShort = [string]$d.hardware.cpu
        if ($cpuShort.Length -gt 34) { $cpuShort = $cpuShort.Substring(0, 34) + "..." }
        $est = "-"
        if ($d.bench.estFirstCacheSecBytes) { $est = ([string]$d.bench.estFirstCacheSecBytes + " 秒") }
        $verdict = "可以"
        if ($d.verdict.canRun -eq $false) { $verdict = "**不行**" }
        elseif (@($d.verdict.warnings).Count -gt 0) { $verdict = "可以（" + @($d.verdict.warnings).Count + " 项注意）" }
        $rows += ("| " + [string]$d.identity.computerName + " | " + [string]$d.collectedAt + " | " + $sysShort + " " + [string]$d.os.build + " | " + $cpuShort + " | " + (Fmt-Size $d.hardware.ramBytes) + " | " + [string]$d.hardware.systemDisk.mediaType + " | " + (Fmt-Text $d.bench.usbSmallFilesPerSec "-") + " | " + (Fmt-Text $d.bench.usbSeqReadMBps "-") + " | " + (Fmt-Text $d.bench.usbSeqWriteMBps "-") + " | " + $est + " | " + $verdict + " |")
    }
    foreach ($r in ($rows | Sort-Object)) { IW $r }
    IW ""
    IW "## 全部记录"
    IW ""
    foreach ($it in ($all | Sort-Object { $_.Data.collectedAt })) {
        $d = $it.Data
        IW ("- " + [string]$d.collectedAt + "  " + [string]$d.identity.computerName + "  （" + [string]$d.identity.model + "，" + [string]$d.os.caption + "）  → " + ($it.File.Name -replace "\.json$", ".md"))
    }
    IW ""
    $idxPath = Join-Path $archive "索引.md"
    [System.IO.File]::WriteAllText($idxPath, ($I -join $CRLF), (New-Object System.Text.UTF8Encoding($true)))
    Say "索引已更新 : $idxPath"
} catch { $idxErr = [string]$_.Exception.Message }
if ($idxErr) { Say "[警告] 索引重建失败：$idxErr" }

Say "--------------------------------------------"
Say ""
Say "完成。直接关掉这个窗口即可（U 盘可以拔了）。"
Say ""
Say ("档案目录: " + $archive)
