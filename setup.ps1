<#
.SYNOPSIS
    dsh-trash-kit 总装脚本：把「删除拦截 + 回收站」体系一次装好（幂等，可反复跑）。

.DESCRIPTION
    安装模式（默认）：
      1. 校验套装完整性（files\ 下的文件齐不齐；并检查根目录的 4 份文档在不在）
      2. 铺 ~\.dsh\tools\：trash / doctor / 离线救援 / 插件源码 / 模板；再把套装根目录的
         SPEC.md、操作手册.md、HANDOFF.md、README.md 也铺一份过去（方便任意会话直接读）；
         逐个报告 [新增] [更新] [不变]，被覆盖的旧文件先备份到 ~\.dsh\tools\backup\setup-<时间>\
      3. 逐 profile 装拦截插件（缺省自动探测 ~\.dsh\profiles 下的全部 profile）
      4. 全局规则 ~\.dsh\AGENTS.md：不存在才写；已存在则体检关键内容（唯一通道 / 插件 /
         两道闸门 / 习惯层 四样都得有），-ForceRules 才重建
      5. 计划任务 dsh-trash-guard-doctor：不存在则建；存在则修正三项可靠性设置（-NoTask 跳过）
      6. 跑 doctor.ps1 全量体检，并打印验收清单（含两条行为探针与离线救援自检）

    导出模式（-Export）：反向把当前机器上已部署的状态刷进套装（files\ + kit-manifest.json），
    所以套装永远可以等于"现在这套已经验证过的状态"，不会与脚本漂移。

.PARAMETER ProfileName
    只处理指定 profile（可多个，逗号分隔）。缺省自动探测 ~\.dsh\profiles 下全部。

.PARAMETER HostDir
    宿主程序目录（只用于版本指纹）。缺省自动探测。

.PARAMETER DryRun
    只报告将要做什么，不改任何东西。

.PARAMETER NoTask
    不创建、不修改计划任务。

.PARAMETER ForceRules
    允许覆盖已存在的 ~\.dsh\AGENTS.md（覆盖前备份）。

.PARAMETER Export
    反向模式：从本机已部署状态刷新套装。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -DryRun
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Export
#>
param(
    [string[]] $ProfileName = @(),
    [string] $HostDir = '',
    [switch] $DryRun,
    [switch] $NoTask,
    [switch] $ForceRules,
    [switch] $Export
)

$ErrorActionPreference = 'Stop'
$KitRoot = $PSScriptRoot
$FilesDir = Join-Path $KitRoot 'files'
$ManifestPath = Join-Path $KitRoot 'kit-manifest.json'
$Dsh = Join-Path $env:USERPROFILE '.dsh'
$Tools = Join-Path $Dsh 'tools'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$TaskName = 'dsh-trash-guard-doctor'
$script:issues = New-Object System.Collections.ArrayList

function Say([string] $Text) { Write-Output $Text }
function Step([string] $Text) { Write-Output ''; Write-Output ('== ' + $Text) }
function Warn([string] $Text) { Write-Output ('  [注意] ' + $Text); [void]$script:issues.Add($Text) }
function Fail([string] $Text) { Write-Output ('  [异常] ' + $Text); [void]$script:issues.Add($Text) }

# 套装要铺开的文件（相对路径）。运行产物（backup\、doctor.log、doctor-report-*、guard-status.txt）不在其中。
$Layout = @(
    'trash.ps1',
    'trash.cmd',
    'doctor.ps1',
    'doctor.cmd',
    'offline-restore.ps1',
    'offline-restore.cmd',
    'dsh-trash-guard\package.json',
    'dsh-trash-guard\lib\index.js',
    'dsh-trash-guard\README.md',
    'dsh-trash-guard\install.ps1',
    'dsh-trash-guard\install-snippet.yml',
    'dsh-trash-guard\staging\global-AGENTS.md',
    'dsh-trash-guard\staging\web-cordis.patch.yml',
    'dsh-trash-guard\staging\check-yaml.cjs',
    'dsh-trash-guard\staging\README.md',
    'templates\AGENTS.workspace.md',
    'templates\apply-workspace-rules.ps1',
    'templates\README.md'
)

function Get-HostInfo([string] $Dir) {
    $info = [ordered]@{ dir = $Dir; version = ''; channel = ''; asarBytes = 0; asarMtime = '' }
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $info }
    $exe = Get-ChildItem -File -LiteralPath $Dir -Filter '*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^Uninstall' } | Select-Object -First 1
    if ($exe) { $info.version = [string]$exe.VersionInfo.FileVersion }
    $yml = Join-Path $Dir 'resources\app-update.yml'
    if (Test-Path -LiteralPath $yml) {
        foreach ($line in (Get-Content -LiteralPath $yml -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*channel:\s*(\S+)') { $info.channel = $Matches[1] }
        }
    }
    $asar = Join-Path $Dir 'resources\app.asar'
    if (Test-Path -LiteralPath $asar) {
        $f = Get-Item -LiteralPath $asar
        $info.asarBytes = $f.Length
        $info.asarMtime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
    return $info
}

function Find-HostDir() {
    $cands = New-Object System.Collections.ArrayList
    if ($env:DSH_HOST_DIR) { [void]$cands.Add($env:DSH_HOST_DIR) }
    if ($HostDir) { [void]$cands.Add($HostDir) }
    if ($env:LOCALAPPDATA) { [void]$cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')) }
    if (${env:ProgramFiles}) { [void]$cands.Add((Join-Path ${env:ProgramFiles} 'DeepSeek Harness')) }
    if (${env:ProgramFiles(x86)}) { [void]$cands.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'resources\app.asar'))) { return $c }
    }
    return ''
}

function Backup-File([string] $Path, [string] $BackupDir) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $rel = $Path.Substring($Tools.Length).TrimStart('\')
    $dst = Join-Path $BackupDir $rel
    $parent = Split-Path -Parent $dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $Path -Destination $dst -Force
}

function Invoke-Quiet([string] $CommandLine) {
    # 用 cmd 执行并把 stdout/stderr 都吞掉，只回传退出码。
    # 为什么不用 "$out = schtasks ... 2>&1"：$ErrorActionPreference='Stop' 时 PowerShell 会把
    # 原生命令的 stderr 包装成终止错误（NativeCommandError），"任务不存在"这种正常情况会直接中断脚本。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        cmd /c ($CommandLine + ' >nul 2>nul')
        return [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-ChildScript([string] $Path, [string[]] $ScriptArgs = @()) {
    # 安全地跑子 PowerShell 脚本：stderr 合并进捕获流（避免它变成终止错误），
    # 输出**随对象返回**而不是直接吐进管道——否则调用方拿到的"退出码"会变成一整串报告文本。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $ScriptArgs
        $lines = @(& powershell @argv 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ code = [int]$LASTEXITCODE; lines = $lines }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-CmdCapture([string] $CommandLine) {
    # 跑一条 cmd 命令并把 stdout+stderr 都抓回来（用于排错时能看到真实报错）。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(cmd /c ($CommandLine + ' 2>&1') | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ code = [int]$LASTEXITCODE; lines = $lines }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-TaskExists([string] $Name) {
    return ((Invoke-Quiet ('schtasks /Query /TN "' + $Name + '"')) -eq 0)
}

# ================================================================ 导出模式
if ($Export) {
    Write-Output '== 导出模式：把本机已部署的状态刷进套装'
    $copied = 0
    $skipped = New-Object System.Collections.ArrayList
    foreach ($rel in $Layout) {
        $src = Join-Path $Tools $rel
        if (-not (Test-Path -LiteralPath $src)) { [void]$skipped.Add($rel); continue }
        $dst = Join-Path $FilesDir $rel
        $parent = Split-Path -Parent $dst
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copied++
        Write-Output ('  ' + $rel)
    }
    if ($skipped.Count -gt 0) { Write-Output ('  [跳过] 本机没有：' + ($skipped -join ', ')) }

    $items = New-Object System.Collections.ArrayList
    foreach ($rel in $Layout) {
        $f = Join-Path $FilesDir $rel
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $item = [ordered]@{
            path   = $rel
            bytes  = (Get-Item -LiteralPath $f).Length
            sha256 = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        }
        [void]$items.Add($item)
    }
    $hostInfo = Get-HostInfo (Find-HostDir)
    # 写进清单的宿主信息做脱敏：只留版本/构建指纹，不写本机安装路径与机器名。
    $hostForManifest = [ordered]@{
        version   = $hostInfo.version
        channel   = $hostInfo.channel
        asarBytes = $hostInfo.asarBytes
        asarMtime = $hostInfo.asarMtime
    }
    $manifest = [ordered]@{
        kit         = 'dsh-trash-kit'
        generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        host        = $hostForManifest
        note        = 'setup.ps1 按本清单铺开 files\ 下的内容；随时可用 setup.ps1 -Export 重新生成，使套装等于当前已验证状态。'
        files       = $items
    }
    [System.IO.File]::WriteAllText($ManifestPath, (($manifest | ConvertTo-Json -Depth 6) + "`r`n"), $Utf8NoBom)
    Write-Output ''
    Write-Output ('已刷新 {0} 个文件；清单：{1}' -f $copied, $ManifestPath)
    Write-Output ('宿主指纹：{0} {1}（channel {2}）' -f $hostInfo.dir, $hostInfo.version, $hostInfo.channel)

    # 生成/刷新双击入口 setup.cmd。
    # 为什么是 .cmd 而不是让人双击 .ps1：资源管理器双击 .ps1 只会用记事本打开它。
    # 编码：GBK(936) + 开头 chcp 936 —— cmd.exe 按控制台代码页读批处理，这样中文才稳；
    # 绝不能带 BOM（cmd 会把 BOM 当成第一行内容，@echo off 会失效）。
    # 无参数 -> 中文菜单（每项下面带说明）；带参数 -> 直接透传给 setup.ps1。
    $cmdText = @'
@echo off
chcp 936 >nul
rem ============================================================
rem  dsh-trash-kit —— 删除拦截 + 回收站 套装（双击入口，不需要管理员）
rem
rem  本文件由 setup.ps1 -Export 自动生成：GBK 编码 + 开头 chcp 936，
rem  这样在中文 Windows 上双击就能正常显示中文。改完模板记得跑一次 -Export。
rem
rem  无参数 = 显示下面的菜单；带参数 = 直接透传给 setup.ps1，例如：
rem    setup.cmd -DryRun        只预演，不改任何东西
rem    setup.cmd -Export        把当前状态导出回套装
rem    setup.cmd -NoTask        跳过计划任务那一步
rem    setup.cmd -ForceRules    允许覆盖已存在的全局规则文件
rem    setup.cmd -ProfileName desktop,web
rem ============================================================
setlocal
title dsh-trash-kit 删除拦截 + 回收站
cd /d "%~dp0"

if not "%~1"=="" goto run

:menu
cls
echo ============================================================
echo   dsh-trash-kit   删除拦截 + 回收站 套装
echo ============================================================
echo.
echo   [1] 安装 / 修复（默认）
echo       把工具铺到 %USERPROFILE%\.dsh\tools，逐个 profile 装拦截插件，
echo       检查全局规则和每月体检的计划任务，最后跑一次完整体检。
echo       已存在的文件会先备份到 tools\backup\setup-^<时间^>\ 再覆盖。
echo.
echo   [2] 预演：只报告，不改任何东西
echo       想先看看会动哪些文件、会跳过什么，就选这个（等于 setup.ps1 -DryRun）。
echo.
echo   [3] 把当前状态导出回套装（改过 tools 之后记得跑）
echo       反向同步：把本机已部署的 tools 文件刷进本目录 files\，
echo       并刷新 kit-manifest.json（哈希清单）和本入口文件。
echo.
echo   [4] 只做体检（doctor）
echo       检查脚本 / 插件 / 心跳 / 全局规则 / 各工作区账本 / 闸门告警日志；
echo       有问题会给出修复命令，结论「正常」即可。
echo.
echo   [0] 退出
echo.
set "ARGS="
set "CH=1"
set /p "CH=请选择 [1]: "
if "%CH%"=="" set "CH=1"
rem [1] 安装 / 修复：不带参数执行 setup.ps1
if "%CH%"=="1" goto run
rem [2] 预演：透传 -DryRun，什么都不改
if "%CH%"=="2" set "ARGS=-DryRun" & goto run
rem [3] 导出：透传 -Export，把本机现状刷回套装
if "%CH%"=="3" set "ARGS=-Export" & goto run
rem [4] 只体检：直接调用 tools 里的 doctor.ps1，不跑安装
if "%CH%"=="4" goto doctor
rem [0] 退出：什么都不做
if "%CH%"=="0" exit /b 0
echo 输入无效："%CH%"（请输入 0 到 4 之间的数字）
goto menu

:doctor
echo.
rem 只跑体检，不安装任何东西；退出码 0=正常，1=有异常
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.dsh\tools\doctor.ps1"
set "RC=%ERRORLEVEL%"
goto done

:run
echo.
rem 带参数就原样透传；否则用菜单里选好的 ARGS
if defined ARGS (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %ARGS%) else (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*)
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" goto ok
echo [!] 没有全部成功：退出码 %RC%（请看上面的报告）
echo     常见原因：在受限环境里跑（写不了 ~\.dsh、查不了计划任务）——请在普通 PowerShell 里重跑。
goto done

:ok
echo [OK] 全部完成。
goto done

:done
echo.
echo 按任意键关闭本窗口...
pause >nul
exit /b %RC%
'@
    $cmdBody = $cmdText.Trim("`r", "`n") -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $KitRoot 'setup.cmd'), ($cmdBody + "`r`n"), [System.Text.Encoding]::GetEncoding(936))
    Write-Output '  [写出] setup.cmd（中文菜单，GBK 编码 + chcp 936，不带 BOM）'
    exit 0
}

# ================================================================ 安装模式
Write-Output ('== dsh-trash-kit 总装   ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Write-Output ('   套装目录：' + $KitRoot)
Write-Output ('   目标家目录：' + $Dsh)
if ($DryRun) { Write-Output '   模式：DryRun（只报告，不改动）' }

Step '1 校验套装完整性'
$missing = New-Object System.Collections.ArrayList
foreach ($rel in $Layout) {
    if (-not (Test-Path -LiteralPath (Join-Path $FilesDir $rel))) { [void]$missing.Add($rel) }
}
if ($missing.Count -gt 0) {
    Fail ('套装不完整，缺少：' + ($missing -join ', '))
    Write-Output '  修法：在已装好的机器上跑 setup.ps1 -Export 重新生成套装。'
    exit 1
}
Write-Output ('  [OK] ' + $Layout.Count + ' 个文件齐备')
# 说明类文档放在套装根目录（不进 files\ 清单）：装机时也铺一份到 tools，方便会话里直接读。
$DocNames = @('SPEC.md', '操作手册.md', 'HANDOFF.md', 'README.md')
$docsMissing = @($DocNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $KitRoot $_)) })
if ($docsMissing.Count -gt 0) { Warn ('套装缺文档：' + ($docsMissing -join '、') + '（不影响安装，但会少一份说明）') }
else { Write-Output ('  [OK] ' + $DocNames.Count + ' 份文档齐备（装机时铺到 ~\.dsh\tools）') }
if (Test-Path -LiteralPath $ManifestPath) {
    try {
        $m = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        Write-Output ('  [OK] 清单：生成于 {0}，宿主 {1}' -f $m.generatedAt, $m.host.version)
    } catch { Warn ('kit-manifest.json 解析失败：' + $_.Exception.Message) }
} else { Warn '没有 kit-manifest.json（可能是手工拷来的）' }

Step '2 铺 ~\.dsh\tools'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $Tools ('backup\setup-' + $stamp)
$added = 0; $updated = 0; $same = 0
foreach ($rel in $Layout) {
    $src = Join-Path $FilesDir $rel
    $dst = Join-Path $Tools $rel
    if ($DryRun) { Write-Output ('  [DryRun] ' + $rel); continue }
    $parent = Split-Path -Parent $dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $dst) {
        $h1 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $h2 = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        if ($h1 -eq $h2) { $same++; continue }
        Backup-File $dst $backupDir
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Output ('  [更新] ' + $rel)
        $updated++
    } else {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Output ('  [新增] ' + $rel)
        $added++
    }
}
# 文档：从套装根目录铺到 ~\.dsh\tools（这样任意会话都能读 SPEC / 操作手册 / HANDOFF）
$docAdded = 0; $docUpdated = 0; $docSame = 0
foreach ($docName in $DocNames) {
    $srcDoc = Join-Path $KitRoot $docName
    if (-not (Test-Path -LiteralPath $srcDoc)) { continue }
    $dstDoc = Join-Path $Tools $docName
    if ($DryRun) { Write-Output ('  [DryRun] ' + $docName); continue }
    if (Test-Path -LiteralPath $dstDoc) {
        if ((Get-FileHash -LiteralPath $srcDoc -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $dstDoc -Algorithm SHA256).Hash) { $docSame++; continue }
        Backup-File $dstDoc $backupDir
        Copy-Item -LiteralPath $srcDoc -Destination $dstDoc -Force
        Write-Output ('  [更新] ' + $docName)
        $docUpdated++
    } else {
        Copy-Item -LiteralPath $srcDoc -Destination $dstDoc -Force
        Write-Output ('  [新增] ' + $docName)
        $docAdded++
    }
}
if (-not $DryRun) {
    Write-Output ('  小结：新增 {0} / 更新 {1} / 不变 {2}' -f $added, $updated, $same)
    Write-Output ('  文档：新增 {0} / 更新 {1} / 不变 {2}' -f $docAdded, $docUpdated, $docSame)
    if (($updated + $docUpdated) -gt 0) { Write-Output ('  被覆盖的旧文件备份在：' + $backupDir) }
}

Step '3 逐 profile 装拦截插件'
$profiles = @()
if ($ProfileName.Count -gt 0) { $profiles = $ProfileName }
else {
    $pdir = Join-Path $Dsh 'profiles'
    if (Test-Path -LiteralPath $pdir) {
        $profiles = @(Get-ChildItem -Directory -LiteralPath $pdir | Sort-Object Name | ForEach-Object { $_.Name })
    }
}
if ($profiles.Count -eq 0) {
    Warn '没发现任何 profile（DSH 还没启动过？）—— 启动一次后重跑本脚本，或加 -ProfileName'
} else {
    foreach ($p in $profiles) {
        $pd = Join-Path $Dsh ('profiles\' + $p)
        if (-not (Test-Path -LiteralPath $pd)) { Write-Output ('  [跳过] profile 不存在：' + $p); continue }
        if ($DryRun) { Write-Output ('  [DryRun] 装插件到 ' + $p); continue }
        $r = Invoke-ChildScript (Join-Path $Tools 'dsh-trash-guard\install.ps1') @('-ProfileName', $p)
        foreach ($line in $r.lines) { Write-Output ('  ' + $line) }
        if ($r.code -ne 0) { Fail ('装插件到 ' + $p + ' 失败（install.ps1 退出码 ' + $r.code + '）') }
    }
}

Step '4 全局规则 ~\.dsh\AGENTS.md'
$g = Join-Path $Dsh 'AGENTS.md'
$rulesSrc = Join-Path $Tools 'dsh-trash-guard\staging\global-AGENTS.md'
if ($DryRun) { Write-Output '  [DryRun] 检查/写入全局规则' }
elseif (-not (Test-Path -LiteralPath $g)) {
    Copy-Item -LiteralPath $rulesSrc -Destination $g -Force
    Write-Output '  [新增] 已写入全局规则'
} elseif ($ForceRules) {
    Backup-File $g $backupDir
    Copy-Item -LiteralPath $rulesSrc -Destination $g -Force
    Write-Output '  [覆盖] 已重建全局规则（旧版已备份）'
} else {
    $txt = [System.IO.File]::ReadAllText($g, [System.Text.Encoding]::UTF8)
    $hasTrash = ($txt -match 'trash\.ps1')
    $hasGuard = ($txt -match 'dsh-trash-guard')
    # 2026-10-25 起全局规则多了两块：两道闸门（受保护路径 / 确认码）与"习惯层"。
    # 只检查前两项的话，规则是旧版也看不出来。
    $hasGate = ($txt -match '受保护路径|AllowOutsideRoot|ConfirmCode')
    $hasHabit = ($txt -match '习惯层')
    if ($hasTrash -and $hasGuard -and $hasGate -and $hasHabit) { Write-Output '  [不变] 已存在且关键内容齐（要重建：-ForceRules）' }
    else { Warn ('已存在但缺关键内容（trash.ps1=' + $hasTrash + ', 插件=' + $hasGuard + ', 两道闸门=' + $hasGate + ', 习惯层=' + $hasHabit + '）—— 加 -ForceRules 重建，或自己补') }
}

Step '5 计划任务（每月 1 号 10:00 体检）'
if ($NoTask) { Write-Output '  [跳过] -NoTask' }
elseif ($DryRun) { Write-Output '  [DryRun] 检查/创建计划任务' }
else {
    $doctorPath = Join-Path $Tools 'doctor.ps1'
    $action = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $doctorPath + ' -Quiet -Notify'
    # 三路探测，避免"受限环境探测不到"被误判成"不存在"（曾经的 bug：误判后 /F 创建失败，把已有任务弄丢了）
    $exists = $false
    try { if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { $exists = $true } } catch { }
    if (-not $exists -and (Test-Path -LiteralPath (Join-Path $env:WINDIR ('System32\Tasks\' + $TaskName)))) { $exists = $true }
    if (-not $exists -and ((Invoke-Quiet ('schtasks /Query /TN "' + $TaskName + '"')) -eq 0)) { $exists = $true }
    if ($exists) {
        Write-Output ('  [存在] ' + $TaskName)
        try {
            $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            $s = $t.Settings
            $changed = @()
            if (-not $s.StartWhenAvailable) { $s.StartWhenAvailable = $true; $changed += '错过就补跑' }
            if ($s.DisallowStartIfOnBatteries) { $s.DisallowStartIfOnBatteries = $false; $changed += '电池上允许启动' }
            if ($s.StopIfGoingOnBatteries) { $s.StopIfGoingOnBatteries = $false; $changed += '电池上不中断' }
            if ($s.ExecutionTimeLimit -ne 'PT10M') { $s.ExecutionTimeLimit = 'PT10M'; $changed += '限时 10 分钟' }
            if ($changed.Count -gt 0) {
                Set-ScheduledTask -TaskName $TaskName -Settings $s | Out-Null
                Write-Output ('  [修正] ' + ($changed -join '、'))
            } else { Write-Output '  [不变] 可靠性设置已正确' }
        } catch {
            Warn ('读不到任务设置（受限环境？）：' + $_.Exception.Message + ' —— 请在普通 PowerShell 里再跑一次本脚本以修正')
        }
    } else {
        $createCmd = 'schtasks /Create /TN "' + $TaskName + '" /TR "' + $action + '" /SC MONTHLY /D 1 /ST 10:00 /RL LIMITED /F'
        $r = Invoke-CmdCapture $createCmd
        foreach ($line in $r.lines) { if ($line.Trim()) { Write-Output ('  ' + $line.Trim()) } }
        if ($r.code -eq 0) { Write-Output '  [新增] 计划任务已创建（每月 1 号 10:00）' }
        else { Warn ('计划任务创建失败（schtasks 退出码 ' + $r.code + '）—— 若当前环境受限（例如在 DSH 沙箱里跑），请在普通 PowerShell 里重跑本脚本') }
    }
}

Step '6 体检'
if ($DryRun) { Write-Output '  [DryRun] 略过体检' }
else {
    $r = Invoke-ChildScript (Join-Path $Tools 'doctor.ps1')
    foreach ($line in $r.lines) { Write-Output $line }
    Write-Output ('  （doctor 退出码 ' + $r.code + '：0=正常，1=有异常）')
    if ($r.code -ne 0) { Warn '体检报告里有异常，请看上面第 [1]-[5] 段' }
}

Step '验收清单（请你亲自过一遍）'
Write-Output '  [ ] 上面 doctor 的结论是「正常」（第 [1][2][4] 段的"闸门 canary"都应显示 [OK]）'
Write-Output '  [ ] 行为探针 A（只能在 DSH 会话里做）：让代理执行  cmd /c del "C:\nope-does-not-exist.txt"  → 期望被拒绝'
Write-Output '  [ ] 行为探针 B（回收站禁区，同样只能在会话里做）：让代理跑一条"纯回收站调用"'
Write-Output '        ... trash.ps1 -Path ''C:\Windows'' -Purpose x -Reason y'
Write-Output '        → 期望在脚本运行之前就被插件拒绝（话术「【回收站通道：受保护路径】…」），且 trash-alerts.log 不新增记录'
Write-Output '  [ ] 离线救援自检：双击 ~\.dsh\tools\offline-restore.cmd → 应只"识别并列出「待删除」路径"，不搬任何东西'
Write-Output '  [ ] 重启一次 DSH，然后看 <profile>\node_modules\dsh-trash-guard\guard-status.txt 是否以 OK 开头'
Write-Output '  [ ] 计划任务下次运行时间是下个月 1 号 10:00（schtasks /Query /TN dsh-trash-guard-doctor /V /FO LIST）'
Write-Output '  [ ] 需要时给工作区装规则：~\.dsh\tools\templates\apply-workspace-rules.ps1 -Workspace <工作区>'
Write-Output '  [ ] 改过 ~\.dsh\tools 里的脚本/插件之后，记得跑一次 setup.ps1 -Export，让套装追上现状'
Write-Output '        （文档以套装根目录那几份为准：要改就改套装根目录，装机时会铺到 tools）'

Write-Output ''
if ($script:issues.Count -gt 0) {
    Write-Output ('== 完成，但有 ' + $script:issues.Count + ' 条注意/异常（见上）')
    exit 1
}
Write-Output '== 完成：全部就绪'
exit 0