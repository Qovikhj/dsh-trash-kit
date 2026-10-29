<#
.SYNOPSIS
    把要删除的文件/文件夹搬进「待删除」文件夹——这是本机唯一被允许的“删除”通道，脚本本身不做任何真正删除。

.DESCRIPTION
    只做三件事（外加搬运前的两道闸门）：把目标 Move-Item 到 待删除\<批次>\<盘符>\<原路径>、写清单、写批次报告。
    真正从磁盘上抹掉文件由用户手动完成。

    【两道闸门】搬运之前先判定，判定不过就“一件都不搬”：
      · 闸门一（永久拒绝，没有开关）：盘符根；系统/引导/程序目录（Windows、Program Files、ProgramData、
        Recovery、Boot、EFI、$Recycle.Bin、System Volume Information、引导与交换文件…）；DSH 家目录
        ~\.dsh（拦截插件、回收站工具、会话与工作区注册表都在里面）；本工作区自身或其上级目录。
        命中即抛错，并写一条告警日志。
      · 闸门二（工作区之外的两段式确认）：目标不在 -Root 之下时，必须加 -AllowOutsideRoot；第一次只预演、
        什么都不搬，并打印一次性确认码（默认 30 分钟有效、只对这次的目标集合有效，记录在
        ~\.dsh\tools\trash-pending.json）；拿到确认码后再加 -ConfirmCode 重跑才会真正搬。每次“等待确认 /
        拦截 / 已执行”都写告警日志（默认 ~\.dsh\tools\trash-alerts.log），doctor.ps1 体检会把
        “已执行的工作区之外搬运”报成异常。
      另外：通配符命中超过 -MaxWildcard（默认 20）项时拒绝，要求显式列出路径；网络(UNC)路径、8.3 短名、
      \\?\ 前缀等写法一律拒绝（要求写完整长路径）。

    每份记录都会同时生成两种格式：
      · 机器读（脚本只用这个）：待删除\_manifest.jsonl、.trash-archive\<年-月>.jsonl（一行一条 JSON）
      · 人读（记事本直接打开）：待删除\_manifest.txt、.trash-archive\<年-月>.txt、各批次 README.md
        块状排版（一行标题 + 缩进明细），带 UTF-8 BOM，中文不会乱码。

.PARAMETER Path
    要搬运的文件或文件夹（可多个）。支持通配符；相对路径按当前目录解析。

.PARAMETER Purpose
    这些东西原本是干什么用的（会写进清单与报告）。

.PARAMETER Reason
    为什么要删除（会写进清单与报告）。

.PARAMETER Root
    「待删除」放在哪个工作区，默认取命令执行时的当前目录（对 DSH 会话通常就是会话工作区）。

.PARAMETER Batch
    批次名，默认按当前时间生成（yyyyMMdd-HHmmss）。

.PARAMETER List
    只列出清单，不搬运。

.PARAMETER Restore
    把「待删除」里的东西搬回原始路径（用 -Record 指定记录号，缺省还原整批）。
    还原完会把只剩空壳的批次文件夹改名成「【空批次】<原名>」做标注 —— 只改名，绝不删除里面的任何东西。

.PARAMETER Record
    -Restore 时指定清单记录号。

.PARAMETER DryRun
    只打印将要发生什么，不实际移动。

.PARAMETER AllowOutsideRoot
    明确允许搬运工作区（-Root）之外的路径。不加这个开关时，工作区之外的目标会被拒绝。
    加了之后也不会立刻搬：第一次只预演、什么都不搬，并打印一次性确认码，必须再用 -ConfirmCode 重跑才真正搬。

.PARAMETER ConfirmCode
    上一次预演打印出来的确认码（形如 A1B2-C3D4）。默认 30 分钟内有效，且只对那次的目标集合有效
    （目标改了就必须重新预演拿新码）；用掉即作废。

.PARAMETER ConfirmTtlMinutes
    确认码有效期，默认 30 分钟；0 表示立刻过期（测试用）。

.PARAMETER MaxWildcard
    通配符最多允许命中多少项，默认 20；超过就拒绝，要求显式列出要搬的路径。

.PARAMETER AlertLog
    告警日志路径，默认 ~\.dsh\tools\trash-alerts.log。写不进去（例如受限沙箱）只提示，不影响主流程。

.PARAMETER PendingFile
    待确认请求（确认码）的记录文件，默认 ~\.dsh\tools\trash-pending.json。

.PARAMETER History
    打印搬运历史归档。归档按月分片存在 <Root>\.trash-archive\<年-月>.jsonl：它在「待删除」之外，所以清空「待删除」也不会丢历史，旧月份可以整个删掉。
    默认只看当月分片、最多 50 条；-All 读全部分片，-Tail 0 取消条数上限。

.PARAMETER All
    配合 -History：读全部分片（不加则只读当月分片）。

.PARAMETER Tail
    配合 -History：最多显示最近多少条，默认 50；0 表示不限。

.EXAMPLE
    权威脚本住在 DSH 家目录，工作区里没有副本；在哪个工作区干活，「待删除」就落在哪个工作区：
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\trash.ps1" `
      -Path '.\build\old.log' -Purpose '旧构建日志' -Reason '已无参考价值'

.EXAMPLE
    清单与还原跟随 -Root（默认当前目录），在别的工作区操作时要带上 -Root：
    ... -List
    ... -Restore -Record 3
    ... -Root 'D:\proj' -List
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Path,
    [string] $Purpose = '',
    [string] $Reason = '',
    [string] $Root = '',
    [string] $Batch = '',
    [switch] $List,
    [switch] $Restore,
    [string] $Record = '',
    [switch] $RepairManifest,
    [switch] $History,
    [switch] $All,
    [int] $Tail = 50,
    [switch] $DryRun,
    # ---- 受保护路径闸门（方法 1 / 方法 3）----
    [switch] $AllowOutsideRoot,
    [string] $ConfirmCode = '',
    [int] $ConfirmTtlMinutes = 30,
    [int] $MaxWildcard = 20,
    [string] $AlertLog = '',
    [string] $PendingFile = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($Root)) {
    # 默认把「待删除」放在命令执行时的当前目录（DSH 会话里通常就是会话工作区），
    # 这样换工作区不必记参数；要在别处落账就显式给 -Root。
    $Root = (Get-Location).Path
}
$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
$TrashRoot = Join-Path $Root '待删除'
$ManifestPath = Join-Path $TrashRoot '_manifest.jsonl'
# 归档日志按月分片放在「待删除」之外：清单描述"当前在押"，归档是永久流水（清空文件夹也不丢）。
# 分片文件名就是年月，所以旧月份可以整个删掉，不会影响新记账。
$ArchiveDir = Join-Path $Root '.trash-archive'
# 「人读版」：同样的记录，排成一行标题 + 缩进明细并带 BOM，记事本/编辑器直接打开就能读。
# 机器读的仍然是 .jsonl（脚本、doctor、-History 都只认 JSONL，两者互不影响）。
$ManifestTextPath = Join-Path $TrashRoot '_manifest.txt'
# 闸门的两个落点都放在 DSH 家目录（不在工作区里）：告警日志与"待确认"记录。
# 这样清空「待删除」、甚至换工作区，都不会把"谁试过搬工作区之外的东西"这段痕迹抹掉。
if ([string]::IsNullOrWhiteSpace($AlertLog)) { $AlertLog = Join-Path $env:USERPROFILE '.dsh\tools\trash-alerts.log' }
if ([string]::IsNullOrWhiteSpace($PendingFile)) { $PendingFile = Join-Path $env:USERPROFILE '.dsh\tools\trash-pending.json' }
# 空批次的标注前缀：还原之后只剩空壳的批次文件夹会被改名成「【空批次】<原名>」——
# 只改名、不删东西；清不清由用户决定（本脚本永不删除「待删除」里的内容）。
$EmptyTag = '【空批次】'

function Get-ArchiveShardPath([datetime] $When) {
    return (Join-Path $ArchiveDir ($When.ToString('yyyy-MM') + '.jsonl'))
}

function Get-ArchiveShardFiles([switch] $AllShards) {
    if (-not (Test-Path -LiteralPath $ArchiveDir)) { return @() }
    if ($AllShards) {
        return @(Get-ChildItem -LiteralPath $ArchiveDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    $current = Get-ArchiveShardPath (Get-Date)
    if (Test-Path -LiteralPath $current) { return @($current) }
    return @()
}

function Get-ArchiveShardTextPath([string] $ShardPath) {
    return ([System.IO.Path]::ChangeExtension($ShardPath, '.txt'))
}

function Write-Human([string] $LiteralPath, [string] $Text, [switch] $Append) {
    # 人读版第一次写入带 BOM（记事本才不会把中文当 ANSI 乱码），之后追加不再写 BOM。
    $dir = Split-Path -Parent $LiteralPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ((-not $Append) -or (-not (Test-Path -LiteralPath $LiteralPath))) {
        [System.IO.File]::WriteAllText($LiteralPath, $Text, (New-Object System.Text.UTF8Encoding($true)))
    } else {
        [System.IO.File]::AppendAllText($LiteralPath, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Format-HumanRecord([object] $Entry) {
    # 一条记录 = 一行可扫读的标题 + 缩进明细（没有表格，就不存在中文对不齐的问题）。
    $event = '搬运'
    if ([string]$Entry.event -eq 'restore') { $event = '还原' }
    $kind = '文件'
    if ([string]$Entry.kind -eq 'directory') { $kind = '目录' }
    $flag = ''
    if ($null -ne $Entry.PSObject.Properties['verified'] -and $Entry.verified) { $flag = '   [已核验]' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('[{0}] {1}   {2}   {3} / {4}{5}' -f $Entry.id, $Entry.time, $event, $kind, (Format-Size ([long]$Entry.sizeBytes)), $flag))
    [void]$lines.Add(('      原始：' + $Entry.originalPath))
    [void]$lines.Add(('      待删除：' + $Entry.trashPath))
    [void]$lines.Add(('      用途：' + $Entry.purpose))
    [void]$lines.Add(('      原因：' + $Entry.reason))
    if ($null -ne $Entry.PSObject.Properties['restoredAt'] -and $Entry.restoredAt) {
        [void]$lines.Add(('      还原于：' + $Entry.restoredAt))
    }
    if ($null -ne $Entry.PSObject.Properties['batch'] -and $Entry.batch) {
        [void]$lines.Add(('      批次：' + $Entry.batch))
    }
    [void]$lines.Add('')
    return ($lines -join "`r`n")
}

function Write-ManifestSnapshot([object] $Records) {
    # 「当前在押」的人读版快照：整份重写（因为还原会改状态），原地更新。
    $total = [long]0
    foreach ($r in $Records) { $total += [long]$r.sizeBytes }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('============================================================')
    [void]$lines.Add('待删除清单（人读版 · 由 trash.ps1 自动生成，请勿手改）')
    [void]$lines.Add('============================================================')
    [void]$lines.Add(('工作区  ：' + $Root))
    [void]$lines.Add(('生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$lines.Add(('在押合计：{0} 条 / {1}' -f $Records.Count, (Format-Size $total)))
    [void]$lines.Add('机器读的是同目录 _manifest.jsonl；搬回来用 trash.ps1 -Restore -Record <号>。')
    [void]$lines.Add('')
    foreach ($r in $Records) {
        [void]$lines.Add(('-------- 状态：' + (Get-Status $r) + ' --------'))
        [void]$lines.Add((Format-HumanRecord $r))
    }
    Write-Human -LiteralPath $ManifestTextPath -Text (($lines -join "`r`n") + "`r`n")
}

function Write-Utf8([string] $LiteralPath, [string] $Text, [switch] $Append) {
    $dir = Split-Path -Parent $LiteralPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    if ($Append) {
        [System.IO.File]::AppendAllText($LiteralPath, $Text, $Utf8NoBom)
    } else {
        [System.IO.File]::WriteAllText($LiteralPath, $Text, $Utf8NoBom)
    }
}

function Convert-LegacyRecord([string] $Text) {
    # 早期版本把记录写成了 "@{id=1; ...}" 字符串形式：这里按 key=value 还原成对象。
    $inner = $Text.Trim()
    if ($inner.StartsWith('@{')) { $inner = $inner.Substring(2) }
    if ($inner.EndsWith('}')) { $inner = $inner.Substring(0, $inner.Length - 1) }
    $map = @{}
    foreach ($part in ($inner -split ';\s*(?=[A-Za-z][A-Za-z0-9]*=)')) {
        $idx = $part.IndexOf('=')
        if ($idx -gt 0) { $map[$part.Substring(0, $idx).Trim()] = $part.Substring($idx + 1) }
    }
    if ($map.Count -eq 0) { return $null }
    $id = 0
    [void][int]::TryParse([string]$map['id'], [ref]$id)
    $size = [long]0
    [void][long]::TryParse([string]$map['sizeBytes'], [ref]$size)
    $verified = $false
    [void][bool]::TryParse([string]$map['verified'], [ref]$verified)
    return [pscustomobject][ordered]@{
        id           = $id
        time         = [string]$map['time']
        batch        = [string]$map['batch']
        originalPath = [string]$map['originalPath']
        trashPath    = [string]$map['trashPath']
        kind         = [string]$map['kind']
        sizeBytes    = $size
        sha256       = [string]$map['sha256']
        purpose      = [string]$map['purpose']
        reason       = [string]$map['reason']
        root         = [string]$map['root']
        verified     = $verified
    }
}

function Get-Manifest {
    $records = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $ManifestPath) {
        foreach ($line in [System.IO.File]::ReadAllLines($ManifestPath, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $obj = $null
            try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }
            if ($obj -is [string]) { $obj = Convert-LegacyRecord $obj }
            if ($null -ne $obj -and $null -ne $obj.PSObject.Properties['id']) { [void]$records.Add($obj) }
        }
    }
    # 逗号阻止 PowerShell 把单元素集合解包，保证调用方拿到的始终是集合（.Count 才可靠）。
    return , $records
}

function Save-Manifest([object] $Records) {
    $lines = @()
    foreach ($r in $Records) { $lines += ($r | ConvertTo-Json -Compress -Depth 5) }
    Write-Utf8 -LiteralPath $ManifestPath -Text (($lines -join "`r`n") + "`r`n")
}

function Get-Status($Record) {
    if (Test-Path -LiteralPath ([string]$Record.trashPath)) { return '在待删除' }
    if ($null -ne $Record.PSObject.Properties['restored'] -and $Record.restored) { return '已还原' }
    return '已不在待删除（可能已被用户手动清理）'
}

function Format-Size([long] $Bytes) {
    if ($Bytes -lt 1024) { return "$Bytes B" }
    if ($Bytes -lt 1048576) { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    if ($Bytes -lt 1073741824) { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    return ('{0:N2} GB' -f ($Bytes / 1073741824))
}

function Get-TreeSize([string] $LiteralPath) {
    $item = Get-Item -LiteralPath $LiteralPath -Force
    if (-not $item.PSIsContainer) { return [long]$item.Length }
    $sum = [long]0
    try {
        foreach ($f in Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force -File -ErrorAction SilentlyContinue) {
            $sum += [long]$f.Length
        }
    } catch { }
    return $sum
}

function Resolve-Targets([string[]] $Inputs) {
    $out = New-Object System.Collections.ArrayList
    foreach ($raw in $Inputs) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $candidate = $raw
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path (Get-Location).Path $candidate
        }
        if ($candidate -match '[\*\?]') {
            # 通配符先展开、后规范化：PS 5.1 的 [System.IO.Path]::GetFullPath 遇到 * 会直接抛
            # "Illegal characters in path"（老版本这里就是坏的），顺序必须反过来。
            $hits = @(Get-ChildItem -Path $candidate -Force -ErrorAction SilentlyContinue)
            if ($hits.Count -eq 0) { throw "没有匹配到任何文件：$raw" }
            foreach ($h in $hits) { [void]$out.Add($h.FullName) }
        } else {
            $candidate = [System.IO.Path]::GetFullPath($candidate)
            if (-not (Test-Path -LiteralPath $candidate)) { throw "路径不存在：$raw" }
            [void]$out.Add($candidate)
        }
    }
    return $out
}

function Get-TrashDestination([string] $FullPath, [string] $BatchName) {
    $trimmed = $FullPath.TrimEnd('\')
    if ($trimmed -match '^([A-Za-z]):\\(.*)$') {
        $rel = $Matches[1].ToUpper() + '\' + $Matches[2]
    } elseif ($trimmed.StartsWith('\\')) {
        $rel = 'UNC\' + $trimmed.Substring(2)
    } else {
        $rel = 'PATH\' + $trimmed.TrimStart('\')
    }
    return (Join-Path (Join-Path $TrashRoot $BatchName) $rel)
}

function Get-UniqueDestination([string] $Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) { return $Destination }
    $dir = Split-Path -Parent $Destination
    $name = Split-Path -Leaf $Destination
    $ext = [System.IO.Path]::GetExtension($name)
    $stem = $name
    if ($ext) { $stem = $name.Substring(0, $name.Length - $ext.Length) }
    for ($i = 2; $i -lt 1000; $i++) {
        $try = Join-Path $dir ("{0}__{1}{2}" -f $stem, $i, $ext)
        if (-not (Test-Path -LiteralPath $try)) { return $try }
    }
    throw "目标已存在且无法生成唯一名字：$Destination"
}

# ================================================================ 受保护路径闸门（方法 1 + 方法 3）
# 判定顺序：规范化路径 → 闸门一（永久拒绝，无开关）→ 工作区自身/上级（永久拒绝）→ 闸门二（工作区之外需确认码）。
# 一律"先判定后搬运"：只要有一件不过，整个调用一件都不搬。
function Test-IsUnder([string] $Candidate, [string] $Base) {
    # Candidate 是否等于 Base、或位于 Base 之下（大小写不敏感，按 \ 边界比较）。
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Base)) { return $false }
    $c = $Candidate.TrimEnd('\')
    $b = $Base.TrimEnd('\')
    if ($c -eq '' -or $b -eq '') { return $false }
    if ($c.Equals($b, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($b + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SafeFullPath([string] $RawPath) {
    # 统一规范化，挡住常见的"写法绕过"：\\?\ 前缀、段尾的点/空格（C:\Windows. == C:\Windows）、
    # 8.3 短名（PROGRA~1）、UNC。返回形如 C:\Windows\System32 的规范路径；不支持的写法直接抛错。
    $p = ([string]$RawPath).Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { throw '空路径' }
    if ($p -match '^\\\\\?\\(.+)$') { $p = $Matches[1] }
    elseif ($p -match '^\\\\\.\\(.+)$') { $p = $Matches[1] }
    if ($p.StartsWith('\\')) { throw '网络(UNC)路径不由本通道处理（跨机器的"搬运"其实是复制+删除源），请在资源管理器里自己操作' }
    if ($p -match '^[A-Za-z]:$') { return ($p.ToUpper() + '\') }
    $full = [System.IO.Path]::GetFullPath($p)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw ('不是本机盘符内的绝对路径：' + $RawPath) }
    $drive = $Matches[1].ToUpper()
    $segs = New-Object System.Collections.ArrayList
    foreach ($seg in $Matches[2].Split('\')) {
        if ($seg -eq '') { continue }
        $clean = $seg.TrimEnd('.', ' ')
        if ($clean -eq '') { throw ('路径段全是点/空格，不受支持：' + $RawPath) }
        if ($clean -match '~\d') { throw ('看起来是 8.3 短名（' + $clean + '），请写完整长路径') }
        [void]$segs.Add($clean)
    }
    if ($segs.Count -eq 0) { return ($drive + ':\') }
    return ($drive + ':\' + ($segs -join '\'))
}

function Get-ProtectedTable {
    # 永久禁搬前缀表：环境变量 + 每个盘符下的系统/引导目录 + 盘符根上的引导与交换文件 + DSH 家目录。
    $list = New-Object System.Collections.ArrayList
    $add = {
        param([string] $PathValue, [string] $Why)
        if ([string]::IsNullOrWhiteSpace($PathValue)) { return }
        try { $n = Get-SafeFullPath $PathValue } catch { return }
        [void]$list.Add([pscustomobject]@{ Path = $n; Why = $Why })
    }
    & $add $env:SystemRoot '系统目录（Windows）'
    & $add $env:ProgramFiles '程序安装目录'
    & $add ${env:ProgramFiles(x86)} '程序安装目录（32 位）'
    & $add $env:ProgramData '系统程序数据目录'
    & $add (Join-Path $env:USERPROFILE '.dsh') 'DSH 家目录（拦截插件、回收站工具、会话与工作区注册表）'
    $subs = @('Windows', 'Program Files', 'Program Files (x86)', 'Program Files (ARM)', 'ProgramData', 'Recovery', 'Boot', 'EFI', 'PerfLogs', 'MSOCache', 'Windows.old', '$Recycle.Bin', 'System Volume Information', 'Config.Msi', '$WinREAgent', 'Users\Default', 'Users\All Users')
    $bootFiles = @('bootmgr', 'BOOTNXT', 'boot.ini', 'ntldr', 'pagefile.sys', 'swapfile.sys', 'hiberfil.sys', 'DumpStack.log.tmp')
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drive.Name -notmatch '^[A-Za-z]$') { continue }
        $d = $drive.Name.ToUpper() + ':\'
        foreach ($sub in $subs) { & $add ($d + $sub) '系统/引导/程序目录' }
        foreach ($f in $bootFiles) { & $add ($d + $f) '引导/交换文件' }
    }
    return , $list
}

function Get-BlockReason([string] $NormPath) {
    # 闸门一：受保护路径。返回拒绝理由（'' = 通过）。
    if ($NormPath -match '^[A-Za-z]:\\?$') { return '盘符根目录（整块盘不允许搬运）' }
    foreach ($entry in $script:ProtectedTable) {
        if (Test-IsUnder $NormPath $entry.Path) { return ($entry.Why + '：' + $entry.Path) }
    }
    return ''
}

function Get-VolumeKey([string] $NormPath) {
    if ($NormPath -match '^([A-Za-z]):') { return ($Matches[1].ToUpper() + ':') }
    return ''
}

function Write-Alert([string] $Kind, [string] $Detail) {
    # 告警日志：写在 DSH 家目录（不在工作区里，清空「待删除」也抹不掉这段痕迹）。
    # 写不进去（受限沙箱 / 目录只读）只提示，绝不影响搬运与账本。
    $block = ('[{0}] {1}{2}{3}{2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Kind, "`r`n", $Detail)
    try {
        $dir = Split-Path -Parent $AlertLog
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::AppendAllText($AlertLog, $block, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Output ('（告警日志没写成，不影响本次操作：' + $_.Exception.Message + '）')
    }
}

function New-ConfirmCode {
    $bytes = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $hex = -join ($bytes | ForEach-Object { $_.ToString('X2') })
    return ($hex.Substring(0, 4) + '-' + $hex.Substring(4, 4))
}

function Get-TargetSetHash([string[]] $NormTargets, [string] $NormRoot) {
    # 确认码绑定"这次的目标集合 + 工作区"：目标一变，旧码就作废。
    $sorted = (@($NormTargets) | Sort-Object) -join '|'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($NormRoot + "`n" + $sorted))
    return ((-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 16))
}

function Save-PendingRequest([string] $Code, [string] $Hash, [string[]] $NormTargets, [int] $TtlMinutes) {
    $obj = [pscustomobject][ordered]@{
        code       = $Code
        targetHash = $Hash
        root       = $Root
        targets    = @($NormTargets)
        created    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        expires    = (Get-Date).AddMinutes($TtlMinutes).ToString('yyyy-MM-dd HH:mm:ss')
    }
    try {
        Write-Utf8 -LiteralPath $PendingFile -Text (($obj | ConvertTo-Json -Compress -Depth 5) + "`r`n")
        return $true
    } catch {
        return $false
    }
}

function Test-PendingCode([string] $Given, [string] $Hash) {
    # 通过返回 ''，否则返回拒绝理由。
    if (-not (Test-Path -LiteralPath $PendingFile)) { return '没有待确认的请求（先不带 -ConfirmCode 跑一次，脚本会打印确认码）' }
    $pend = $null
    try { $pend = ([System.IO.File]::ReadAllText($PendingFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return '待确认记录读不出来（文件损坏？）：再跑一次生成新确认码' }
    if ($null -eq $pend -or [string]::IsNullOrWhiteSpace([string]$pend.code)) { return '上次的确认码已经用掉或作废：再跑一次生成新确认码' }
    if (-not ([string]$pend.targetHash).Equals($Hash, [System.StringComparison]::OrdinalIgnoreCase)) { return '确认码对不上这次的目标集合：目标改了就必须重新预演、拿新码' }
    if (([string]$pend.code).Replace('-', '').ToUpper() -ne $Given.Replace('-', '').ToUpper()) { return '确认码不对' }
    [datetime]$exp = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$pend.expires, [ref]$exp)) { return '待确认记录里没有有效期限，作废：再跑一次' }
    if ((Get-Date) -gt $exp) { return ('确认码已过期（{0} 之后失效）：再跑一次生成新确认码' -f $pend.expires) }
    return ''
}

function Clear-PendingRequest {
    # 用掉即作废：不删除文件（本脚本从不删除任何东西），只把它改写成"没有有效码"。
    try {
        Write-Utf8 -LiteralPath $PendingFile -Text ('{"code":"","usedAt":"' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '"}' + "`r`n")
    } catch { }
}

function Write-ArchiveEntry([object] $Entry, [string] $Event) {
    # 永久流水：每搬一件、每还原一件都追写一行；失败不影响搬运本身（调用处不做回滚）。
    $copy = [pscustomobject][ordered]@{}
    foreach ($p in $Entry.PSObject.Properties) {
        $copy | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
    $copy | Add-Member -NotePropertyName 'event' -NotePropertyValue $Event -Force
    $shard = Get-ArchiveShardPath (Get-Date)
    Write-Utf8 -LiteralPath $shard -Text (($copy | ConvertTo-Json -Compress -Depth 5) + "`r`n") -Append
    # 同步一份人读版（同名 .txt）：首次带表头，之后只追加记录块。
    $human = Get-ArchiveShardTextPath $shard
    if (-not (Test-Path -LiteralPath $human)) {
        Write-Human -LiteralPath $human -Text ('搬运历史（人读版）· 机器读的是同名 .jsonl；本文件只追加，不随「待删除」被清空而消失。' + "`r`n`r`n")
    }
    Write-Human -LiteralPath $human -Text ((Format-HumanRecord $copy) + "`r`n") -Append
}

function Get-BatchDir([string] $BatchName) {
    # 批次文件夹可能已经被标注成「【空批次】<原名>」；能找着就用现成的，别新建一个空壳。
    $direct = Join-Path $TrashRoot $BatchName
    if (Test-Path -LiteralPath $direct) { return $direct }
    $renamed = Join-Path $TrashRoot ($EmptyTag + $BatchName)
    if (Test-Path -LiteralPath $renamed) { return $renamed }
    return $direct
}

function Test-BatchEmpty([string] $Dir) {
    # "空批次" = 除了 README.md 之外没有任何文件（目录树可以是空的）。
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) { if ($f.Name -ne 'README.md') { return $false } }
    return $true
}

function Rename-EmptyBatches {
    # 只改名、不删东西：给还原后剩下的空批次加「【空批次】」前缀，方便用户自己清理。
    # 注意：刚用 Move-Item 搬走东西的批次，Windows 可能还握着句柄 → Rename-Item 会瞬时失败，
    # 所以重试几次；仍然失败就**报出来**（绝不静默吞掉 —— "失败不静默"是硬性不变量）。
    $changed = New-Object System.Collections.ArrayList
    $blocked = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem -LiteralPath $TrashRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Name.StartsWith($EmptyTag)) { continue }
        if (-not (Test-BatchEmpty $d.FullName)) { continue }
        $newName = $EmptyTag + $d.Name
        if (Test-Path -LiteralPath (Join-Path $TrashRoot $newName)) { continue }
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

function Write-BatchReports([object] $Records) {
    foreach ($group in ($Records | Group-Object batch)) {
        $batchDir = Get-BatchDir $group.Name
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('# 待删除批次 ' + $group.Name)
        [void]$lines.Add('')
        [void]$lines.Add('本批次的东西只是被搬进来了，**没有被真正删除**。确认无用后，由用户手动删除本文件夹里的内容。')
        [void]$lines.Add('')
        foreach ($r in $group.Group) {
            [void]$lines.Add(('-------- 状态：' + (Get-Status $r) + ' --------'))
            [void]$lines.Add((Format-HumanRecord $r))
        }
        $restoreCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Root "' + $Root + '" -Restore -Batch ' + $group.Name
        [void]$lines.Add('还原（搬回原位）：`' + $restoreCmd + '`')
        [void]$lines.Add('')
        [void]$lines.Add('历史归档（按月分片、不随本批次被删而消失）：`' + (Get-ArchiveShardPath (Get-Date)) + '`')
        [void]$lines.Add('')
        Write-Utf8 -LiteralPath (Join-Path $batchDir 'README.md') -Text (($lines -join "`r`n") + "`r`n")
    }
}

# ---------------------------------------------------------------- -History
if ($History) {
    $files = Get-ArchiveShardFiles -AllShards:$All
    if ($files.Count -eq 0) {
        if ($All) { Write-Output "还没有历史归档：$ArchiveDir" }
        else { Write-Output ("当月还没有历史归档：{0}（-All 可看全部分片）" -f (Get-ArchiveShardPath (Get-Date))) }
        return
    }
    $rows = New-Object System.Collections.ArrayList
    $bad = 0
    foreach ($file in $files) {
        foreach ($line in [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { [void]$rows.Add(($line | ConvertFrom-Json)) } catch { $bad++ }
        }
    }
    if ($rows.Count -eq 0) { Write-Output ("历史归档为空：{0}" -f ($files -join ' ; ')); return }
    $total = $rows.Count
    $shown = $rows
    if ($Tail -gt 0 -and $total -gt $Tail) {
        $shown = @($rows[($total - $Tail)..($total - 1)])
    }
    $scope = '当月分片'
    if ($All) { $scope = '全部分片' }
    $shownText = ('全部 {0} 条' -f $total)
    if ($shown.Count -lt $total) { $shownText = ('最近 {0} 条（共 {1} 条）' -f $shown.Count, $total) }
    Write-Output ("搬运历史归档（{0}；{1}）：{2}" -f $scope, $shownText, ($files -join ' ; '))
    if ($bad -gt 0) { Write-Output ("注意：有 {0} 行无法解析、已跳过（账本不静默少行，请人工看一下分片文件）" -f $bad) }
    Write-Output ''
    Write-Output '| 时间 | 事件 | # | 原始路径 | 待删除路径 | 大小 | 用途 | 原因 |'
    Write-Output '|---|---|---|---|---|---|---|---|'
    foreach ($r in $shown) {
        Write-Output ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f $r.time, $r.event, $r.id, $r.originalPath, $r.trashPath, (Format-Size ([long]$r.sizeBytes)), $r.purpose, $r.reason)
    }
    if ($total -gt $shown.Count) {
        Write-Output ''
        Write-Output ("（只显示最近 {0} 条；-Tail <更大的数> 调整，-Tail 0 看全部）" -f $shown.Count)
    }
    return
}

# ---------------------------------------------------------------- -List
if ($List) {
    $records = Get-Manifest
    if ($records.Count -eq 0) { Write-Output "清单为空：$ManifestPath"; return }
    Write-Output ("待删除清单（共 {0} 条）：{1}" -f $records.Count, $ManifestPath)
    Write-Output ''
    Write-Output '| # | 时间 | 状态 | 原始路径 | 待删除路径 | 大小 | 用途 | 原因 |'
    Write-Output '|---|---|---|---|---|---|---|---|'
    foreach ($r in $records) {
        Write-Output ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f $r.id, $r.time, (Get-Status $r), $r.originalPath, $r.trashPath, (Format-Size ([long]$r.sizeBytes)), $r.purpose, $r.reason)
    }
    Write-Output ''
    Write-Output ("历史归档（按月分片、清空「待删除」也不丢）：{0} —— 用 -History 查看（-All 看全部分片）" -f $ArchiveDir)
    Write-Output ("清单（人读版）：{0}" -f $ManifestTextPath)
    return
}

# ---------------------------------------------------------------- -Restore
if ($Restore) {
    $records = Get-Manifest
    if ($records.Count -eq 0) { throw "清单为空，无法还原：$ManifestPath" }
    $targets = @()
    if (-not [string]::IsNullOrWhiteSpace($Record)) {
        $ids = $Record.Split(',') | ForEach-Object { $_.Trim() }
        $targets = @($records | Where-Object { $ids -contains ([string]$_.id) })
        if ($targets.Count -eq 0) { throw "清单里没有记录号：$Record" }
    } elseif (-not [string]::IsNullOrWhiteSpace($Batch)) {
        $targets = @($records | Where-Object { $_.batch -eq $Batch })
        if ($targets.Count -eq 0) { throw "清单里没有批次：$Batch" }
    } else {
        throw "请用 -Record <记录号> 或 -Batch <批次名> 指定要还原的内容（-List 可查看）"
    }
    $changed = $false
    foreach ($r in $targets) {
        $src = [string]$r.trashPath
        $dst = [string]$r.originalPath
        if (-not (Test-Path -LiteralPath $src)) { Write-Output ("跳过（待删除里已找不到）：{0}" -f $src); continue }
        if (Test-Path -LiteralPath $dst) { Write-Output ("跳过（原路径已被占用）：{0}" -f $dst); continue }
        $parent = Split-Path -Parent $dst
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Move-Item -LiteralPath $src -Destination $dst
        $r | Add-Member -NotePropertyName 'restored' -NotePropertyValue $true -Force
        $r | Add-Member -NotePropertyName 'restoredAt' -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -Force
        Write-ArchiveEntry $r 'restore'
        $changed = $true
        Write-Output ("已还原：{0}  ->  {1}" -f $src, $dst)
    }
    if ($changed) {
        Save-Manifest $records
        Write-ManifestSnapshot $records
        Write-Output ("清单已更新，记录已标记为「已还原」：{0}" -f $ManifestPath)
    }
    # 还原之后只剩空壳的批次文件夹：加「【空批次】」前缀做标注（只改名，里面的东西一个不动）。
    $emptyRenamed = Rename-EmptyBatches
    if ($emptyRenamed.Changed.Count -gt 0) {
        Write-Output ("已标注 {0} 个空批次文件夹（只改名、不删东西）：" -f $emptyRenamed.Changed.Count)
        foreach ($n in $emptyRenamed.Changed) { Write-Output ("  " + $EmptyTag + $n) }
        Write-Output "确认没用之后，由你自己删掉这些文件夹。"
    }
    if ($emptyRenamed.Blocked.Count -gt 0) {
        Write-Output ("注意：有 {0} 个空批次这次没能改名（多半是刚搬完东西被瞬时占用）—— 用 offline-restore.ps1 -MarkEmpty 再标一次即可：" -f $emptyRenamed.Blocked.Count)
        foreach ($n in $emptyRenamed.Blocked) { Write-Output ("    " + $n) }
    }
    return
}

# ---------------------------------------------------------------- -RepairManifest
if ($RepairManifest) {
    $records = Get-Manifest
    if ($records.Count -eq 0) { throw "清单为空或没有可解析的记录：$ManifestPath" }
    Save-Manifest $records
    Write-BatchReports $records
    Write-ManifestSnapshot $records
    # 归档的人读版：已有的不动（只追加的历史），缺的按 JSONL 原样补建。
    $built = 0
    $shards = Get-ArchiveShardFiles -AllShards
    foreach ($shard in $shards) {
        $txt = Get-ArchiveShardTextPath $shard
        if (Test-Path -LiteralPath $txt) { continue }
        $body = New-Object System.Collections.ArrayList
        [void]$body.Add('搬运历史（人读版）· 机器读的是同名 .jsonl；本文件只追加，不随「待删除」被清空而消失。')
        [void]$body.Add('')
        foreach ($line in [System.IO.File]::ReadAllLines($shard, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { [void]$body.Add((Format-HumanRecord ($line | ConvertFrom-Json))) } catch { }
        }
        Write-Human -LiteralPath $txt -Text (($body -join "`r`n") + "`r`n")
        $built++
    }
    Write-Output ("已重写清单 JSON、重建批次报告与人读版清单：{0} 条记录；补建人读版归档 {1} 个分片（已有分片不动）" -f $records.Count, $built)
    return
}

# ---------------------------------------------------------------- 正常搬运
if (-not $Path -or $Path.Count -eq 0) {
    throw "请给出要搬运的路径，例如：.\trash.ps1 -Path '.\a.log' -Purpose '旧日志' -Reason '无参考价值'"
}
if ([string]::IsNullOrWhiteSpace($Reason)) {
    throw "请用 -Reason 说明为什么要删除（会写进清单，便于事后人工确认）"
}
if ([string]::IsNullOrWhiteSpace($Batch)) {
    $Batch = Get-Date -Format 'yyyyMMdd-HHmmss'
}

$targets = Resolve-Targets $Path

# ---------------------------------------------------------------- 闸门（方法 1 / 方法 3）
$script:ProtectedTable = Get-ProtectedTable
$normRoot = ''
try { $normRoot = Get-SafeFullPath $Root } catch { throw ('「待删除」根目录写法不受支持：' + $_.Exception.Message + ' —— ' + $Root) }
$rootWhy = Get-BlockReason $normRoot
if ($rootWhy) { throw ('拒绝：-Root 落在受保护位置（' + $rootWhy + '）：' + $Root) }

$usedWildcard = $false
foreach ($raw in $Path) { if ([string]$raw -match '[\*\?]') { $usedWildcard = $true } }
if ($usedWildcard -and ($targets.Count -gt $MaxWildcard)) {
    throw ('通配符命中 ' + $targets.Count + ' 项，超过上限 ' + $MaxWildcard + '：请显式列出要搬的路径（-MaxWildcard 可调，但不建议调大）')
}

$targetsNorm = New-Object System.Collections.ArrayList   # 过闸门的目标
$blockedList = New-Object System.Collections.ArrayList   # 闸门一命中：永久拒绝
$outsideList = New-Object System.Collections.ArrayList   # 工作区之外：需要两段式确认
foreach ($src in $targets) {
    $n = ''
    try { $n = Get-SafeFullPath $src } catch {
        [void]$blockedList.Add(('路径写法不受支持：{0} —— {1}' -f $src, $_.Exception.Message))
        continue
    }
    $why = Get-BlockReason $n
    if ($why) { [void]$blockedList.Add(('受保护路径：{0}（{1}）' -f $src, $why)); continue }
    if (Test-IsUnder $normRoot $n) { [void]$blockedList.Add(('工作区自身/上级目录：{0}（搬走它会把「待删除」和账本一起埋掉）' -f $src)); continue }
    [void]$targetsNorm.Add([pscustomobject]@{ Original = $src; Norm = $n })
    if (-not (Test-IsUnder $n $normRoot)) { [void]$outsideList.Add($n) }
}

if ($blockedList.Count -gt 0) {
    Write-Alert '已拦截（受保护路径 / 工作区自身）' ("  工作区：{0}`r`n  结果：一件都没搬`r`n  命中：`r`n    {1}" -f $Root, ($blockedList -join "`r`n    "))
    throw ("拒绝搬运（受保护路径，永久生效、没有开关）：`r`n  " + ($blockedList -join "`r`n  ") + "`r`n`r`n盘符根、系统/引导/程序目录、DSH 家目录永远不由本通道处理。真要清理系统盘，请用 Windows 自带方式（磁盘清理 / DISM / 应用卸载），或由用户自己在资源管理器里动手。")
}

if ($outsideList.Count -gt 0) {
    $trashVolume = Get-VolumeKey $normRoot
    $crossVolume = @($targetsNorm | Where-Object { (Get-VolumeKey $_.Norm) -ne $trashVolume })
    $planText = (@($targetsNorm) | ForEach-Object { '  - ' + $_.Original }) -join "`r`n"
    if (-not $AllowOutsideRoot) {
        Write-Alert '已拦截（工作区之外，缺 -AllowOutsideRoot）' ("  工作区：{0}`r`n  结果：一件都没搬`r`n  目标：`r`n{1}" -f $Root, $planText)
        throw ("有 {0} 个目标在工作区之外，本通道默认只服务工作区：`r`n{1}`r`n`r`n确实要搬工作区之外的东西：加 -AllowOutsideRoot 重跑 —— 脚本会先只预演、打印一次性确认码，拿到确认码后再加 -ConfirmCode 才会真正搬。" -f $outsideList.Count, $planText)
    }
    $targetHash = Get-TargetSetHash @($targetsNorm | ForEach-Object { $_.Norm }) $normRoot
    if ([string]::IsNullOrWhiteSpace($ConfirmCode)) {
        $code = New-ConfirmCode
        $saved = Save-PendingRequest $code $targetHash @($targetsNorm | ForEach-Object { $_.Norm }) $ConfirmTtlMinutes
        Write-Alert '等待确认码（工作区之外）' ("  工作区：{0}`r`n  结果：只预演，未搬运`r`n  目标：`r`n{1}" -f $Root, $planText)
        Write-Output ('有 {0} 个目标在工作区之外 —— 本次只预演，什么都没搬：' -f $outsideList.Count)
        Write-Output ''
        foreach ($t in $targetsNorm) {
            $tag = ''
            if ((Get-VolumeKey $t.Norm) -ne $trashVolume) { $tag = '   [跨卷：搬运 = 复制 + 删除源文件]' }
            Write-Output ('  {0}  ->  {1}{2}' -f $t.Original, (Get-TrashDestination $t.Original $Batch), $tag)
        }
        Write-Output ''
        if ($crossVolume.Count -gt 0) {
            Write-Output ('注意：其中 {0} 个目标与「待删除」不在同一个卷，Move-Item 会先复制再删掉源文件 —— 中途失败可能两头都不完整。' -f $crossVolume.Count)
            Write-Output ''
        }
        Write-Output ('确认码：{0}   （{1} 分钟内有效，且只对这次的目标集合有效）' -f $code, $ConfirmTtlMinutes)
        if (-not $saved) { Write-Output ('（确认码没能写进 ' + $PendingFile + '：受限沙箱或目录不可写 —— 这种情况下稍后带 -ConfirmCode 也会被拒绝，请在普通 PowerShell 里操作）') }
        Write-Output ('请先把上面的目标给用户确认；用户同意后，用同一条命令加 -ConfirmCode ''{0}'' 重跑才会真正搬运。' -f $code)
        Write-Output ('告警日志：{0}' -f $AlertLog)
        return
    }
    $codeError = Test-PendingCode $ConfirmCode $targetHash
    if ($codeError) {
        Write-Alert '已拦截（确认码不对/过期）' ("  工作区：{0}`r`n  结果：一件都没搬`r`n  原因：{1}`r`n  目标：`r`n{2}" -f $Root, $codeError, $planText)
        throw ('确认不通过：' + $codeError)
    }
    Clear-PendingRequest
    $script:outsideConfirmed = $true
    $script:outsidePlanText = $planText
}

# -DryRun 只描述将要发生什么，连「待删除」根目录都不创建；闸门不过时同样什么都不建。
if (-not $DryRun -and -not (Test-Path -LiteralPath $TrashRoot)) {
    New-Item -ItemType Directory -Force -Path $TrashRoot | Out-Null
}

$records = Get-Manifest
$nextId = 1
foreach ($r in $records) {
    $rid = 0
    if ([int]::TryParse([string]$r.id, [ref]$rid) -and $rid -ge $nextId) { $nextId = $rid + 1 }
}

$moved = New-Object System.Collections.ArrayList
foreach ($t in $targetsNorm) {
    $src = $t.Original
    $trimmed = $src.TrimEnd('\')
    if ($trimmed -eq $TrashRoot -or $trimmed.StartsWith($TrashRoot + '\')) {
        Write-Output ("跳过（已经在「待删除」里，只能由用户手动处理）：{0}" -f $src)
        continue
    }
    $item = Get-Item -LiteralPath $src -Force
    $kind = 'file'
    if ($item.PSIsContainer) { $kind = 'directory' }
    $dest = Get-TrashDestination $src $Batch
    $dest = Get-UniqueDestination $dest
    $size = 0
    try { $size = Get-TreeSize $src } catch { $size = 0 }
    $hash = ''
    if ($kind -eq 'file' -and $size -le 67108864) {
        try { $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash } catch { $hash = '' }
    }

    if ($DryRun) {
        Write-Output ("[DryRun] {0}  ->  {1}  ({2}, {3})" -f $src, $dest, $kind, (Format-Size $size))
        continue
    }

    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Move-Item -LiteralPath $src -Destination $dest
    $ok = (Test-Path -LiteralPath $dest) -and (-not (Test-Path -LiteralPath $src))

    # 注意：变量名不能叫 $record —— PowerShell 变量名不区分大小写，会和 [string]$Record 参数
    # 撞成同一个变量，赋值时被强制转成 "@{...}" 字符串（这个坑踩过一次）。
    $entry = [pscustomobject][ordered]@{
        id           = $nextId
        time         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        batch        = $Batch
        originalPath = $src
        trashPath    = $dest
        kind         = $kind
        sizeBytes    = $size
        sha256       = $hash
        purpose      = $Purpose
        reason       = $Reason
        root         = $Root
        verified     = $ok
    }
    Write-Utf8 -LiteralPath $ManifestPath -Text (($entry | ConvertTo-Json -Compress -Depth 5) + "`r`n") -Append
    [void]$moved.Add($entry)
    Write-ArchiveEntry $entry 'trash'
    $nextId++
}

if ($DryRun) { return }

if ($script:outsideConfirmed) {
    # 真正搬完才算"已执行"，写进告警日志留痕（体检会把这类记录报成异常）。
    $doneText = (@($moved) | ForEach-Object { '  - ' + $_.originalPath + '  ->  ' + $_.trashPath }) -join "`r`n"
    if ([string]::IsNullOrWhiteSpace($doneText)) { $doneText = '  （没有任何东西被搬运）' }
    Write-Alert '已执行（工作区之外，带确认码）' ("  工作区：{0}`r`n  结果：搬运 {1} 件工作区之外的路径`r`n  明细：`r`n{2}" -f $Root, $moved.Count, $doneText)
}

# ---------------------------------------------------------------- 人读版清单快照（在押全量）
Write-ManifestSnapshot (Get-Manifest)

# ---------------------------------------------------------------- 批次报告
Write-BatchReports $moved

# ---------------------------------------------------------------- 控制台输出
if ($moved.Count -eq 0) { Write-Output '没有任何东西被搬运。'; return }
Write-Output ("已搬入「待删除」（未真正删除），批次 {0}：" -f $Batch)
Write-Output ("「待删除」根目录：{0}（不是这里，下次带 -Root）" -f $TrashRoot)
Write-Output ''
Write-Output '| # | 原始路径 | 待删除路径 | 类型 | 大小 | 用途 | 删除原因 |'
Write-Output '|---|---|---|---|---|---|---|'
foreach ($r in $moved) {
    Write-Output ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $r.id, $r.originalPath, $r.trashPath, $r.kind, (Format-Size ([long]$r.sizeBytes)), $r.purpose, $r.reason)
}
Write-Output ''
Write-Output ("清单：{0}" -f $ManifestPath)
Write-Output ("清单（人读版，记事本直接看）：{0}" -f $ManifestTextPath)
Write-Output ("批次报告：{0}" -f (Join-Path (Join-Path $TrashRoot $Batch) 'README.md'))
Write-Output ("历史归档：{0}（人读版是同名 .txt）—— 用 -History 查看" -f (Get-ArchiveShardPath (Get-Date)))

if ($script:outsideConfirmed) {
    Write-Output ("注意：本次搬运包含工作区之外的路径，已记入告警日志：{0}" -f $AlertLog)
}