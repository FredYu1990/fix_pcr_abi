$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:LogFile = $null
$logDir = $env:PCR_ABI_LOG_DIR
if (-not $logDir) { $logDir = $PSScriptRoot }
$logCands = @()
if ($logDir) { $logCands += "$logDir\pcr-abi-fix.log" }
$logCands += "$env:TEMP\pcr-abi-fix.log"
foreach ($logCand in $logCands) {
    try {
        [IO.File]::AppendAllText($logCand, "`r`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === PCR ABI 修复工具启动 ===`r`n", [Text.Encoding]::UTF8)
        $script:LogFile = $logCand
        break
    } catch {}
}
function Log([string]$Msg) {
    Write-Host $Msg
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] $Msg`r`n", [Text.Encoding]::UTF8) } catch {}
    }
}

function LogDiag([string]$Msg) {
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] $Msg`r`n", [Text.Encoding]::UTF8) } catch {}
    }
}

function Get-DisplayWidth([string]$s) {
    if ($null -eq $s -or $s -eq '') { return 0 }
    $w = 0
    foreach ($c in $s.ToCharArray()) {
        $code = [int]$c
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Pad-Display([string]$s, [int]$width) {
    $pad = $width - (Get-DisplayWidth $s)
    if ($pad -le 0) { return $s }
    return $s + (' ' * $pad)
}

function Write-Section([string]$Title) {
    $left = '-' * 16
    $middle = " $Title"
    $middleW = Get-DisplayWidth $middle
    $right = '-' * [Math]::Max(1, 64 - 16 - $middleW)
    Write-Host ($left + $middle + $right)
}

try { $Host.UI.RawUI.WindowTitle = 'PCR ABI 修复工具 - 公主连结模拟器卡顿修复' } catch {}

$script:ExitCode = 0
function Raise-ExitCode([int]$c) { if ($script:ExitCode -lt $c) { $script:ExitCode = $c } }

function Finish {
    Write-Host ''
    Write-Host "[完成] 退出码 $script:ExitCode（0=成功/无需修复 1=环境错误 2=有失败 3=严重错误 9=启动器失败）"
    if ($env:PCR_ABI_NO_PAUSE -ne '1') { Read-Host '按回车键退出' | Out-Null }
    exit $script:ExitCode
}

function Show-QQTip {
    Write-Host ''
    Write-Host '  ******************************************' -ForegroundColor Yellow
    Write-Host '  *                                        *' -ForegroundColor Yellow
    Write-Host '  *    欢迎使用				               *' -ForegroundColor Black -BackgroundColor Yellow
    Write-Host '  *                                        *' -ForegroundColor Yellow
    Write-Host '  ******************************************' -ForegroundColor Yellow
    Write-Host ''
}

function Invoke-Tool {
    param([string]$Exe, [string[]]$ToolArgs, [int]$TimeoutMs = 0)
    if ($TimeoutMs -le 0) {
        $out = $null | & $Exe @ToolArgs 2>$null
        $script:ToolExit = $LASTEXITCODE
        $script:ToolStderr = ''  
        if ($null -eq $out) { return @() }
        return @($out | ForEach-Object { [string]$_ })
    }

    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = ($ToolArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)

        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try { $proc.Kill() } catch {}
            $script:ToolExit = -1  
            $script:ToolStderr = ''
            LogDiag "[超时] $Exe $($ToolArgs -join ' ') 超过 ${TimeoutMs}ms 未退出，已终止"
            return @()
        }
        $proc.WaitForExit()  
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        $script:ToolExit = $proc.ExitCode
        $script:ToolStderr = $stderr  
        if ($stderr) {
            $stderrShort = $stderr.Trim()
            if ($stderrShort.Length -gt 500) { $stderrShort = $stderrShort.Substring(0, 500) + '...' }
            LogDiag "[stderr] $Exe exit=$($proc.ExitCode): $stderrShort"
        }
        $out = @()
        if ($stdout) { $out = @($stdout -split "`r?`n" | Where-Object { $_.Trim() }) }
        return $out
    } finally {
        if ($proc) { try { $proc.Dispose() } catch {} }
    }
}


function Get-FirstOutputLine([string[]]$Lines) {
    if ($null -eq $Lines -or $Lines.Count -eq 0) { return '' }
    return ([string]$Lines[0]).Trim()
}

function Get-PrimaryCpuAbi([string[]]$Lines) {
    foreach ($line in @($Lines)) {
        $m = [regex]::Match([string]$line, '^\s*primaryCpuAbi\s*=\s*(x86_64|arm64-v8a|armeabi-v7a|x86)\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

function Get-AlternativeAbis([string]$CurrentAbi) {
    @('x86_64', 'arm64-v8a', 'armeabi-v7a') | Where-Object { $_ -ne $CurrentAbi }
}

function Invoke-VmShell([string]$VmIndex, [string]$Cmd) {

    $script:ShellBackend = 'mu'
    $script:ShellTarget = $VmIndex
    return Invoke-RemoteShell $Cmd
}

function Invoke-RemoteShell([string]$Cmd, [int]$TimeoutMs = 15000) {
    if ($script:ShellBackend -eq 'adb') {
        return Invoke-Tool $script:Adb @('-s', $script:ShellTarget, 'shell', $Cmd) $TimeoutMs
    } else {
        return Invoke-Tool $script:MuMuCli @('sh', '--vmindex', $script:ShellTarget, '--cmd', $Cmd) $TimeoutMs
    }
}

function Get-RemotePackageAbiInfo([string]$Package) {
    $pathOut = @(Invoke-RemoteShell "pm path $Package")
    if ($script:ToolExit -ne 0) { return $null }
    $pkLines = @($pathOut | Where-Object { $_ -match '^package:' })
    if ($pkLines.Count -ne 1) { return $null }
    $apk = ([string]$pkLines[0] -replace '^package:', '').Trim()
    if (-not $apk) { return $null }

    $abiOut = @(Invoke-RemoteShell "dumpsys package $Package | grep primaryCpuAbi")
    if ($script:ToolExit -ne 0) { return $null }
    $abi = Get-PrimaryCpuAbi $abiOut
    if (-not $abi) { return $null }
    [pscustomobject]@{ Package = $Package; Apk = $apk; CurAbi = $abi }
}

function Invoke-AbiReinstall($Item, [string]$TargetAbi) {
    $script:ShellBackend = $Item.Backend
    $script:ShellTarget = $Item.Target
    if ($Item.Cli) { $script:MuMuCli = $Item.Cli }

    Invoke-RemoteShell "am force-stop $($Item.Pkg)" | Out-Null
    $installOut = @(Invoke-RemoteShell "pm install -r --abi $TargetAbi '$($Item.Apk)'" 120000)
    if ($script:ToolExit -ne 0 -or -not (($installOut -join "`n") -match '(?m)^\s*Success\s*$')) {
        return [pscustomobject]@{ Success = $false; Reason = 'install'; ActualAbi = ''; Output = $installOut }
    }

    $abiOut = @(Invoke-RemoteShell "dumpsys package $($Item.Pkg) | grep primaryCpuAbi")
    $actualAbi = Get-PrimaryCpuAbi $abiOut
    if ($script:ToolExit -ne 0 -or $actualAbi -ne $TargetAbi) {
        return [pscustomobject]@{ Success = $false; Reason = 'abi'; ActualAbi = $actualAbi; Output = $abiOut }
    }
    [pscustomobject]@{ Success = $true; Reason = ''; ActualAbi = $actualAbi; Output = $abiOut }
}

function Test-PortsOpen([string]$HostName, [int[]]$Ports, [int]$TimeoutMs = 300) {
    $clients = New-Object System.Collections.Generic.List[object]
    $iars = New-Object System.Collections.Generic.List[object]
    foreach ($port in $Ports) {
        $c = New-Object System.Net.Sockets.TcpClient
        $clients.Add($c)
        try { $iars.Add($c.BeginConnect($HostName, $port, $null, $null)) } catch { $iars.Add($null) }
    }
    $open = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Ports.Count; $i++) {
        if ($iars[$i] -and $iars[$i].AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            try { $clients[$i].EndConnect($iars[$i]); $open.Add($Ports[$i]) } catch {}
        }
    }
    foreach ($c in $clients) { try { $c.Close() } catch {} }
    $open
}

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Log "[错误] PowerShell 版本过低（$($PSVersionTable.PSVersion)），需 3.0+。请升级 Windows Management Framework。"
    Show-QQTip
    Finish
}

try {

Write-Host '================================================================'
Write-Host '   PCR ABI 一体化修复工具（雷电 + MuMu）'
Write-Host '   问题：模拟器选择 ARM ABI 后经翻译层运行，可能导致卡顿'
Write-Host '================================================================'
Write-Host ''


$script:AllProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$script:MuMuAdbPorts = @()
$script:MuMuCliHandledPorts = @()
$script:MuMuHandledAids = @{}
$script:MuMuRoots = New-Object System.Collections.Generic.List[string]
$seenMuMuRoot = @{}
function Add-MuMuRoot([string]$Dir) {
    if (-not $Dir) { return }
    try { $Dir = [IO.Path]::GetFullPath($Dir.TrimEnd('\')) } catch { return }
    $key = $Dir.ToLowerInvariant()
    if (-not $seenMuMuRoot.ContainsKey($key)) { $seenMuMuRoot[$key] = $true; $script:MuMuRoots.Add($Dir) | Out-Null }
}
foreach ($p in @($script:AllProcs | Where-Object { $_.Name -like 'MuMu*' })) {
    if ($p.ExecutablePath) { Add-MuMuRoot (Split-Path -Parent $p.ExecutablePath) }
}

$script:MuMuClis = @()
$cand = New-Object System.Collections.Generic.List[string]
if ($env:PCR_ABI_MUMU_CLI) { $cand.Add($env:PCR_ABI_MUMU_CLI) }
foreach ($root in $script:MuMuRoots) {
    foreach ($sub in @('.', 'nx_main')) {
        $cand.Add((Join-Path (Join-Path $root $sub) 'mumu-cli.exe')) | Out-Null
    }
}
$seenCli = @{}
foreach ($x in $cand) {
    if (-not $x) { continue }
    try { $fx = [IO.Path]::GetFullPath($x) } catch { continue }
    $key = $fx.ToLowerInvariant()
    if ($seenCli.ContainsKey($key)) { continue }
    $seenCli[$key] = $true
    if (Test-Path -LiteralPath $fx) {
        LogDiag "[扫描] mumu-cli 候选: $fx"
        Invoke-Tool $fx @('version') 10000 | Out-Null
        if ($script:ToolExit -eq 0) { $script:MuMuClis += , $fx }
    }
}
$MuMuOk = ($script:MuMuClis.Count -gt 0)
$script:MuMuManagerClis = @()
$mgrCand = New-Object System.Collections.Generic.List[string]
if ($env:PCR_ABI_MUMU_CLI) {
    $mgrCand.Add($env:PCR_ABI_MUMU_CLI)
}
foreach ($root in $script:MuMuRoots) {
    foreach ($sub in @('.', 'nx_main', 'shell')) {
        $mgrCand.Add((Join-Path (Join-Path $root $sub) 'MuMuManager.exe')) | Out-Null
    }
}
$seenMgr = @{}
foreach ($x in $mgrCand) {
    if (-not $x) { continue }
    try { $fx = [IO.Path]::GetFullPath($x) } catch { continue }
    $key = $fx.ToLowerInvariant()
    if ($seenMgr.ContainsKey($key)) { continue }
    $seenMgr[$key] = $true
    if (Test-Path -LiteralPath $fx) {
        $siblingCli = Join-Path (Split-Path -Parent $fx) 'mumu-cli.exe'
        if (Test-Path -LiteralPath $siblingCli) {
            LogDiag "[扫描] MuMuManager 跳过（同目录有 mumu-cli.exe，属旧版）: $fx"
            continue
        }
        LogDiag "[扫描] MuMuManager 候选: $fx"
        Invoke-Tool $fx @('info', '-v', '0') 10000 | Out-Null
        if ($script:ToolExit -eq 0) { $script:MuMuManagerClis += , $fx }
    }
}
$script:DevNames = @{}

$script:Adb = $null
foreach ($n in @('dnplayer.exe', 'LDPlayer9.exe', 'dnplayer9.exe')) {
    foreach ($p in @($script:AllProcs | Where-Object { $_.Name -eq $n })) {
        if ($p.ExecutablePath) {
            $a = Join-Path (Split-Path -Parent $p.ExecutablePath) 'adb.exe'
            if (Test-Path -LiteralPath $a) { $script:Adb = $a; break }
        }
    }
    if ($script:Adb) { break }
}
if (-not $script:Adb) {
    foreach ($root in $script:MuMuRoots) {
        foreach ($sub in @('.', 'shell', 'nx_main', '..\shell', 'nx_device\12.0\shell')) {
            $a = Join-Path (Join-Path $root $sub) 'adb.exe'
            try { $a = [IO.Path]::GetFullPath($a) } catch { continue }
            if (Test-Path -LiteralPath $a) { $script:Adb = $a; break }
        }
        if ($script:Adb) { break }
    }
}
if (-not $script:Adb) {
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { $script:Adb = $w.Source }
}
$LdOk = $false
if ($script:Adb) {
    LogDiag "[扫描] ADB 验证: $script:Adb"
    Invoke-Tool $script:Adb @('version') 10000 | Out-Null
    if ($script:ToolExit -eq 0) { $LdOk = $true }
}

Write-Host '[检测] 环境：'
if ($MuMuOk) {
    foreach ($c in $script:MuMuClis) {
        $cliRootName = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $c))
        $cliLabel = if ($cliRootName -like '*Global*') { 'MuMuGlobal CLI' } else { 'MuMu CLI' }
        Write-Host "  $cliLabel : $c"
    }
} else { Write-Host '  MuMu CLI : 未找到（跳过 MuMu 检测）' }
if ($LdOk)   { Write-Host "  ADB      : $script:Adb" }     else { Write-Host '  ADB      : 未找到（跳过 ADB 检测）' }
Write-Host ''

if (-not $MuMuOk -and -not $LdOk) {
    Write-Host '[错误] 既未找到 MuMu CLI 也未找到 adb.exe。'
    Write-Host '       请先启动模拟器，或设置 PCR_ABI_MUMU_CLI / 将 adb.exe 加入 PATH。'
    Raise-ExitCode 1
    Show-QQTip
    Finish
}

$MuInstanceCount = 0
$MuNonRootCount = 0
$MuPlan = New-Object System.Collections.Generic.List[object]
$script:MuSwitchPlan = New-Object System.Collections.Generic.List[object]
$script:MuAbiPlan = New-Object System.Collections.Generic.List[object]
$script:MuAbiSwitchPlan = New-Object System.Collections.Generic.List[object]
$script:MuMuInstanceNames = @{}
$script:CurInstName = ''

function Test-SafeRemotePath([string]$p) {
    return ($p -match '^/[A-Za-z0-9._/-]+$')
}

function Inspect-MuMuConfig([string]$RemotePath) {
    if (-not (Test-SafeRemotePath $RemotePath)) {
        Write-Host '    [跳过] 路径包含不安全字符或非绝对路径。'
        return
    }
    LogDiag "[MuMu] 检查配置文件: $RemotePath"
    if ($RemotePath -like '/system/*') {
        $mount = Invoke-RemoteShell "grep ' /system ' /proc/mounts"
        if ($script:ToolExit -ne 0) {
            LogDiag '[MuMu] /system 挂载状态读取失败，跳过'
            return
        }
        if (-not (($mount -join "`n") -match ' rw,')) {
            LogDiag '[MuMu] /system 是只读系统基线，已跳过'
            return
        }
    }
    $rel = @()
    for ($try = 1; $try -le 3; $try++) {
        $rel = @(Invoke-RemoteShell "grep -n -F 'priconne' '$RemotePath'" | Where-Object { $_ -ne '' })
        if ($rel.Count -gt 0) { break }
        Start-Sleep -Milliseconds 300
    }
    if ($rel.Count -eq 0) {
        LogDiag "[MuMu] 配置 $RemotePath 中无 priconne 条目"
        return
    }
    Write-Host "      $RemotePath"
    $pkgDefs = @(
        @{ Show = 'com.bilibili.priconne'; Rx = '^(\d+):com\\\.bilibili\\\.priconne(?![\\.\w])' },
        @{ Show = 'com.bilibili.priconne.yofun.mumu'; Rx = '^(\d+):com\\\.bilibili\\\.priconne\\\.yofun\\\.mumu(?![\\.\w])' }
    )
    foreach ($pkg in $pkgDefs) {
        $hits = @($rel | Where-Object { $_ -match $pkg.Rx })
        if ($hits.Count -eq 0) {
            LogDiag "[MuMu] $($pkg.Show) 未找到配置行"
            continue
        }
        if ($hits.Count -gt 1) {
            Write-Host "        [$($pkg.Show)] 配置行重复，已跳过" -ForegroundColor DarkGray
            continue
        }
        $lineText = [string]$hits[0]
        $null = $lineText -match $pkg.Rx
        $lineNo = [int]$Matches[1]
        LogDiag "[MuMu] 原始配置行: $lineText"
        $curAbi = $null
        if ($lineText -match 'x86_64') { $curAbi = 'x86_64' }
        elseif ($lineText -match 'armeabi-v7a') { $curAbi = 'armeabi-v7a' }
        elseif ($lineText -match 'arm64-v8a') { $curAbi = 'arm64-v8a' }
        elseif ($lineText -match 'x86') { $curAbi = 'x86' }
        if (-not $curAbi) {
            Write-Host "        [$($pkg.Show)] ABI 值异常，已跳过" -ForegroundColor Red
            continue
        }
        $script:MuSwitchPlan.Add(@{ Backend = $script:ShellBackend; Vm = $script:ShellTarget; Path = $RemotePath; Cli = $script:MuMuCli; Tag = $script:CliTag; PkgShow = $pkg.Show; CurAbi = $curAbi; Line = $lineNo; InstName = $script:CurInstName })
        if ($curAbi -eq 'x86_64') {
            Write-Host "        $($pkg.Show): $curAbi ✓" -ForegroundColor Green
        } else {
            Write-Host "        $($pkg.Show): $curAbi [待修]" -ForegroundColor Yellow
            $script:MuPlan.Add(@{ Backend = $script:ShellBackend; Vm = $script:ShellTarget; Path = $RemotePath; Cli = $script:MuMuCli; Tag = $script:CliTag; PkgShow = $pkg.Show; From = $curAbi; Line = $lineNo; InstName = $script:CurInstName })
        }
    }
}

function Retry-ShellIdWithFallback([string]$Label, [int]$AdbPort, [int]$RetryDelaySec = 3) {
    Start-Sleep -Seconds $RetryDelaySec
    $retry = Invoke-RemoteShell 'id'
    $retryStr = ($retry -join '').Trim()
    if ($retryStr) {
        LogDiag "[重试] $Label 第二次 'id' 成功（backend=$($script:ShellBackend)）"
        return @($retry)
    }
    LogDiag "[重试] $Label 第二次 'id' 仍为空（backend=$($script:ShellBackend)）"
    if ($AdbPort -gt 0 -and $script:ShellBackend -ne 'adb' -and $script:Adb) {
        $dev = "127.0.0.1:$AdbPort"
        LogDiag "[fallback] $Label 尝试 ADB backend: $dev"
        $connOut = @(Invoke-Tool $script:Adb @('connect', $dev) 10000)
        LogDiag "[fallback] adb connect $dev -> exit=$script:ToolExit out=$($connOut -join '; ')"
        $devs = @(Invoke-Tool $script:Adb @('devices') 10000)
        $connected = $false
        foreach ($d in $devs) {
            if ($d -match ('^' + [regex]::Escape($dev) + '\s+device')) { $connected = $true; break }
        }
        if (-not $connected) {
            LogDiag "[fallback] $dev 未出现在 devices 列表，放弃"
            return $null
        }
        Invoke-Tool $script:Adb @('-s', $dev, 'root') 15000 | Out-Null
        Start-Sleep -Milliseconds 300
        $script:ShellBackend = 'adb'
        $script:ShellTarget = $dev
        $fbOut = Invoke-RemoteShell 'id'
        $fbStr = ($fbOut -join '').Trim()
        if ($fbStr) {
            LogDiag "[fallback] $Label ADB backend 'id' 成功"
            $aid = Get-FirstOutputLine (Invoke-RemoteShell 'settings get secure android_id')
            if ($aid -and $aid -ne 'null' -and -not $script:MuMuHandledAids.ContainsKey($aid)) {
                $script:MuMuHandledAids[$aid] = $true
                LogDiag "[fallback] $Label android_id=$aid 已记录（供 ADB 阶段去重）"
            }
            return @($fbOut)
        }
        LogDiag "[fallback] $Label ADB backend 'id' 仍为空，放弃"
        return $null
    }
    return $null
}

function Inspect-MuMuInstanceCommon([string]$Label, [int]$AdbPort = 0) {
    $idOut = Invoke-RemoteShell 'id'
    if ($script:ToolExit -eq -1) {
        Write-Host "  [$Label] ADB 响应超时，模拟器可能未完全启动。"
        Write-Host "           请等待 30s 后重试；若反复出现请检查防火墙是否拦截了 MuMu 联网。"
        $script:MuNonRootCount++
        Raise-ExitCode 1
        return
    }
    if ($script:ToolExit -ne 0) { Write-Host "  [$Label] 状态读取失败（exit=$script:ToolExit），已跳过。"; Raise-ExitCode 1; return }
    $idStr = ($idOut -join '').Trim()
    if (-not $idStr) {
        LogDiag "[空响应] $Label 第一次 'id' 为空（stderr=$($script:ToolStderr)），尝试重试"
        $retryOut = Retry-ShellIdWithFallback $Label $AdbPort
        if ($null -ne $retryOut) {
            $idOut = $retryOut
            $idStr = ($idOut -join '').Trim()
        } else {
            Write-Host "  [$Label] ADB 返回空响应，模拟器可能未完全启动。"
            Write-Host "           请等待 30s 后重试；若反复出现请检查防火墙是否拦截了 MuMu 联网。"
            $script:MuNonRootCount++
            Raise-ExitCode 1
            return
        }
    }
    if (-not ($idStr -match '^uid=0\(root\)')) {
        $script:MuNonRootCount++
        Write-Host "  [$Label] 未开启 Root 权限，无法检测" -ForegroundColor Red
        Write-Host "           开启方法：MuMu 设备设置 → 开发者选项 → 开启 Root 权限，保存后重启该模拟器再运行本工具。" -ForegroundColor DarkGray
        Raise-ExitCode 1
        return
    }
    if ($script:ShellBackend -eq 'mu') {
        $aid = Get-FirstOutputLine (Invoke-RemoteShell 'settings get secure android_id')
        if ($aid -and $aid -ne 'null' -and -not $script:MuMuHandledAids.ContainsKey($aid)) {
            $script:MuMuHandledAids[$aid] = $true
            LogDiag "[MuMu] VM $Label android_id=$aid 已记录（供 ADB 阶段去重）"
        }
    }
    $ver = (Invoke-RemoteShell 'getprop ro.build.version.release' | Select-Object -First 1)
    if ($script:ToolExit -ne 0) { $ver = '?' } else { $ver = Get-FirstOutputLine @($ver) }
    $vmIdx = if ($Label -match '^VM\s+(\d+)$') { $Matches[1] } else { $Label }
    $instName = ''
    if ($script:MuMuInstanceNames -and $script:MuMuInstanceNames.ContainsKey($vmIdx)) {
        $instName = $script:MuMuInstanceNames[$vmIdx]
    }
    if (-not $instName -and $script:DevNames -and $script:DevNames.ContainsKey($Label)) {
        $dn = [string]$script:DevNames[$Label]
        if ($dn -match '^[^:]+:(.+)$') { $instName = $Matches[1] }
    }
    if (-not $instName -and $script:ShellBackend -eq 'adb') {
        $model = Get-FirstOutputLine (Invoke-RemoteShell 'getprop ro.product.model')
        if ($model -and $model -ne 'null') {
            $instName = $model
            if ($script:DevNames) { $script:DevNames[$Label] = "ADB:$model" }
        }
    }
    $script:CurInstName = $instName
    if ($instName) {
        if ($Label -match '^VM\s+\d+$') {
            $title = "$instName (Android $ver)"
        } else {
            $title = "$(Pad-Display "$instName (Android $ver)" 32)$Label"
        }
    } else {
        $title = "$Label (Android $ver)"
    }
    Write-Host "  $title"
    Write-Host ''
    Write-Host '    配置文件：'
    $configName = if ($ver -match '^12(?:\.|$)') { 'abi-select-android12.config' } elseif ($ver -match '^15(?:\.|$)') { 'abi-select-v2.config' } else { '' }
    $configs = if ($configName) {
        @(Invoke-RemoteShell "find /data/system/etc/mumu-configs /system/etc/mumu-configs -type f -name '$configName' 2>/dev/null")
    } else { @() }

    if ($script:ToolExit -eq -1) { Write-Host '    [状态] 配置搜索超时，请重试' -ForegroundColor Red; Raise-ExitCode 1; return }
    $found = $false
    foreach ($f in $configs) {
        $f = $f.Trim()
        if ($f) { Inspect-MuMuConfig $f; $found = $true }
    }
    if (-not $found) { Write-Host '    [状态] 未找到 abi-select 配置文件' -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '    游戏 ABI：'
    foreach ($pkg in @('com.bilibili.priconne', 'com.bilibili.priconne.yofun.mumu')) {
        $info = Get-RemotePackageAbiInfo $pkg
        if (-not $info) { continue }
        $item = @{
            Backend = $script:ShellBackend; Target = $script:ShellTarget; Vm = $script:ShellTarget
            Cli = $script:MuMuCli; Tag = $script:CliTag; InstName = $script:CurInstName
            Pkg = $pkg; Apk = $info.Apk; CurAbi = $info.CurAbi
        }
        $script:MuAbiSwitchPlan.Add($item)
        if ($info.CurAbi -eq 'x86_64') {
            Write-Host "      ${pkg}: $($info.CurAbi) ✓" -ForegroundColor Green
            continue
        }
        $libOut = Invoke-RemoteShell "unzip -l '$($info.Apk)' | grep -c 'lib/x86_64/'"
        $libCnt = 0
        foreach ($line in $libOut) {
            $value = ([string]$line).Trim()
            if ($value -match '^\d+$') { $libCnt = [int]$value }
        }
        if ($libCnt -eq 0) {
            Write-Host "      ${pkg}: $($info.CurAbi)（x86_64 库检测异常，已跳过）" -ForegroundColor DarkGray
            continue
        }
        Write-Host "      ${pkg}: $($info.CurAbi) [待修]" -ForegroundColor Yellow
        $script:MuAbiPlan.Add($item)
    }
}

function Inspect-MuMuInstance([string]$VmIndex, [int]$AdbPort = 0) {
    $script:MuInstanceCount++
    $script:ShellBackend = 'mu'
    $script:ShellTarget = $VmIndex
    Inspect-MuMuInstanceCommon "VM $VmIndex" $AdbPort
}

function Inspect-MuMuDeviceAdb([string]$Dev) {
    $script:MuInstanceCount++
    $script:ShellBackend = 'adb'
    $script:ShellTarget = $Dev
    $script:MuMuCli = $null
    Invoke-Tool $script:Adb @('-s', $Dev, 'root') 15000 | Out-Null
    Start-Sleep -Milliseconds 300  
    Inspect-MuMuInstanceCommon $Dev
}

foreach ($cli in $script:MuMuClis) {
    $script:MuMuCli = $cli
    $script:CliTag = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $cli))
    $script:CliShort = if ($script:CliTag -eq 'MuMuPlayer') { 'MuMu' } elseif ($script:CliTag -eq 'MuMuPlayerGlobal') { 'MuMu Global' } else { $script:CliTag }
    $infoRaw = Invoke-Tool $script:MuMuCli @('info', '--vmindex', 'all') 15000
    if ($script:ToolExit -ne 0) {
        LogDiag "[MuMu] $script:CliTag info 调用失败（exit=$script:ToolExit），跳过"
        Raise-ExitCode 1
        continue
    }
    $items = @()
    try {
        $root = ($infoRaw -join "`n") | ConvertFrom-Json
        if ($root.PSObject.Properties['index']) {
            $items = @($root)   
        } else {
            $items = @($root.PSObject.Properties | ForEach-Object { $_.Value })
        }
        $items = @($items | Where-Object {
            $_.is_process_started -eq $true -and $_.is_android_started -eq $true -and
            $_.player_state -eq 'start_finished' -and ([string]$_.index) -match '^\d+$'
        } | Sort-Object { [int]$_.index })
    } catch {
        LogDiag "[MuMu] $script:CliTag 实例信息无法解析，已跳过"
        Raise-ExitCode 1
        $items = @()
    }

    if ($items.Count -eq 0) {
        LogDiag "[MuMu] $script:CliTag 未发现已启动实例"
        continue
    }
    Write-Section "$script:CliShort 检测"
    $script:MuMuInstanceNames = @{}
    foreach ($it in $items) {
        $script:MuMuInstanceNames[[string]$it.index] = $it.name
        foreach ($pn in @('adb_port', 'adb_host_port')) {
            if ($it.PSObject.Properties[$pn] -and $it.$pn) {
                $script:DevNames["127.0.0.1:$($it.$pn)"] = "MuMu($script:CliTag):$($it.name)"
                $script:MuMuAdbPorts += [int]$it.$pn
                $script:MuMuCliHandledPorts += [int]$it.$pn  
                break
            }
        }
    }
    foreach ($it in $items) {
        $ap = 0
        foreach ($pn in @('adb_port', 'adb_host_port')) {
            if ($it.PSObject.Properties[$pn] -and $it.$pn) { $ap = [int]$it.$pn; break }
        }
        Inspect-MuMuInstance ([string]$it.index) $ap
    }
    Write-Host ''
}


foreach ($mgr in $script:MuMuManagerClis) {
    $script:MuMuCli = $mgr
    $script:CliTag = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $mgr))
    $script:CliShort = if ($script:CliTag -like '*MuMuPlayer*12*' -or $script:CliTag -eq 'mumu12') { 'MuMu12' } else { $script:CliTag }
    $infoRaw = Invoke-Tool $script:MuMuCli @('info', '--vmindex', 'all') 15000
    if ($script:ToolExit -ne 0) {
        LogDiag "[MuMu12] $script:CliTag 无法读取实例信息（$mgr），已跳过"
        Raise-ExitCode 1
        continue
    }
    $items = @()
    try {
        $root = ($infoRaw -join "`n") | ConvertFrom-Json
        if ($root.PSObject.Properties['index']) {
            $items = @($root)   
        } else {
            $items = @($root.PSObject.Properties | ForEach-Object { $_.Value })
        }
        $items = @($items | Where-Object {
            $_.is_process_started -eq $true -and $_.is_android_started -eq $true -and
            $_.player_state -eq 'start_finished' -and ([string]$_.index) -match '^\d+$'
        } | Sort-Object { [int]$_.index })
    } catch {
        LogDiag "[MuMu12] $script:CliTag 实例信息无法解析，已跳过"
        Raise-ExitCode 1
        $items = @()
    }

    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        $adbPort = 0
        foreach ($pn in @('adb_port', 'adb_host_port')) {
            if ($it.PSObject.Properties[$pn] -and $it.$pn) { $adbPort = [int]$it.$pn; break }
        }

        if ($adbPort -gt 0 -and $script:MuMuCliHandledPorts -contains $adbPort) {
            LogDiag "[MuMu12] VM $($it.index) adb_port=$adbPort 已由 mumu-cli 阶段处理，跳过"
            continue
        }
        $pending.Add(@{ Index = $it.index; Name = $it.name; Port = $adbPort }) | Out-Null
        if ($adbPort -gt 0) {
            $script:DevNames["127.0.0.1:$adbPort"] = "MuMu12($script:CliTag):$($it.name)"
            $script:MuMuAdbPorts += $adbPort
        }
    }
    if ($pending.Count -eq 0) {
        LogDiag "[MuMu12] $script:CliTag 未发现待 ADB 检测的实例"
        continue
    }
    LogDiag "[MuMu12] $script:CliTag 发现 $($pending.Count) 个已启动实例（将通过 ADB 检测 ABI）"
}


$LdDevCount = 0
$LdPlan = New-Object System.Collections.Generic.List[object]

$LdSwitchPlan = New-Object System.Collections.Generic.List[object]

function Inspect-LdPackage([string]$Dev, [string]$Pkg) {
    LogDiag "  [包] $Pkg"
    $script:ShellBackend = 'adb'
    $script:ShellTarget = $Dev
    $info = Get-RemotePackageAbiInfo $Pkg
    if (-not $info) { return }
    $apk = $info.Apk
    $curLdAbi = $info.CurAbi
    LogDiag "    [APK] $apk"
    $item = @{ Backend = 'adb'; Target = $Dev; Dev = $Dev; Pkg = $Pkg; Apk = $apk; Name = $script:CurDevLabel; CurAbi = $curLdAbi }
    if ($curLdAbi -eq 'x86_64') {
        Write-Host "    ${Pkg}: $curLdAbi ✓" -ForegroundColor Green
    } elseif ($curLdAbi) {
        $libOut = Invoke-RemoteShell "unzip -l $apk | grep -c lib/x86_64/"
        $libCnt = 0
        foreach ($l in $libOut) { $t = ([string]$l).Trim(); if ($t -match '^\d+$') { $libCnt = [int]$t } }
        if ($libCnt -eq 0) {
            Write-Host "    ${Pkg}: $curLdAbi（x86_64 库检测异常，已跳过）" -ForegroundColor DarkGray
        } else {
            Write-Host "    ${Pkg}: $curLdAbi [待修]" -ForegroundColor Yellow
            $script:LdPlan.Add($item)
        }
    }

    if ($curLdAbi) {
        $script:LdSwitchPlan.Add($item)
    }
}

if ($LdOk) {

    $ports = @(5555, 7555, 16384, 16416, 16448, 16480, 16512, 16544, 16576, 16608, 16640, 16672, 16704, 16736, 16768, 16800, 16832, 16864) +
             @(7556..7570) +   
             @(5557, 5559, 5561, 5563, 5565, 5567, 5569) +   
             $script:MuMuAdbPorts
    if ($env:PCR_ABI_EXTRA_PORTS) {
        foreach ($ep in ($env:PCR_ABI_EXTRA_PORTS -split ',')) {
            $epn = 0
            if ([int]::TryParse($ep.Trim(), [ref]$epn)) { $ports += $epn }
        }
    }

    $listening = @(Test-PortsOpen '127.0.0.1' (@($ports | Sort-Object -Unique)) 300)
    foreach ($port in $listening) {
        $connectOut = @(Invoke-Tool $script:Adb @('connect', "127.0.0.1:$port") 10000)
        LogDiag "[端口] connect 127.0.0.1:$port -> exit=$script:ToolExit, out=$($connectOut -join '; ')"
    }
    LogDiag "[端口] 预探测 $($ports.Count) 个，在听 $($listening.Count) 个$(if($listening.Count){':' + ($listening -join ',')})"

    if ($script:MuMuHandledAids.Count -gt 0) {
        $preDevs = @(Invoke-Tool $script:Adb @('devices') 10000 |
            Where-Object { $_ -match '^127\.0\.0\.1:(\d+)\s+device' } |
            ForEach-Object { ($_ -split '\s+')[0] })
        foreach ($pd in $preDevs) {
            if ($pd -match '^127\.0\.0\.1:(\d+)$') {
                $pdPort = [int]$Matches[1]
                if ($script:MuMuAdbPorts -contains $pdPort) { continue }
                $pdAid = Get-FirstOutputLine (Invoke-Tool $script:Adb @('-s', $pd, 'shell', 'settings', 'get', 'secure', 'android_id') 10000)
                if ($pdAid -and $pdAid -ne 'null' -and $script:MuMuHandledAids.ContainsKey($pdAid)) {
                    $script:MuMuAdbPorts += $pdPort
                    LogDiag "[端口补全] $pd android_id=$pdAid 匹配 MuMu，端口 $pdPort 已加入 MuMuAdbPorts"
                }
            }
        }
    }

    try {
        $ldConsole = Join-Path (Split-Path -Parent $script:Adb) 'ldconsole.exe'
        if (Test-Path -LiteralPath $ldConsole) {
            $tmpLd = Join-Path $env:TEMP ('pcrabi_ld_' + [guid]::NewGuid().ToString('N') + '.txt')
            Start-Process -FilePath $ldConsole -ArgumentList 'list2' -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpLd | Out-Null
            if (Test-Path -LiteralPath $tmpLd) {
                $ldList = [System.Text.Encoding]::GetEncoding(936).GetString([IO.File]::ReadAllBytes($tmpLd)) -split "`r?`n"
                Remove-Item -LiteralPath $tmpLd -Force -ErrorAction SilentlyContinue
                foreach ($ln in $ldList) {
                    $f = $ln -split ','
                    if ($f.Count -ge 5 -and $f[4] -eq '1') {
                        $serial = Get-FirstOutputLine (Invoke-Tool $ldConsole @('adb', '--index', $f[0], '--command', 'get-serialno') 10000)
                        if ($serial -match '^(emulator-|127\.)') {

                            $conflict = $false
                            if ($script:DevNames.ContainsKey($serial)) {
                                $existTag = [string]$script:DevNames[$serial]
                                if ($existTag -match '^MuMu') {
                                    $conflict = $true
                                    LogDiag "[冲突] 雷电 '$($f[1])' 的 ldconsole adb 返回 serial=$serial，但已被 MuMu 标记为 '$existTag'，端口冲突，跳过写入 DevNames"
                                }
                            }
                            if (-not $conflict -and $serial -match '^127\.0\.0\.1:(\d+)$') {
                                $ldPort = $Matches[1]
                                if ($script:MuMuAdbPorts -contains $ldPort) {
                                    $conflict = $true
                                    LogDiag "[冲突] 雷电 '$($f[1])' 的 ldconsole adb 返回 $serial，但端口 $ldPort 在 MuMu adb_port 列表中，端口冲突，跳过写入 DevNames"
                                }
                            }
                            if (-not $conflict -and $serial -match '^emulator-(\d+)$') {

                                $ldPort = [string]([int]$Matches[1] + 1)
                                if ($script:MuMuAdbPorts -contains $ldPort) {
                                    $conflict = $true
                                    LogDiag "[冲突] 雷电 '$($f[1])' 的 ldconsole adb 返回 $serial（端口 $ldPort），但端口 $ldPort 在 MuMu adb_port 列表中，端口冲突，跳过写入 DevNames"
                                }
                            }
                            if ($conflict) {
                                Write-Host "  [警告] 雷电 '$($f[1])' ADB 端口被 MuMu 占用（serial=$serial），该实例可能无法正常检测" -ForegroundColor Yellow
                                Write-Host "         建议：修改雷电 '$($f[1])' 的 ADB 端口，或关闭冲突的 MuMu 实例后重跑" -ForegroundColor Yellow
                            } else {
                                $script:DevNames[$serial] = $f[1]
                            }
                        }
                    }
                }
            }
        }
    } catch {}
    $devLines = Invoke-Tool $script:Adb @('devices') 10000
    LogDiag "[ADB] devices 原始输出："
    foreach ($dl in $devLines) { if ($dl.Trim()) { LogDiag "  $dl" } }
    $devs = @($devLines | Where-Object { $_ -match '^(emulator-\d+|127\.0\.0\.1:\d+)\s+device' } | ForEach-Object { ($_ -split '\s+')[0] })

    $devs = @($devs | Sort-Object {
        if ($_ -match '^emulator-') { 0 }
        elseif ($script:DevNames.ContainsKey($_)) { 1 }
        else { 2 }
    })
    $seenSerials = @{}
    $skippedMuMuDevCount = 0
    $currentAdbGroup = ''
    foreach ($dev in $devs) {
        $sno = Get-FirstOutputLine (Invoke-Tool $script:Adb @('-s', $dev, 'shell', 'getprop', 'ro.serialno') 10000)
        $dedupKey = $sno
        $aid = ''  
        if (-not $sno -or $sno -eq 'null') {
            $aid = Get-FirstOutputLine (Invoke-Tool $script:Adb @('-s', $dev, 'shell', 'settings', 'get', 'secure', 'android_id') 10000)
            if ($aid -and $aid -ne 'null') { $dedupKey = "aid:$aid" }
        }
        if ($dedupKey -and $dedupKey -ne 'null' -and $seenSerials.ContainsKey($dedupKey)) { LogDiag "[ADB] $dev dedupKey=$dedupKey 与 $($seenSerials[$dedupKey]) 重复，跳过"; continue }
        if ($dedupKey -and $dedupKey -ne 'null') { $seenSerials[$dedupKey] = $dev }
        LogDiag "[ADB] 处理设备 $dev serialno=$sno dedupKey=$dedupKey"
        $label = $script:DevNames[$dev]
        if (-not $label) {
            $model = Get-FirstOutputLine (Invoke-Tool $script:Adb @('-s', $dev, 'shell', 'getprop', 'ro.product.model') 10000)
            $label = "机型:$model"
        }
        LogDiag "[设备] $dev  （$label）"
        $script:CurDevLabel = $label
        $muTest = @(Invoke-Tool $script:Adb @('-s', $dev, 'shell',
            "ls -d /data/system/etc/mumu-configs 2>/dev/null; ls -d /system/etc/mumu-configs 2>/dev/null") 10000 |
            Where-Object { $_.Trim() })
        if ($muTest.Count -gt 0) {
            $devPort = 0
            if ($dev -match '^127\.0\.0\.1:(\d+)$') { $devPort = [int]$Matches[1] }
            if (-not $aid) {
                $aid = Get-FirstOutputLine (Invoke-Tool $script:Adb @('-s', $dev, 'shell', 'settings', 'get', 'secure', 'android_id') 10000)
            }
            $handledByMuCli = $false
            if ($aid -and $aid -ne 'null' -and $script:MuMuHandledAids.ContainsKey($aid)) { $handledByMuCli = $true }
            if (-not $handledByMuCli -and $devPort -gt 0 -and $script:MuMuCliHandledPorts -contains $devPort) { $handledByMuCli = $true }
            if ($handledByMuCli) {
                $skippedMuMuDevCount++
                LogDiag "[ADB] $dev 已由 mumu-cli 阶段处理，跳过"
                continue
            }
            if ($currentAdbGroup -ne 'mumu12') { Write-Section 'MuMu12 检测'; $currentAdbGroup = 'mumu12' }
            $script:CliTag = 'ADB'
            Inspect-MuMuDeviceAdb $dev
            Write-Host ''
        } else {
            if ($currentAdbGroup -ne 'ld') { Write-Section '雷电检测'; $currentAdbGroup = 'ld' }
            $LdDevCount++
            $pkgs = Invoke-Tool $script:Adb @('-s', $dev, 'shell', 'pm', 'list', 'packages', '-3') 15000
            $hits = @($pkgs | Where-Object { $_ -match 'priconne|pcrconne|princessconnect' } |
                     ForEach-Object { (($_ -split ':', 2)[1]).Trim() } | Where-Object { $_ })
            if ($hits.Count -eq 0) {
                Write-Host "  $(Pad-Display $label 14)$dev  未检测到 PCR 类包" -ForegroundColor DarkGray
                Write-Host ''
                continue
            }
            Write-Host "  $(Pad-Display $label 14)$dev"
            foreach ($pkg in $hits) { Inspect-LdPackage $dev $pkg }
            Write-Host ''
        }
    }
    if ($skippedMuMuDevCount -gt 0) {
        LogDiag "[ADB] 已跳过 $skippedMuMuDevCount 个 MuMu 设备（由 mumu-cli 阶段处理）"
    }
    if ($LdDevCount -eq 0 -and $MuInstanceCount -eq 0) {
        Write-Host '[提示] 未发现任何 ADB 设备。可能原因：'
        Write-Host '  1. 模拟器未启动'
        Write-Host '  2. MuMu 需在设置中开启 ADB 调试（设备设置 → 开发者选项）'
        Write-Host '  3. MuMu 多开实例可能使用非标准端口（可在 MuMu 多开器中查看 ADB 端口）'
        Write-Host '  4. 自定义端口可设置环境变量 PCR_ABI_EXTRA_PORTS=端口号,端口号'
        Raise-ExitCode 1
    }
}


Write-Host '================================================================'
Write-Host '[汇总] 检测结果'
Write-Host "  MuMu 实例：$MuInstanceCount 个；雷电设备：$LdDevCount 个"
Write-Host "  MuMu 配置待修：$($MuPlan.Count) 项"
Write-Host "  MuMu 游戏 ABI 待修：$($script:MuAbiPlan.Count) 项"
Write-Host "  雷电游戏 ABI 待修：$($LdPlan.Count) 项"
Write-Host "  可切换 ABI（高级）：$($script:MuSwitchPlan.Count + $script:MuAbiSwitchPlan.Count + $LdSwitchPlan.Count) 项"
if ($MuNonRootCount -gt 0) { Write-Host "  注意：$MuNonRootCount 个 MuMu 实例未开启 Root，无法检测；请按上方说明开启 Root 后重跑。"; Raise-ExitCode 1 }
Write-Host '================================================================'
Show-QQTip

$totalPending = $MuPlan.Count + $script:MuAbiPlan.Count + $LdPlan.Count
$totalSwitch = $script:MuSwitchPlan.Count + $script:MuAbiSwitchPlan.Count + $LdSwitchPlan.Count
if ($totalPending -eq 0 -and $totalSwitch -eq 0) {
    Write-Host '[提示] 没有可修复或可切换的项目。'
    Finish
}

Write-Host '[菜单]'
$fixItems = New-Object System.Collections.Generic.List[object]
foreach ($it in $MuPlan) {
    $muName = $it.InstName
    if (-not $muName) { $muName = [string]$it.Vm }
    $configFile = [IO.Path]::GetFileName([string]$it.Path)
    $fixItems.Add(@{ Kind = 'mu-config'; Item = $it; Label = "$muName - $($it.PkgShow)（配置 $configFile：$($it.From) -> x86_64）" })
}
foreach ($it in $script:MuAbiPlan) {
    $muName = if ($it.InstName) { $it.InstName } else { [string]$it.Target }
    $fixItems.Add(@{ Kind = 'mu-abi'; Item = $it; Label = "$muName - $($it.Pkg)（游戏 ABI：$($it.CurAbi) -> x86_64 重装）" })
}
foreach ($it in $LdPlan) { $fixItems.Add(@{ Kind = 'ld-abi'; Item = $it; Label = "$($it.Name) - $($it.Pkg)（游戏 ABI：$($it.CurAbi) -> x86_64 重装）" }) }
if ($totalPending -gt 0) {
    Write-Host "  1 = 推荐修复全部卡顿（$totalPending 项）"
    Write-Host '    MuMu：修改配置 + ABI 重装到 x86_64'
    Write-Host '    雷电：ABI 重装到 x86_64'
} else {
    Write-Host '  （当前没有可推荐修复的项目；如需切换可使用高级菜单）' -ForegroundColor Green
}
if ($totalSwitch -gt 0) { Write-Host "  2 = 切换 ABI（高级，正常运行游戏则无需修改，$totalSwitch 项可选）" }
if ($fixItems.Count -gt 0) {
    Write-Host ''
    Write-Host '  只修指定项请输入编号（多个用逗号分隔，如 3,4）：'
    for ($i = 0; $i -lt $fixItems.Count; $i++) { Write-Host ("  {0} = {1}" -f ($i + 3), $fixItems[$i].Label) }
}
Write-Host ''
Write-Host '  0 = 退出（直接回车也可退出，不做任何修改）'
$confirm = Read-Host '请输入选项'
$modeSwitch = $false
if ($confirm -match '^(1|[Yy])$' -and $totalPending -gt 0) {
    $doMu = $MuPlan
    $doAbi = New-Object System.Collections.Generic.List[object]
    foreach ($item in $script:MuAbiPlan) { $doAbi.Add($item) }
    foreach ($item in $LdPlan) { $doAbi.Add($item) }
    $fromAbi = 'x86'; $toAbi = 'x86_64'
} elseif ($confirm -match '^(2|[Ss])$' -and $totalSwitch -gt 0) {
    $allSwitchItems = New-Object System.Collections.Generic.List[object]
    foreach ($it in $script:MuSwitchPlan) {
        $muName = if ($it.InstName) { $it.InstName } else { [string]$it.Vm }
        $muType = if ($it.Tag -eq 'MuMuPlayerGlobal') { 'MuMu Global' } elseif ($it.Backend -eq 'adb') { 'MuMu12' } else { 'MuMu' }
        $key = "mu|$($it.Backend)|$($it.Cli)|$($it.Vm)"
        $allSwitchItems.Add(@{ Kind = 'mu-config'; Item = $it; InstanceKey = $key; InstanceLabel = "$muName（$muType）" })
    }
    foreach ($it in $script:MuAbiSwitchPlan) {
        $muName = if ($it.InstName) { $it.InstName } else { [string]$it.Target }
        $muType = if ($it.Tag -eq 'MuMuPlayerGlobal') { 'MuMu Global' } elseif ($it.Backend -eq 'adb') { 'MuMu12' } else { 'MuMu' }
        $key = "mu|$($it.Backend)|$($it.Cli)|$($it.Vm)"
        $allSwitchItems.Add(@{ Kind = 'mu-abi'; Item = $it; InstanceKey = $key; InstanceLabel = "$muName（$muType）" })
    }
    foreach ($it in $LdSwitchPlan) {
        $key = "ld|$($it.Target)"
        $allSwitchItems.Add(@{ Kind = 'ld-abi'; Item = $it; InstanceKey = $key; InstanceLabel = "$($it.Name)（雷电）" })
    }

    $instanceGroups = New-Object System.Collections.Generic.List[object]
    $instanceByKey = @{}
    foreach ($switchItem in $allSwitchItems) {
        if (-not $instanceByKey.ContainsKey($switchItem.InstanceKey)) {
            $group = @{ Key = $switchItem.InstanceKey; Label = $switchItem.InstanceLabel; Items = (New-Object System.Collections.Generic.List[object]) }
            $instanceByKey[$switchItem.InstanceKey] = $group
            $instanceGroups.Add($group)
        }
        $instanceByKey[$switchItem.InstanceKey].Items.Add($switchItem)
    }

    Write-Host ''
    Write-Host '[切换 ABI] 选择模拟器实例：'
    for ($i = 0; $i -lt $instanceGroups.Count; $i++) { Write-Host ("  {0} = {1}" -f ($i + 1), $instanceGroups[$i].Label) }
    Write-Host ''
    Write-Host '  0 = 返回退出'
    $sel = Read-Host '请选择模拟器编号'
    $pickedGroup = $null
    if ($sel -match '^\s*\d+\s*$') {
        $n = 0
        if ([int]::TryParse($sel.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $instanceGroups.Count) { $pickedGroup = $instanceGroups[$n - 1] }
    }
    if (-not $pickedGroup) {
        Write-Host '[已取消] 未修改任何文件。'
        Finish
    }

    $switchItems = New-Object System.Collections.Generic.List[object]
    Write-Host ''
    Write-Host '[切换 ABI] 选择配置项或游戏 ABI：'
    $configItems = @($pickedGroup.Items | Where-Object { $_.Kind -eq 'mu-config' })
    if ($configItems.Count -gt 0) {
        Write-Host '  配置文件：'
        $lastPath = ''
        foreach ($entry in $configItems) {
            if ($entry.Item.Path -ne $lastPath) { Write-Host "    $($entry.Item.Path)"; $lastPath = $entry.Item.Path }
            $switchItems.Add($entry)
            Write-Host ("      {0} = {1}（当前：{2}）" -f $switchItems.Count, $entry.Item.PkgShow, $entry.Item.CurAbi)
        }
    }
    $gameItems = @($pickedGroup.Items | Where-Object { $_.Kind -ne 'mu-config' })
    if ($gameItems.Count -gt 0) {
        Write-Host '  游戏 ABI：'
        foreach ($entry in $gameItems) {
            $switchItems.Add($entry)
            Write-Host ("      {0} = {1}（当前：{2}）" -f $switchItems.Count, $entry.Item.Pkg, $entry.Item.CurAbi)
        }
    }
    Write-Host ''
    Write-Host '  0 = 返回退出'
    $selItem = Read-Host '请选择项目编号'
    $picked = $null
    if ($selItem -match '^\s*\d+\s*$') {
        $n = 0
        if ([int]::TryParse($selItem.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $switchItems.Count) { $picked = $switchItems[$n - 1] }
    }
    if (-not $picked) { Write-Host '[已取消] 未修改任何文件。'; Finish }
    $pickedItem = $picked.Item
    $curAbi = $pickedItem.CurAbi
    $pickedKind = $picked.Kind

    $allAbiChoices = @(
        @{ Name = 'x86_64';      Desc = '64位 Intel 原生库，无需 ARM 翻译，性能最佳' }
        @{ Name = 'arm64-v8a';   Desc = '64位 ARM 原生库，模拟器需 ARM 翻译' }
        @{ Name = 'armeabi-v7a'; Desc = '32位 ARM 原生库，模拟器需 ARM 翻译' }
    )
    $targetAbis = @(Get-AlternativeAbis $curAbi)
    $abiChoices = @($allAbiChoices | Where-Object { $targetAbis -contains $_.Name })
    $pickedAbi = $null
    while (-not $pickedAbi) {
        Write-Host ''
        Write-Host "[切换 ABI] 当前 ABI: $curAbi"
        for ($i = 0; $i -lt $abiChoices.Count; $i++) {
            Write-Host ("  [{0}] {1,-14} {2}" -f ($i + 1), $abiChoices[$i].Name, $abiChoices[$i].Desc)
        }
        $selAbi = Read-Host '请选择目标 ABI 编号（直接回车 = 取消）'
        if (-not $selAbi.Trim()) { Write-Host '[已取消] 未修改任何文件。'; Finish }
        if ($selAbi -match '^\s*\d+\s*$') {
            $n = 0
            if ([int]::TryParse($selAbi.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $abiChoices.Count) {
                $pickedAbi = $abiChoices[$n - 1].Name
            } else {
                Write-Host '  [提示] 编号无效，请重新选择。' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  [提示] 输入无效，请重新选择。' -ForegroundColor Yellow
        }
    }

    if ($pickedKind -ne 'mu-config') {
        $abiDir = switch ($pickedAbi) {
            'x86_64'       { 'lib/x86_64/' }
            'arm64-v8a'    { 'lib/arm64-v8a/' }
            'armeabi-v7a'  { 'lib/armeabi-v7a/' }
        }
        Write-Host ''
        Write-Host "[检查] APK 是否含 $pickedAbi 库..."
        $script:ShellBackend = $pickedItem.Backend
        $script:ShellTarget = $pickedItem.Target
        if ($pickedItem.Cli) { $script:MuMuCli = $pickedItem.Cli }
        $libOut = Invoke-RemoteShell "unzip -l '$($pickedItem.Apk)' | grep -c '$abiDir'"
        $libCnt = 0
        foreach ($l in $libOut) { $t = ([string]$l).Trim(); if ($t -match '^\d+$') { $libCnt = [int]$t } }
        if ($libCnt -eq 0) {
            Write-Host "  [异常] 未检测到 $pickedAbi 库；已知游戏应包含三套 ABI 库，本次已取消切换" -ForegroundColor Red
            Write-Host '  [提示] 请检查 APK 是否完整，以及 unzip/grep 检测命令是否可用'
            Finish
        }
        Write-Host "  [OK] 已检测到 $libCnt 个 $($pickedAbi)库文件"
    }

    $pickedLabel = if ($pickedKind -eq 'mu-config') {
        "MuMu($($pickedItem.Tag)) $($pickedItem.InstName) - $($pickedItem.PkgShow)（配置 $($pickedItem.Path)）"
    } elseif ($pickedKind -eq 'mu-abi') {
        "MuMu($($pickedItem.Tag)) $($pickedItem.InstName) - $($pickedItem.Pkg)（游戏 ABI）"
    } else {
        "$($pickedItem.Name)（$($pickedItem.Target)）- $($pickedItem.Pkg)（游戏 ABI）"
    }
    Write-Host ''
    Write-Host "[确认] 将把 $pickedLabel 从 $curAbi 切换到 $pickedAbi" -ForegroundColor Cyan
    Write-Host '  风险提示：' -ForegroundColor Yellow
    if ($pickedAbi -ne 'x86_64') {
        Write-Host "    · 游戏包含 x86_64、arm64-v8a、armeabi-v7a 三套原生库；切换到 $pickedAbi 后由模拟器 ARM 翻译层运行" -ForegroundColor Yellow
    } else {
        Write-Host '    · x86_64 为推荐配置，无需 ARM 翻译，性能最佳' -ForegroundColor Yellow
    }
    Write-Host "    · 切换后若运行或性能不符合预期，可再次运行本工具切回 $curAbi" -ForegroundColor Yellow
    if ($pickedKind -eq 'mu-config') {
        Write-Host '    · MuMu 修改配置文件，需手动重启模拟器后生效' -ForegroundColor Yellow
    } elseif ($pickedKind -eq 'mu-abi') {
        Write-Host '    · MuMu 将立即重装 APK（pm install -r --abi）' -ForegroundColor Yellow
    } else {
        Write-Host '    · 雷电将立即重装 APK（pm install -r --abi），无需重启模拟器' -ForegroundColor Yellow
    }
    $finalConfirm = Read-Host '确认执行？(Y/N)'
    if ($finalConfirm -notmatch '^[Yy]') {
        Write-Host '[已取消] 未修改任何文件。'
        Finish
    }

    $modeSwitch = $true
    $doMu = New-Object System.Collections.Generic.List[object]
    $doAbi = New-Object System.Collections.Generic.List[object]
    if ($pickedKind -eq 'mu-config') {
        $doMu.Add(@{ Backend = $pickedItem.Backend; Vm = $pickedItem.Vm; Path = $pickedItem.Path; Cli = $pickedItem.Cli; Tag = $pickedItem.Tag; PkgShow = $pickedItem.PkgShow; From = $curAbi; Line = $pickedItem.Line; InstName = $pickedItem.InstName })
    } else {
        $doAbi.Add($pickedItem)
    }
    $fromAbi = $curAbi; $toAbi = $pickedAbi
} elseif (-not $confirm.Trim() -or $confirm -match '^\s*0\s*$') {
    Write-Host '[已取消] 未修改任何文件（本次仅为状态查询）。'
    Finish
} elseif ($confirm -match '^\s*\d+(\s*,\s*\d+)*\s*$' -and $fixItems.Count -gt 0) {
    $doMu = New-Object System.Collections.Generic.List[object]
    $doAbi = New-Object System.Collections.Generic.List[object]
    $pickedFix = 0
    foreach ($nStr in ($confirm -split ',')) {
        $n = 0
        if ([int]::TryParse($nStr.Trim(), [ref]$n) -and $n -ge 3 -and $n -le ($fixItems.Count + 2)) {
            $fi = $fixItems[$n - 3]
            if ($fi.Kind -eq 'mu-config') { $doMu.Add($fi.Item) } else { $doAbi.Add($fi.Item) }
            $pickedFix++
        }
    }
    if ($pickedFix -eq 0) {
        Write-Host '[已取消] 没有选中任何有效编号，未修改任何文件。'
        Finish
    }
    $fromAbi = 'x86'; $toAbi = 'x86_64'
    Write-Host ("[修复] 将只修复选中的 {0} 项。" -f $pickedFix)
} else {
    Write-Host '[已取消] 未修改任何文件（本次仅为状态查询）。'
    Finish
}


$SuccessCount = 0; $FailedCount = 0; $RolledBackCount = 0; $CriticalCount = 0


$TxnTemplate = @'
PCR_ABI_TRANSACTION=1; FILE='__FILE__'; BACKUP_DIR='__BACKUP_DIR__'; BACKUP='__BACKUP__'; TMP='__TMP__'; CAND='__CAND__'; REV='__REV__'; ROLL='__ROLL__'; PK='__PK_VAL__'; FROM='__FROM_VAL__'; TO='__TO_VAL__'; cleanup() { rm -f $TMP $CAND $REV $ROLL $BASE; }; fail() { echo RESULT=$1; cleanup; exit 20; }; rollback() { OWNER=$(echo $ORIG_META | cut -d: -f1); GROUP=$(echo $ORIG_META | cut -d: -f2); MODE=$(echo $ORIG_META | cut -d: -f3); cp -p $BACKUP $ROLL || { echo RESULT=ROLLBACK_FAILED; cleanup; exit 33; }; chown $OWNER:$GROUP $ROLL || { echo RESULT=ROLLBACK_FAILED; cleanup; exit 33; }; chmod $MODE $ROLL || { echo RESULT=ROLLBACK_FAILED; cleanup; exit 33; }; chcon $ORIG_CTX $ROLL || { echo RESULT=ROLLBACK_FAILED; cleanup; exit 33; }; mv -f $ROLL $FILE || { echo RESULT=ROLLBACK_FAILED; cleanup; exit 33; }; sync; RB_HASH=$(sha256sum $FILE | cut -d ' ' -f 1); RB_META=$(stat -c $FMT $FILE); RB_CTX=$(ls -Z $FILE | awk '{print $1}'); if [ $RB_HASH = $ORIG_HASH ] && [ $RB_META = $ORIG_META ] && [ $RB_CTX = $ORIG_CTX ]; then echo RESULT=ROLLED_BACK; cleanup; exit 22; else echo RESULT=ROLLBACK_FAILED; cleanup; exit 33; fi; }; post_fail() { echo POST_VERIFY=$1; rollback; }; FMT=$(printf '\045u:\045g:\045a'); ORIG_HASH=$(sha256sum $FILE | cut -d ' ' -f 1) || fail HASH_READ_FAILED; ORIG_META=$(stat -c $FMT $FILE) || fail META_READ_FAILED; ORIG_CTX=$(ls -Z $FILE | awk '{print $1}') || fail CONTEXT_READ_FAILED; ATTR=$(lsattr $FILE | awk '{print $1}') || fail ATTR_READ_FAILED; case $ATTR in *i*) fail IMMUTABLE ;; esac; case $FILE in /system/*) grep ' /system ' /proc/mounts | grep -q ' rw,' || fail SYSTEM_READ_ONLY ;; esac; mkdir -p $BACKUP_DIR || fail BACKUP_DIR_FAILED; cp -p $FILE $BACKUP || fail BACKUP_FAILED; BACKUP_HASH=$(sha256sum $BACKUP | cut -d ' ' -f 1); [ $BACKUP_HASH = $ORIG_HASH ] || fail BACKUP_VERIFY_FAILED; echo BACKUP=$BACKUP; cp -p $FILE $TMP || fail TEMP_COPY_FAILED; BASE=$BACKUP.norm; awk '{print}' $FILE > $BASE || fail NORM_FAILED; LN=__LN__; L=$(awk -v n=$LN 'NR==n' $FILE); case "$L" in *"$PK"*) ;; *) fail LINE_PKG_MISMATCH ;; esac; case "$L" in *"$FROM"*) ;; *) fail ABI_TOKEN_MISSING ;; esac; case "$L" in *"$TO"*) fail ALREADY_TARGET ;; esac; awk -v n=$LN -v r="$TO" 'NR==n{sub(/__FROM__/,r)} {print}' $FILE > $CAND || fail TRANSFORM_FAILED; awk -v n=$LN -v r="$FROM" 'NR==n{sub(/__TO__/,r)} {print}' $CAND > $REV || fail REVERSE_FAILED; cmp -s $BASE $REV || { echo FSIZE=$(wc -c < $FILE); echo BSIZE=$(wc -c < $BASE); echo RSIZE=$(wc -c < $REV); fail UNEXPECTED_DIFF; }; cmp -s $BASE $CAND && fail NO_CHANGE; CAND_HASH=$(sha256sum $CAND | cut -d ' ' -f 1) || fail CANDIDATE_HASH_FAILED; cat $CAND > $TMP || fail TEMP_WRITE_FAILED; TMP_META=$(stat -c $FMT $TMP) || fail TEMP_META_FAILED; TMP_CTX=$(ls -Z $TMP | awk '{print $1}') || fail TEMP_CONTEXT_FAILED; [ $TMP_META = $ORIG_META ] || fail TEMP_META_MISMATCH; [ $TMP_CTX = $ORIG_CTX ] || fail TEMP_CONTEXT_MISMATCH; mv -f $TMP $FILE || fail REPLACE_FAILED; sync; NEW_HASH=$(sha256sum $FILE | cut -d ' ' -f 1) || post_fail FINAL_HASH_FAILED; NEW_META=$(stat -c $FMT $FILE) || post_fail FINAL_META_FAILED; NEW_CTX=$(ls -Z $FILE | awk '{print $1}') || post_fail FINAL_CONTEXT_FAILED; [ $NEW_HASH = $CAND_HASH ] || post_fail FINAL_HASH_MISMATCH; [ $NEW_META = $ORIG_META ] || post_fail FINAL_META_MISMATCH; [ $NEW_CTX = $ORIG_CTX ] || post_fail FINAL_CONTEXT_MISMATCH; FV=$(awk -v n=$LN 'NR==n' $FILE); case "$FV" in *"$PK"*) ;; *) post_fail FINAL_PKG_MISMATCH ;; esac; case "$FV" in *"$TO"*) ;; *) post_fail FINAL_ABI_FAILED ;; esac; cleanup; echo RESULT=SUCCESS; exit 0
'@

if ($doMu.Count -gt 0) {
    Write-Host ''
    Write-Host '---------------- MuMu 修复/还原 ----------------'
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $txnIndex = 0
    foreach ($item in $doMu) {
        $txnIndex++
        $vm = $item.Vm; $file = $item.Path
        $dispName = if ($item.InstName) { $item.InstName } else { "VM $vm" }
        $script:ShellBackend = $item.Backend
        $script:ShellTarget = $vm
        if ($item.Cli) { $script:MuMuCli = $item.Cli }
        $backupDir = "/data/local/tmp/pcr-abi-backup-$runId"
        Write-Host "[备份] $dispName - $file"
        $cmd = $TxnTemplate.Trim()
        $fa = $fromAbi; $ta = $toAbi
        if ($item.From) { $fa = $item.From }
        $pkVal = $item.PkgShow -replace '\.', '\.'
        $cmd = $cmd.Replace('__FROM_VAL__', $fa).Replace('__TO_VAL__', $ta).Replace('__PK_VAL__', $pkVal)
        $cmd = $cmd.Replace('__FROM__', $fa).Replace('__TO__', $ta).Replace('__LN__', [string]$item.Line)
        $cmd = $cmd.Replace('__FILE__', $file).Replace('__BACKUP_DIR__', $backupDir)
        $cmd = $cmd.Replace('__BACKUP__', "$backupDir/file-$txnIndex.bak").Replace('__TMP__', "$file.pcrabi-$runId-$txnIndex.tmp")
        $cmd = $cmd.Replace('__CAND__', "/data/local/tmp/pcrabi-candidate-$runId-$txnIndex").Replace('__REV__', "/data/local/tmp/pcrabi-reverse-$runId-$txnIndex")
        $cmd = $cmd.Replace('__ROLL__', "$file.pcrabi-$runId-$txnIndex.rollback")
        $out = Invoke-RemoteShell $cmd 120000
        $txnExit = $script:ToolExit
        $out | ForEach-Object { Write-Host $_ }
        $joined = $out -join "`n"
        if ($joined -match '(?m)^RESULT=SUCCESS' -and $txnExit -eq 0) {
            Write-Host "[成功] $dispName - $file"; $SuccessCount++
        } elseif ($joined -match '(?m)^RESULT=ROLLED_BACK') {
            Write-Host "[已回滚] $dispName - $file"; $FailedCount++; $RolledBackCount++; Raise-ExitCode 2
        } elseif ($joined -match '(?m)^RESULT=ROLLBACK_FAILED') {
            Write-Host "[严重] 回滚失败 - $dispName - $file"; $FailedCount++; $CriticalCount++; Raise-ExitCode 3
        } elseif ($txnExit -eq -1) {
            Write-Host "[超时] $dispName - 事务超过 120s 未完成，正在检查远程文件状态..." -ForegroundColor Yellow
            $checkOut = Invoke-RemoteShell "sed -n '$($item.Line)p' '$file' 2>/dev/null || echo CHECK_FAILED" 15000
            $checkTxt = ($checkOut -join ' ').Trim()
            if ($checkTxt -and $checkTxt -ne 'CHECK_FAILED' -and $checkTxt -match $toAbi) {
                Write-Host "  [警告] 超时但配置行已是 $toAbi，可能已写入但未完成校验。建议人工复核。" -ForegroundColor Yellow
                Write-Host "  [需人工复核] $dispName - $file（超时但目标 ABI 已生效）"; $FailedCount++; Raise-ExitCode 2
            } elseif ($checkTxt -eq 'CHECK_FAILED') {
                Write-Host "  [严重] 超时且无法读取远程文件状态，可能处于部分写入状态" -ForegroundColor Red
                Write-Host "  [需人工复核] $dispName - $file（状态未知，请检查备份目录 $backupDir）"; $FailedCount++; $CriticalCount++; Raise-ExitCode 3
            } else {
                $curAbiTxt = if ($checkTxt -match '(x86_64|arm64-v8a|armeabi-v7a|x86)') { $Matches[1] } else { '未知' }
                Write-Host "  [需人工复核] $dispName - $file（超时，配置行='$curAbiTxt'，期望='$toAbi'）" -ForegroundColor Yellow
                Write-Host "  备份目录: $backupDir（如需回滚请手动恢复）" -ForegroundColor Yellow
                $FailedCount++; Raise-ExitCode 2
            }
        } else {
            Write-Host "[失败] $dispName - $file"; $FailedCount++; Raise-ExitCode 2
        }
    }
}

if ($doAbi.Count -gt 0) {
    Write-Host ''
    Write-Host '---------------- 游戏 ABI 重装 ----------------'
    foreach ($item in $doAbi) {
        $targetName = if ($item.InstName) { $item.InstName } elseif ($item.Name) { $item.Name } else { [string]$item.Target }
        Write-Host "[安装] $targetName（$($item.Target)）- $($item.Pkg)"
        Write-Host "  pm install -r --abi $toAbi ..."
        $result = Invoke-AbiReinstall $item $toAbi
        if ($result.Success) {
            Write-Host "  [成功] primaryCpuAbi=$($result.ActualAbi)"
            $SuccessCount++
            continue
        }
        if ($result.Reason -eq 'install') {
            Write-Host '  [失败] 安装未返回 Success：'
        } else {
            Write-Host "  [失败] 安装成功但 primaryCpuAbi 实际='$($result.ActualAbi)'（期望 '$toAbi'）："
        }
        $result.Output | ForEach-Object { Write-Host "  $_" }
        $FailedCount++; Raise-ExitCode 2
    }
}


if ($doMu.Count -gt 0) {
    Write-Host ''
    Write-Host '[验证] 修复后 ABI 状态：'
    foreach ($item in $doMu) {
        $script:ShellBackend = $item.Backend
        $script:ShellTarget = $item.Vm
        if ($item.Cli) { $script:MuMuCli = $item.Cli }
        $lineContent = (Invoke-RemoteShell "sed -n '$($item.Line)p' '$($item.Path)'" | Select-Object -First 1)
        $lineText = [string]$lineContent
        $curAbi = '未匹配'
        if ($lineText -match '\s+(x86_64|arm64-v8a|armeabi-v7a|x86)\s') { $curAbi = $Matches[1] }
        elseif ($lineText -match '\s+(x86_64|arm64-v8a|armeabi-v7a|x86)$') { $curAbi = $Matches[1] }
        $muDisp = if ($item.InstName) { $item.InstName } else { "VM $($item.Vm)" }
        if ($curAbi -eq $toAbi) {
            Write-Host "  [OK] MuMu($($item.Tag)) $muDisp - $($item.PkgShow): 配置行=$toAbi（需重启模拟器生效）"
        } else {
            Write-Host "  [FAIL] MuMu($($item.Tag)) $muDisp - $($item.PkgShow): 配置行=$curAbi（期望 $toAbi）" -ForegroundColor Red
            $FailedCount++; Raise-ExitCode 2
        }
    }
}

Write-Host ''
Write-Host '================================================================'
Write-Host "[汇总] 成功：$SuccessCount  失败：$FailedCount  已回滚：$RolledBackCount  严重错误：$CriticalCount"
if ($doMu.Count -gt 0) { Write-Host '[提示] MuMu 修改成功的实例需要手动重启 MuMu 后生效。' }
if ($modeSwitch) { Write-Host "[提示] 如切换后运行或性能不符合预期，可再次运行本工具切回 $fromAbi。" -ForegroundColor Yellow }
Write-Host '================================================================'
Finish

} catch {
    Log "[严重错误] 未捕获异常：$($_.Exception.Message)"
    Log "位置：$($_.InvocationInfo.PositionMessage)"
    Log "请截图此窗口或回传日志文件：$script:LogFile"
    Raise-ExitCode 3
    Show-QQTip
    Finish
}
