<#
  Idempotent installer for the dsh-trash-guard plugin (delete guard).

  Copy the plugin into a DSH profile's node_modules and make sure the profile's
  cordis.patch.yml carries the mount row. Safe to re-run: it refreshes the files
  and only appends the row when it is missing (backing the patch up first).

  Run it after a DSH plugin update if the guard stops working:
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\dsh-trash-guard\install.ps1"

  Options:
    -ProfileName <name>   DSH profile to install into (default: desktop)
    -DryRun               print what would happen, change nothing
#>
param(
    [string] $ProfileName = 'desktop',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$Source = $PSScriptRoot
$BackupDir = Join-Path $env:USERPROFILE '.dsh\tools\backup'
$ProfileDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $ProfileName)
if (-not (Test-Path -LiteralPath $ProfileDir)) { throw "profile not found: $ProfileDir" }
$Target = Join-Path $ProfileDir 'node_modules\dsh-trash-guard'
$Patch = Join-Path $ProfileDir 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $Patch)) { throw "patch file not found: $Patch" }

if ($DryRun) {
    Write-Output "would refresh plugin files -> $Target"
    Write-Output "would ensure mount row    -> $Patch"
    return
}

New-Item -ItemType Directory -Force -Path (Join-Path $Target 'lib') | Out-Null
Copy-Item -LiteralPath (Join-Path $Source 'package.json') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Source 'lib\index.js') -Destination (Join-Path $Target 'lib') -Force
Copy-Item -LiteralPath (Join-Path $Source 'README.md') -Destination $Target -Force

$current = [System.IO.File]::ReadAllText($Patch, [System.Text.Encoding]::UTF8)
if ($current -match 'dsh-trash-guard') {
    Write-Output 'plugin files refreshed; mount row already present'
} else {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $backup = Join-Path $BackupDir ("cordis.patch.$ProfileName.$stamp.yml")
    Copy-Item -LiteralPath $Patch -Destination $backup -Force
    $snippet = [System.IO.File]::ReadAllText((Join-Path $Source 'install-snippet.yml'), [System.Text.Encoding]::UTF8)
    [System.IO.File]::AppendAllText($Patch, "`r`n" + $snippet + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "mount row appended; patch backed up to $backup"
}

Get-ChildItem -Recurse -File $Target | ForEach-Object { Write-Output ($_.FullName + '  ' + $_.Length) }