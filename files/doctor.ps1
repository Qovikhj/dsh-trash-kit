<#
.SYNOPSIS
    本机「删除拦截 + 回收站」体系体检。

.DESCRIPTION
    检查五类东西：权威脚本（存在 / 能解析 / BOM / 闸门 canary）、插件源码与安装器（含受保护路径检查）、
    全局与工作区规则、每个 profile 的装载情况（插件文件 + 装载行 + 心跳）、每个工作区的「待删除」与
    归档体积和健康度，以及受保护路径闸门的告警日志与待确认请求（有人试过搬工作区之外的东西吗）。
    只读，不改任何东西；发现异常时给出可执行的修复提示。

    注意：**行为探针查不了**。拦截器活在 DSH 进程里，只有 DSH 会话内的工具调用才会被它拦，
    所以"是否真的还拦得住"必须在一个 DSH 会话里试（本脚本末尾会提示怎么做）。

.PARAMETER Quiet
    一切正常时不打印报告（只写一行日志）；有异常仍会打印。

.PARAMETER Notify
    有异常时弹一个 Windows 对话框（120 秒自动关闭）并把完整报告写到 doctor-report-*.txt。
    计划任务用这个开关；手动跑一般不用。

.PARAMETER WarnTrashMB
    「待删除」超过这个体积（MB）就提醒清理，默认 500。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\doctor.ps1"
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\doctor.ps1" -Quiet -Notify
#>
param(
    [switch] $Quiet,
    [switch] $Notify,
    [int] $WarnTrashMB = 500
)

$ErrorActionPreference = 'Stop'
$Tools = $PSScriptRoot
$Dsh = Split-Path -Parent $Tools
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:issues = New-Object System.Collections.ArrayList
$script:out = New-Object System.Collections.ArrayList

function Say([string] $Text) { [void]$script:out.Add($Text) }
function Ok([string] $Text) { [void]$script:out.Add('  [OK]   ' + $Text) }
function Note([string] $Text) { [void]$script:out.Add('  [注意] ' + $Text) }
function Bad([string] $Text) { [void]$script:out.Add('  [异常] ' + $Text); [void]$script:issues.Add($Text) }

function Test-Jsonl([string] $File, [int] $Cap = 5000) {
    $good = 0
    $bad = 0
    $total = 0
    $capped = $false
    if (Test-Path -LiteralPath $File) {
        $lines = [System.IO.File]::ReadAllLines($File, [System.Text.Encoding]::UTF8)
        $total = $lines.Count
        if ($total -gt $Cap) {
            $lines = $lines[($total - $Cap)..($total - 1)]
            $capped = $true
            $total = $lines.Count
        }
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $null = $line | ConvertFrom-Json; $good++ } catch { $bad++ }
        }
    }
    return [pscustomobject]@{ Exists = (Test-Path -LiteralPath $File); Total = $total; Good = $good; Bad = $bad; Capped = $capped }
}

function Get-DirSize([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $sum = Get-ChildItem -Recurse -File -Force -LiteralPath $Path -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    return [long]$sum.Sum
}

Say ('== DSH 删除拦截体检   ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Say ('   工具目录：' + $Tools)

# ---------------------------------------------------------------- 1 权威脚本
Say ''
Say '[1] 权威回收站脚本'
$TrashScript = Join-Path $Tools 'trash.ps1'
if (Test-Path -LiteralPath $TrashScript) {
    $bytes = [System.IO.File]::ReadAllBytes($TrashScript)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($TrashScript, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -eq 0) {
        Ok ('trash.ps1 可解析，' + $bytes.Length + ' 字节，SHA256 ' + (Get-FileHash -LiteralPath $TrashScript -Algorithm SHA256).Hash.Substring(0, 16))
    } else {
        Bad ('trash.ps1 有语法错误：' + $parseErrors[0].Message + '（第 ' + $parseErrors[0].Extent.StartLineNumber + ' 行）')
    }
    if ($hasBom) { Ok 'UTF-8 BOM 在（PowerShell 5.1 读中文必需）' }
    else { Bad 'trash.ps1 缺少 UTF-8 BOM：里面的中文会被按 GBK 读成乱码，脚本会直接报语法错' }
    # 闸门 canary：受保护路径永久拒绝 + 工作区之外的两段式确认。少了任何一条 = 被换回了旧版本。
    $tsText = [System.IO.File]::ReadAllText($TrashScript, [System.Text.Encoding]::UTF8)
    foreach ($need in @('AllowOutsideRoot', 'ConfirmCode', '受保护路径', 'trash-alerts.log')) {
        if ($tsText -match [regex]::Escape($need)) { Ok ('闸门在：提到了 ' + $need) }
        else { Bad ('闸门缺失：trash.ps1 里没有 «' + $need + '» —— 看起来是旧版本（没有受保护路径闸门），请重新部署') }
    }
} else {
    Bad ('trash.ps1 不存在：' + $TrashScript + '（重装：见 [2] 的 install.ps1，或从备份恢复）')
}
if (Test-Path -LiteralPath (Join-Path $Tools 'trash.cmd')) { Ok 'trash.cmd 在' } else { Note 'trash.cmd 不在（只是 cmd 便捷包装，不影响功能）' }

# ---------------------------------------------------------------- 2 插件源码与安装器
Say ''
Say '[2] 拦截插件源码 / 安装器 / 模板'
$PluginSrc = Join-Path $Tools 'dsh-trash-guard'
$Install = Join-Path $PluginSrc 'install.ps1'
foreach ($rel in @('package.json', 'lib\index.js', 'install.ps1', 'install-snippet.yml', 'staging\check-yaml.cjs', 'staging\global-AGENTS.md')) {
    $f = Join-Path $PluginSrc $rel
    if (Test-Path -LiteralPath $f) { Ok ($rel + ' 在') } else { Bad ('缺少 ' + $f + '（恢复能力受损；可从 tools\backup 或工作区历史找回）') }
}
if (Test-Path -LiteralPath (Join-Path $Tools 'templates\AGENTS.workspace.md')) { Ok 'templates\AGENTS.workspace.md 在' } else { Note '工作区规则模板不在（新工作区就没有"更具体"那份规则，功能不受影响）' }
# 方法 2 canary：源码里的受保护路径检查（插件不再无条件放行回收站调用）。
$GuardSrcFile = Join-Path $PluginSrc 'lib\index.js'
if (Test-Path -LiteralPath $GuardSrcFile) {
    $gtext = [System.IO.File]::ReadAllText($GuardSrcFile, [System.Text.Encoding]::UTF8)
    if ($gtext -match 'PROTECTED_PATH_RULES') { Ok '插件源码含受保护路径检查（方法 2）' }
    else { Bad '插件源码没有受保护路径检查（方法 2）—— 看起来是旧版本，请重新部署后再 install.ps1' }
}

# ---------------------------------------------------------------- 3 全局规则
Say ''
Say '[3] 全局规则 ~/.dsh/AGENTS.md'
$GlobalAgents = Join-Path $Dsh 'AGENTS.md'
if (Test-Path -LiteralPath $GlobalAgents) {
    $text = [System.IO.File]::ReadAllText($GlobalAgents, [System.Text.Encoding]::UTF8)
    Ok ('在，' + $text.Length + ' 字符')
    if ($text -match 'trash\.ps1') { Ok '提到了 trash.ps1' } else { Bad '没有提到 trash.ps1 —— 新会话将不知道唯一删除通道' }
    if ($text -match 'dsh-trash-guard') { Ok '提到了拦截插件' } else { Note '没提到插件（新会话不会知道"没被拦就该报告"这条 canary）' }
    # 2026-10-25 起全局规则多了两块：两道闸门（受保护路径 / 确认码）与"习惯层"。
    # 只检查前两项的话，规则是旧版也看不出来 → 拿它们当 canary。
    if ($text -match '受保护路径|AllowOutsideRoot') { Ok '含"两道闸门"（受保护路径 / 确认码）' } else { Bad '全局规则是旧版：没有"两道闸门"那一节（重装会被 setup.ps1 -ForceRules 覆盖，也可自己补）' }
    if ($text -match '习惯层') { Ok '含"习惯层"（别把沙箱关掉等）' } else { Bad '全局规则是旧版：没有"习惯层"那一节' }
} else {
    Bad ('全局规则不存在：' + $GlobalAgents + '（源：' + (Join-Path $PluginSrc 'staging\global-AGENTS.md') + '）')
}

# ---------------------------------------------------------------- 4 各 profile 装载情况
Say ''
Say '[4] 各 profile 的拦截插件装载'
$ProfilesDir = Join-Path $Dsh 'profiles'
$profiles = @()
if (Test-Path -LiteralPath $ProfilesDir) { $profiles = @(Get-ChildItem -Directory -LiteralPath $ProfilesDir | Sort-Object Name) }
if ($profiles.Count -eq 0) { Note ('没有找到任何 profile：' + $ProfilesDir) }
foreach ($p in $profiles) {
    $guardFile = Join-Path $p.FullName 'node_modules\dsh-trash-guard\lib\index.js'
    $patch = Join-Path $p.FullName 'cordis.patch.yml'
    $hasFile = Test-Path -LiteralPath $guardFile
    $hasRow = $false
    $hasTab = $false
    if (Test-Path -LiteralPath $patch) {
        $ptext = [System.IO.File]::ReadAllText($patch, [System.Text.Encoding]::UTF8)
        $hasRow = ($ptext -match 'dsh-trash-guard')
        $hasTab = ($ptext -match "`t")
    }
    $state = 'OK'
    if (-not $hasFile) { $state = '插件文件缺失'; Bad ($p.Name + '：插件文件缺失 —— 该 profile 下删除不会被拦（修复：install.ps1 -ProfileName ' + $p.Name + '）') }
    if (-not $hasRow) { $state = '装载行缺失'; Bad ($p.Name + '：cordis.patch.yml 里没有 trash-guard 装载行（修复：install.ps1 -ProfileName ' + $p.Name + '）') }
    if ($hasTab) { Bad ($p.Name + '：cordis.patch.yml 里出现 TAB 字符，YAML 会解析失败') }
    if ($state -eq 'OK') { Ok ($p.Name + '：插件文件在，装载行在') }
    # 装到 profile 里的那一份也要带上方法 2 的路径检查，否则它还是个"无条件放行"的旧守卫。
    if ($hasFile) {
        $pGuardText = [System.IO.File]::ReadAllText($guardFile, [System.Text.Encoding]::UTF8)
        if ($pGuardText -match 'PROTECTED_PATH_RULES') { Ok ($p.Name + '：插件含受保护路径检查') }
        else { Bad ($p.Name + '：插件是旧版本（没有受保护路径检查）—— 重跑 install.ps1 -ProfileName ' + $p.Name) }
    }
    # 心跳/失败标记：插件每次加载都会写它。没有它 = 插件从未被加载；写的是 FAILED = 装了但没挂上。
    $statusFile = Join-Path $p.FullName 'node_modules\dsh-trash-guard\guard-status.txt'
    if (Test-Path -LiteralPath $statusFile) {
        $statusLine = (Get-Content -LiteralPath $statusFile -Encoding UTF8 -TotalCount 1)
        if ($statusLine -match 'FAILED') {
            Bad ($p.Name + '：插件加载失败（删不掉东西？那说明拦截没生效）—— ' + $statusLine)
        } else {
            Ok ($p.Name + '：上次加载正常 —— ' + $statusLine)
        }
    } elseif ($hasFile) {
        Note ($p.Name + '：还没有 guard-status.txt（插件从未被加载过，或加载时 apply 没跑到；重启 DSH 后再看）')
    }
}

# ---------------------------------------------------------------- 5 各工作区
Say ''
Say '[5] 各工作区的「待删除」与归档'
$Registry = Join-Path $Dsh 'storages\workspace.json'
$wsList = @()
if (Test-Path -LiteralPath $Registry) {
    try {
        $reg = [System.IO.File]::ReadAllText($Registry, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($prop in $reg.tables.workspaces.PSObject.Properties) { $wsList += $prop.Value }
    } catch {
        Bad ('工作区注册表解析失败：' + $Registry + ' —— ' + $_.Exception.Message)
    }
}
if ($wsList.Count -eq 0) { Note '注册表里没有工作区（或注册表不存在）' }
foreach ($ws in $wsList) {
    $path = [string]$ws.path
    $title = [string]$ws.title
    Say ('  -- ' + $title + '  ' + $path)
    if (-not (Test-Path -LiteralPath $path)) { Note ('工作区目录当前不存在（可能是移动盘/已删），跳过'); continue }
    $trashDir = Join-Path $path '待删除'
    $manifest = Join-Path $trashDir '_manifest.jsonl'
    $archiveDir = Join-Path $path '.trash-archive'
    if (Test-Path -LiteralPath $trashDir) {
        $sizeMB = [math]::Round((Get-DirSize $trashDir) / 1MB, 2)
        $batches = @(Get-ChildItem -Directory -LiteralPath $trashDir -ErrorAction SilentlyContinue).Count
        $files = @(Get-ChildItem -Recurse -File -Force -LiteralPath $trashDir -ErrorAction SilentlyContinue).Count
        $m = Test-Jsonl $manifest
        Ok ('「待删除」' + $batches + ' 批 / ' + $files + ' 个文件 / ' + $sizeMB + ' MB；清单 ' + $m.Good + ' 条')
        if ($m.Bad -gt 0) { Bad ('清单有 ' + $m.Bad + ' 行无法解析：' + $manifest) }
        if (($m.Good -gt 0) -and -not (Test-Path -LiteralPath (Join-Path $trashDir '_manifest.txt'))) {
            Note ('清单缺"人读版"：' + (Join-Path $trashDir '_manifest.txt') + '（补建：trash.ps1 -RepairManifest）')
        }
        if ($sizeMB -gt $WarnTrashMB) { Note ('「待删除」已超过 ' + $WarnTrashMB + ' MB，建议手动清理确认无用的批次') }
        if ($batches -ge 5) { Note ('已积压 ' + $batches + ' 个批次，可以看看是否该清理') }
        $emptyBatches = @(Get-ChildItem -Directory -LiteralPath $trashDir -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '【空批次】*' })
        if ($emptyBatches.Count -gt 0) { Note ('有 ' + $emptyBatches.Count + ' 个已标注的空批次文件夹（还原后剩下的空壳，内容已还原走，确认后可手动删掉）') }
    } else {
        Ok '还没有「待删除」（本工作区没搬过东西）'
    }
    if (Test-Path -LiteralPath $archiveDir) {
        $shards = @(Get-ChildItem -File -LiteralPath $archiveDir -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name)
        $archiveSize = [math]::Round((Get-DirSize $archiveDir) / 1KB, 1)
        $records = 0
        $badTotal = 0
        foreach ($s in $shards) {
            $r = Test-Jsonl $s.FullName
            $records += $r.Good
            $badTotal += $r.Bad
        }
        Ok ('归档 ' + $shards.Count + ' 个分片 / ' + $records + ' 条 / ' + $archiveSize + ' KB（' + (($shards | ForEach-Object { $_.Name }) -join ', ') + '）')
        if ($badTotal -gt 0) { Bad ('归档有 ' + $badTotal + ' 行无法解析（分片文件可能被手改过）') }
        $missingHuman = 0
        foreach ($s in $shards) {
            if (-not (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($s.FullName, '.txt')))) { $missingHuman++ }
        }
        if ($missingHuman -gt 0) { Note ('归档有 ' + $missingHuman + ' 个分片缺"人读版"（补建：trash.ps1 -RepairManifest）') }
        if ($shards.Count -ge 13) { Note ('归档已积 ' + $shards.Count + ' 个月份，可整月删掉去年的') }
    }
}

# ---------------------------------------------------------------- 6 闸门告警日志与待确认请求
Say ''
Say '[6] 受保护路径闸门：告警日志与待确认请求'
$AlertLog = Join-Path $Tools 'trash-alerts.log'
$PendingFile = Join-Path $Tools 'trash-pending.json'
if (Test-Path -LiteralPath $AlertLog) {
    $alertLines = @([System.IO.File]::ReadAllLines($AlertLog, [System.Text.Encoding]::UTF8))
    $blockedCount = @($alertLines | Where-Object { $_ -match '^\[.*\] 已拦截' }).Count
    $waitCount = @($alertLines | Where-Object { $_ -match '^\[.*\] 等待确认码' }).Count
    $doneCount = @($alertLines | Where-Object { $_ -match '^\[.*\] 已执行' }).Count
    Ok ('告警日志：拦截 ' + $blockedCount + ' 次 / 等待确认码 ' + $waitCount + ' 次 / 已执行 ' + $doneCount + ' 次（' + $AlertLog + '）')
    if ($doneCount -gt 0) {
        Bad ('有 ' + $doneCount + ' 次"工作区之外的搬运"被执行过 —— 请打开日志确认是不是你要的：' + $AlertLog)
    } elseif (($blockedCount + $waitCount) -gt 0) {
        Note ('有过 ' + ($blockedCount + $waitCount) + ' 次被闸门拦下或等待确认的搬运尝试（正常现象；看一眼日志即可）：' + $AlertLog)
    }
    $lastEvent = @($alertLines | Where-Object { $_ -match '^\[' } | Select-Object -Last 1)
    if ($lastEvent.Count -gt 0) { Say ('  最后一条：' + $lastEvent[0]) }
} else {
    Ok '还没有告警日志（说明没人用回收站通道碰过工作区之外的东西）'
}
if (Test-Path -LiteralPath $PendingFile) {
    $pend = $null
    try { $pend = ([System.IO.File]::ReadAllText($PendingFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $pend = $null }
    if ($null -ne $pend -and -not [string]::IsNullOrWhiteSpace([string]$pend.code)) {
        Note ('有一笔等待确认码的搬运请求（到期 ' + $pend.expires + '）：' + (($pend.targets | ForEach-Object { $_ }) -join ' ; '))
    } else {
        Ok '待确认记录是空的（上次的确认码已用掉或作废）'
    }
} else {
    Ok '没有待确认的搬运请求'
}

# ---------------------------------------------------------------- 7 结论
Say ''
$verdict = '正常'
if ($script:issues.Count -gt 0) { $verdict = ('发现 ' + $script:issues.Count + ' 项异常') }
Say ('== 结论：' + $verdict)
Say ''
Say '[!] 行为探针（本脚本查不了，必须在 DSH 会话里做）：'
Say '    在任意 DSH 会话里让它执行   cmd /c del "C:\nope-does-not-exist.txt"'
Say '    期望：被拒绝并打印「【删除已被本机策略禁用】…」。被放行 = 拦截插件已失效。'
Say '    （你自己在 cmd/PowerShell 里删东西不会被拦，那是设计如此，不是故障。）'

# 日志与报告都是"尽力而为"：写不进去（例如本脚本被跑在受限沙箱里，工具目录不在可写范围）
# 绝不能影响体检结论和退出码。
$log = Join-Path $Tools 'doctor.log'
try {
    [System.IO.File]::AppendAllText($log, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $verdict + "`r`n"), $Utf8NoBom)
} catch {
    Note ('日志没写成（不影响结论）：' + $_.Exception.Message)
}

if ((-not $Quiet) -or ($script:issues.Count -gt 0)) {
    foreach ($line in $script:out) { Write-Output $line }
}

if ($Notify -and $script:issues.Count -gt 0) {
    $report = Join-Path $Tools ('doctor-report-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
    try {
        [System.IO.File]::WriteAllText($report, (($script:out -join "`r`n") + "`r`n"), $Utf8NoBom)
    } catch {
        $report = '(报告也没写成：' + $_.Exception.Message + ')'
    }
    $msg = 'DSH 删除拦截体检发现 ' + $script:issues.Count + ' 项异常：' + "`r`n`r`n" + (($script:issues | Select-Object -First 5) -join "`r`n") + "`r`n`r`n完整报告：" + $report
    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.Popup($msg, 120, 'DSH 删除拦截体检', 48)
    } catch { }
}

if ($script:issues.Count -gt 0) { exit 1 }
exit 0