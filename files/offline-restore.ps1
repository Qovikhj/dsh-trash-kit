<#
.SYNOPSIS
    离线救援：把「待删除」里的东西按清单搬回原始路径 —— 不依赖 DSH，可在 WinRE 或另一台机器上跑。

.DESCRIPTION
    什么时候用它：DSH 起不来、系统进不去、换机器，或者你只想拖一下就还原。

    它只读 <待删除>\_manifest.jsonl（纯文本，trash.ps1 写的），把记录里的 trashPath 搬回 originalPath：
      · 只搬，不删：任何情况下都不会删除任何东西；
      · 绝不覆盖：原路径已经存在就跳过并报告，由你自己决定怎么办；
      · 空批次只改名：还原完剩下的空批次文件夹会被加上「【空批次】」前缀做标注（内容一个不动），
        清不清由你决定 —— 本工具永远不删「待删除」里的任何东西；
      · 坏行不静默：解析不了的行会数出来并提醒人工看一眼；
      · 可映射盘符：WinRE 里盘符常常变了，用 -Map 'C:=D:' 把清单里的 C: 改写成现在的 D:；
      · 还原动作会追加到日志（默认 <待删除>\_restore-log.txt）。

    三种用法：
      1) 把某个工作区的「待删除」文件夹拖到 offline-restore.cmd 上   → 还原里面全部；
      2) 把「待删除」里的某个批次文件夹拖上去（可以拖很深，会自动找到批次名）→ 只还原那一批；
      3) 什么都不给（直接双击）→ **只识别、只报告**：列出本机能找到的「待删除」路径，
         **不会搬运任何东西**。要还原必须显式给路径（拖拽，或用 -TrashRoot 指定）。

.PARAMETER TrashRoot
    「待删除」文件夹，或者它里面的某个批次文件夹（会自动换算成"只还原那一批"）。
    **不填 = 只识别并列出候选路径，什么都不搬**（见上面第 3 种用法）。

.PARAMETER Record
    只还原这些记录号（逗号分隔，例如 '1,2,5'）。不给就是全部（或配合 -Batch 限定）。

.PARAMETER Batch
    只还原某个批次（批次名就是 <待删除> 下的文件夹名，形如 20261025-122557）。
    如果那个文件夹已经被标成「【空批次】xxx」，写哪个名字都认。

.PARAMETER List
    只列清单，不还原（可与 -Record / -Batch 一起用）。

.PARAMETER DryRun
    只打印将要发生什么，不实际搬。

.PARAMETER MarkEmpty
    只做一件事：把「待删除」里已经空掉的批次文件夹加上「【空批次】」前缀（只改名、不删东西）。

.PARAMETER Map
    盘符映射，可多个，形如 'C:=D:'：左边是清单里记录的原盘符，右边是现在实际的盘符。

.PARAMETER LogFile
    还原日志路径，默认 <待删除>\_restore-log.txt。

.EXAMPLE
    直接双击 offline-restore.cmd 看用法（不带路径时它只识别、只列路径，不会搬运任何东西）
.EXAMPLE
    & "$env:USERPROFILE\.dsh\tools\offline-restore.cmd"                       # 只识别：列出本机所有「待删除」路径
.EXAMPLE
    & "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -List
.EXAMPLE
    & "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除\20261025-122557" -DryRun
.EXAMPLE
    & "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "D:\待删除" -Map "C:=D:"
#>
param(
    [Parameter(Position = 0)]
    [string] $TrashRoot = '',
    [string] $Record = '',
    [string] $Batch = '',
    [switch] $List,
    [switch] $DryRun,
    [switch] $MarkEmpty,
    [string[]] $Map = @(),
    [string] $LogFile = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$EmptyTag = '【空批次】'
$ManifestName = '_manifest.jsonl'

function Test-IsTrashRoot([string] $Dir) {
    return (Test-Path -LiteralPath (Join-Path $Dir $ManifestName))
}

function Convert-MappedPath([string] $Value) {
    # 把清单里的盘符换成现在的实际盘符（WinRE / 换机器时用）。
    $v = [string]$Value
    foreach ($m in $Map) {
        if ($m -match '^\s*([A-Za-z])\s*:\s*=\s*([A-Za-z])\s*:\s*$') {
            $from = $Matches[1].ToUpper() + ':'
            $to = $Matches[2].ToUpper() + ':'
            $upper = $v.ToUpper()
            if ($upper -eq $from) { return $to }
            if ($upper.StartsWith($from + '\')) { return ($to + $v.Substring(2)) }
        }
    }
    return $v
}

function Normalize-BatchName([string] $Name) {
    # 允许直接写「【空批次】xxx」这种被标注过的名字。
    $n = [string]$Name
    if ($n.StartsWith($EmptyTag)) { return $n.Substring($EmptyTag.Length) }
    return $n
}

function Resolve-TrashTarget([string] $InputPath) {
    # 用户拖进来/写进来的可能是：①「待删除」本身；②里面的某个批次文件夹（甚至更深的子目录）；③一个文件。
    # 返回 TrashRoot +（可选）Batch。
    $p = [System.IO.Path]::GetFullPath($InputPath)
    if (-not (Test-Path -LiteralPath $p)) { throw ('路径不存在：' + $InputPath) }
    $item = Get-Item -LiteralPath $p -Force
    if (-not $item.PSIsContainer) { $p = (Split-Path -Parent $p) }
    $p = $p.TrimEnd('\')
    if (Test-IsTrashRoot $p) {
        return [pscustomobject]@{ TrashRoot = $p; Batch = ''; How = '这就是「待删除」文件夹' }
    }
    $cur = $p
    for ($i = 0; $i -lt 8; $i++) {
        $parent = Split-Path -Parent $cur
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) { break }
        if (Test-IsTrashRoot $parent) {
            $batch = Normalize-BatchName (Split-Path -Leaf $cur)
            return [pscustomobject]@{ TrashRoot = $parent; Batch = $batch; How = ('这是「待删除」里的一个批次文件夹，只还原这一批：' + $batch) }
        }
        $cur = $parent
    }
    throw ('这不像「待删除」文件夹（里面没有 ' + $ManifestName + '），也不在任何「待删除」里面：' + $InputPath)
}

function Get-LastUsedPath {
    $f = Join-Path $PSScriptRoot 'offline-restore-last.txt'
    if (Test-Path -LiteralPath $f) {
        try { return ([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)).Trim() } catch { return '' }
    }
    return ''
}

function Save-LastUsedPath([string] $Path) {
    try { [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'offline-restore-last.txt'), $Path, $Utf8NoBom) } catch { }
}

function Get-WorkspaceTrashRoots {
    # DSH 登记过的工作区（换机器、任意工作区都能认出来）。
    $out = New-Object System.Collections.ArrayList
    $reg = Join-Path $env:USERPROFILE '.dsh\storages\workspace.json'
    if (Test-Path -LiteralPath $reg) {
        try {
            $j = [System.IO.File]::ReadAllText($reg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($prop in $j.tables.workspaces.PSObject.Properties) {
                $wsPath = [string]$prop.Value.path
                if (-not [string]::IsNullOrWhiteSpace($wsPath)) { [void]$out.Add((Join-Path $wsPath '待删除')) }
            }
        } catch { }
    }
    return , $out
}

function Get-NearbyTrashRoots {
    # 脚本自己所在目录、它的上级、以及当前目录的上溯：适合"工具就放在工作区里/旁边"的用法。
    $out = New-Object System.Collections.ArrayList
    foreach ($start in @($PSScriptRoot, (Get-Location).Path)) {
        $cur = $start
        for ($i = 0; $i -lt 5; $i++) {
            [void]$out.Add((Join-Path $cur '待删除'))
            $parent = Split-Path -Parent $cur
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) { break }
            $cur = $parent
        }
    }
    return , $out
}

function Get-ScannedTrashRoots {
    # 兜底：各固定盘里找名为「待删除」的文件夹（最多 3 层）。只在别的手段都没找到时才会跑。
    $out = New-Object System.Collections.ArrayList
    $drives = @()
    try { $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' }) } catch { $drives = @() }
    if ($drives.Count -eq 0) {
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Za-z]$' })
    }
    foreach ($d in $drives) {
        $root = ''
        try { $root = [string]$d.RootDirectory } catch { $root = '' }
        if ([string]::IsNullOrWhiteSpace($root)) { $root = (([string]$d.Name).TrimEnd(':')) + ':\' }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Write-Host ('  正在扫描 ' + $root + ' …')
        try {
            $hits = @(Get-ChildItem -LiteralPath $root -Directory -Filter '待删除' -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue)
            foreach ($h in $hits) { [void]$out.Add($h.FullName) }
        } catch { }
    }
    return , $out
}

function Find-TrashRoots {
    # 只"找"，不搬：按"最可能"的顺序收集候选，去重后只留下真的含清单的目录，返回路径列表。
    # 注意：提示一律用 Write-Host（不是 Write-Output）——调用方是 $x = Find-TrashRoots，
    # 用 Write-Output 的话提示会被"函数返回值"一起抓走，用户根本看不到（2026-10-25 踩过）。
    $candidates = New-Object System.Collections.ArrayList
    $last = Get-LastUsedPath
    if (-not [string]::IsNullOrWhiteSpace($last)) { [void]$candidates.Add($last) }
    # 注意：这些函数用 `return , $out` 返回集合，所以这里**不能**再套 @(...)：
    # 套了会把整个集合当成一个元素（再 [string] 化就变成一整串空格拼接的路径，候选全废）。
    foreach ($c in (Get-NearbyTrashRoots)) { [void]$candidates.Add([string]$c) }
    foreach ($c in (Get-WorkspaceTrashRoots)) { [void]$candidates.Add([string]$c) }

    $found = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $full = ''
        try { $full = [System.IO.Path]::GetFullPath($c).TrimEnd('\') } catch { continue }
        $key = $full.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-IsTrashRoot $full) { [void]$found.Add($full) }
    }
    if ($found.Count -eq 0) {
        Write-Host '上次用过的位置、脚本旁边、DSH 登记过的工作区里都没找到「待删除」，现在兜底扫描各固定盘（最多 3 层）……'
        foreach ($c in (Get-ScannedTrashRoots)) {
            $full = ''
            try { $full = [System.IO.Path]::GetFullPath([string]$c).TrimEnd('\') } catch { continue }
            $key = $full.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (Test-IsTrashRoot $full) { [void]$found.Add($full) }
        }
    }
    return , $found
}

function Test-BatchEmpty([string] $Dir) {
    # "空批次" = 除了 README.md 之外没有任何文件（目录树可以是空的）。
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) { if ($f.Name -ne 'README.md') { return $false } }
    return $true
}

function Rename-EmptyBatches([string] $Root) {
    # 只改名、不删东西：给还原后剩下的空批次加「【空批次】」前缀，方便你自己清理。
    # 注意：刚用 Move-Item 搬走东西的批次，Windows 可能还握着句柄 → Rename-Item 会瞬时失败，
    # 所以这里重试几次；仍然失败就**报出来**（绝不静默吞掉 —— "失败不静默"是硬性不变量）。
    $changed = New-Object System.Collections.ArrayList
    $blocked = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Name.StartsWith($EmptyTag)) { continue }
        if (-not (Test-BatchEmpty $d.FullName)) { continue }
        $newName = $EmptyTag + $d.Name
        if (Test-Path -LiteralPath (Join-Path $Root $newName)) { continue }
        $done = $false
        $lastError = ''
        for ($attempt = 1; $attempt -le 5 -and -not $done; $attempt++) {
            try {
                Rename-Item -LiteralPath $d.FullName -NewName $newName -ErrorAction Stop
                $done = $true
            } catch {
                $lastError = $_.Exception.Message
                Start-Sleep -Milliseconds 300
            }
        }
        if ($done) { [void]$changed.Add($d.Name) }
        else { [void]$blocked.Add(($d.Name + '  —— ' + $lastError)) }
    }
    return [pscustomobject]@{ Changed = $changed; Blocked = $blocked }
}

function Write-RescueLog([string] $Text) {
    # 尽力而为：日志写不进去也不能影响还原本身。
    try { [System.IO.File]::AppendAllText($LogFile, $Text, $Utf8NoBom) } catch { }
}

function Format-Size([long] $Bytes) {
    if ($Bytes -lt 1024) { return "$Bytes B" }
    if ($Bytes -lt 1048576) { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    if ($Bytes -lt 1073741824) { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    return ('{0:N2} GB' -f ($Bytes / 1073741824))
}

# ---------------------------------------------------------------- 定位
# 不给路径 = **只识别、只报告，绝不搬运**（双击本文件走的就是这条路）。
if ([string]::IsNullOrWhiteSpace($TrashRoot)) {
    Write-Output '没有给「待删除」路径 —— 只做识别，不会搬运任何东西。'
    Write-Output ''
    $foundRoots = Find-TrashRoots
    if ($foundRoots.Count -eq 0) {
        Write-Output '没找到任何「待删除」文件夹。'
        Write-Output '要还原的话：把那个「待删除」文件夹（或它里面的某个批次文件夹）拖到 offline-restore.cmd 上。'
        exit 0
    }
    Write-Output ('识别到 ' + $foundRoots.Count + ' 个「待删除」：')
    foreach ($f in $foundRoots) { Write-Output ('  ' + $f) }
    Write-Output ''
    Write-Output '要还原：把上面某个文件夹（或它里面的某个批次文件夹）拖到 offline-restore.cmd 上；'
    Write-Output '或用 -TrashRoot ''<路径>'' 明确指定。本工具不会自己决定还原什么。'
    exit 0
}
$target = Resolve-TrashTarget $TrashRoot
Save-LastUsedPath $target.TrashRoot
Write-Output ('定位：' + $target.How)
Write-Output ('「待删除」：' + $target.TrashRoot)
$TrashRoot = $target.TrashRoot
if ([string]::IsNullOrWhiteSpace($Batch) -and -not [string]::IsNullOrWhiteSpace([string]$target.Batch)) { $Batch = [string]$target.Batch }
$Batch = Normalize-BatchName $Batch
$ManifestPath = Join-Path $TrashRoot $ManifestName
if (-not (Test-Path -LiteralPath $ManifestPath)) { throw ('找不到清单：' + $ManifestPath) }
if ([string]::IsNullOrWhiteSpace($LogFile)) { $LogFile = Join-Path $TrashRoot '_restore-log.txt' }

# ---------------------------------------------------------------- -MarkEmpty
if ($MarkEmpty) {
    Write-Output ('只做标注：给空掉的批次文件夹加「' + $EmptyTag + '」前缀（只改名、不删东西）')
    Write-Output ('「待删除」：' + $TrashRoot)
    $renamedOnly = Rename-EmptyBatches $TrashRoot
    if ($renamedOnly.Changed.Count -eq 0 -and $renamedOnly.Blocked.Count -eq 0) { Write-Output '没有需要标注的空批次。' }
    foreach ($n in $renamedOnly.Changed) { Write-Output ('  已标注：' + $EmptyTag + $n) }
    if ($renamedOnly.Blocked.Count -gt 0) {
        Write-Output ('  有 ' + $renamedOnly.Blocked.Count + ' 个空批次这次没标成（多半是被瞬时占用）：')
        foreach ($n in $renamedOnly.Blocked) { Write-Output ('    ' + $n) }
        Write-Output '  过几秒再跑一次 -MarkEmpty 就行（只改名，不影响任何内容）。'
    }
    exit 0
}

# ---------------------------------------------------------------- 读清单
$records = New-Object System.Collections.ArrayList
$badLines = New-Object System.Collections.ArrayList
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($ManifestPath, [System.Text.Encoding]::UTF8)) {
    $lineNo++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $obj = $null
    try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }
    if ($null -eq $obj -or $null -eq $obj.PSObject.Properties['originalPath']) {
        [void]$badLines.Add($lineNo)
        continue
    }
    [void]$records.Add($obj)
}

if ($records.Count -eq 0) {
    Write-Output ('清单里没有可还原的记录：' + $ManifestPath)
    if ($badLines.Count -gt 0) { Write-Output ('有 ' + $badLines.Count + ' 行解析不了（第 ' + ($badLines -join ', ') + ' 行）—— 请人工看一眼清单文件'); exit 1 }
    exit 0
}

# ---------------------------------------------------------------- 过滤
$selected = $records
if (-not [string]::IsNullOrWhiteSpace($Record)) {
    $ids = @($Record.Split(',') | ForEach-Object { $_.Trim() })
    $selected = @($selected | Where-Object { $ids -contains ([string]$_.id) })
}
if (-not [string]::IsNullOrWhiteSpace($Batch)) {
    $selected = @($selected | Where-Object { ([string]$_.batch) -eq $Batch })
}
if (@($selected).Count -eq 0) {
    Write-Output ('按 -Record/-Batch 过滤后没有记录可处理（批次「' + $Batch + '」）。用 -List 看看清单里都有什么。')
    exit 0
}

# ---------------------------------------------------------------- -List
if ($List) {
    Write-Output ('待删除清单：' + $ManifestPath)
    Write-Output ('（共 ' + $records.Count + ' 条，本次选中 ' + @($selected).Count + ' 条；只列不动）')
    if ($badLines.Count -gt 0) { Write-Output ('注意：有 ' + $badLines.Count + ' 行解析不了（第 ' + ($badLines -join ', ') + ' 行）') }
    Write-Output ''
    Write-Output '| # | 批次 | 原始路径 | 现在在哪（待删除路径） | 大小 | 用途 | 删除原因 |'
    Write-Output '|---|---|---|---|---|---|---|'
    foreach ($r in $selected) {
        Write-Output ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $r.id, $r.batch, (Convert-MappedPath $r.originalPath), (Convert-MappedPath $r.trashPath), (Format-Size ([long]$r.sizeBytes)), $r.purpose, $r.reason)
    }
    Write-Output ''
    Write-Output '还原：加 -Record <号> 或 -Batch <批次>（先加 -DryRun 看一眼）；盘符变了就加 -Map ''C:=D:'''
    exit 0
}

# ---------------------------------------------------------------- 还原
Write-Output ('离线救援（只搬不删、绝不覆盖）   ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Write-Output ('「待删除」：' + $TrashRoot)
if (-not [string]::IsNullOrWhiteSpace($Batch)) { Write-Output ('只处理批次：' + $Batch) }
if ($DryRun) { Write-Output '模式：DryRun（只报告，不搬）' }
if ($Map.Count -gt 0) { Write-Output ('盘符映射：' + ($Map -join ' , ')) }
Write-Output ''

$restored = 0
$skipped = 0
$failed = 0
foreach ($r in $selected) {
    $src = Convert-MappedPath $r.trashPath
    $dst = Convert-MappedPath $r.originalPath
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Output ('跳过（「待删除」里已经找不到，可能早就还原过或被手工清理）：' + $src)
        $skipped++
        continue
    }
    if (Test-Path -LiteralPath $dst) {
        Write-Output ('跳过（原路径已被占用，本工具绝不覆盖）：' + $dst)
        Write-Output ('      待还原的东西还在：' + $src + '  —— 你自己决定是改名、还是换个地方放')
        $skipped++
        continue
    }
    if ($DryRun) {
        Write-Output ('[DryRun] {0}  ->  {1}   （用途：{2}；原因：{3}）' -f $src, $dst, $r.purpose, $r.reason)
        continue
    }
    $parent = Split-Path -Parent $dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    try {
        Move-Item -LiteralPath $src -Destination $dst
        if (Test-Path -LiteralPath $dst) {
            $restored++
            Write-Output ('已还原：{0}  ->  {1}' -f $src, $dst)
            Write-RescueLog (('[{0}] 还原 #{1}（批次 {2}）：{3}  ->  {4}{5}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $r.id, $r.batch, $src, $dst, "`r`n"))
        } else {
            $failed++
            Write-Output ('搬运后没在目标位置看到东西，请人工确认：{0}' -f $dst)
            Write-RescueLog (('[{0}] 疑似失败 #{1}：{2}  ->  {3}{4}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $r.id, $src, $dst, "`r`n"))
        }
    } catch {
        $failed++
        Write-Output ('搬不动（可能被占用或权限不够）：{0}  —— {1}' -f $dst, $_.Exception.Message)
        Write-RescueLog (('[{0}] 失败 #{1}：{2}{3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $r.id, $_.Exception.Message, "`r`n"))
    }
}

Write-Output ''
Write-Output ('小结：还原 {0} 件 / 跳过 {1} 件 / 失败 {2} 件' -f $restored, $skipped, $failed)
if ($DryRun) { Write-Output '（DryRun：什么都没搬；去掉 -DryRun 才会真还原）' }

# 还原完把空掉的批次文件夹标注一下（只改名、不删东西）。
if (-not $DryRun) {
    $renamed = Rename-EmptyBatches $TrashRoot
    if ($renamed.Changed.Count -gt 0) {
        Write-Output ''
        Write-Output ('已标注 ' + $renamed.Changed.Count + ' 个空批次文件夹（只改名、里面的东西一个没动）：')
        foreach ($n in $renamed.Changed) { Write-Output ('  ' + $EmptyTag + $n) }
        Write-Output '确认没用之后，由你自己删掉这些文件夹。'
    }
    if ($renamed.Blocked.Count -gt 0) {
        Write-Output ''
        Write-Output ('注意：有 ' + $renamed.Blocked.Count + ' 个空批次这次没能改名（多半是刚搬完东西被瞬时占用）—— 过几秒再跑一次 -MarkEmpty 就行：')
        foreach ($n in $renamed.Blocked) { Write-Output ('    ' + $n) }
    }
}

if ($badLines.Count -gt 0) { Write-Output ('注意：清单里有 ' + $badLines.Count + ' 行解析不了（第 ' + ($badLines -join ', ') + ' 行）—— 请人工看一眼') }
if (-not $DryRun -and $restored -gt 0) { Write-Output ('还原日志：' + $LogFile) }
if ($failed -gt 0 -or $badLines.Count -gt 0) { exit 1 }
exit 0