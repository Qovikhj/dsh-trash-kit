<#
  Install the workspace-level delete rule into a workspace root.

  Copies AGENTS.workspace.md -> <Workspace>\AGENTS.md

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\templates\apply-workspace-rules.ps1" -Workspace 'D:\proj'
    ... -Workspace 'D:\proj' -Force     # back up an existing AGENTS.md, then overwrite

  Options:
    -Workspace <path>   workspace root that should receive AGENTS.md (required)
    -Force              allow overwriting; the existing file is backed up first
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Workspace,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$Source = Join-Path $PSScriptRoot 'AGENTS.workspace.md'
if (-not (Test-Path -LiteralPath $Source)) { throw "template not found: $Source" }

$root = [System.IO.Path]::GetFullPath($Workspace)
if (-not (Test-Path -LiteralPath $root)) { throw "workspace does not exist: $root" }
if (-not (Get-Item -LiteralPath $root).PSIsContainer) { throw "not a directory: $root" }

$Target = Join-Path $root 'AGENTS.md'
if (Test-Path -LiteralPath $Target) {
    if (-not $Force) {
        throw "AGENTS.md already exists here; re-run with -Force to back it up and overwrite: $Target"
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = $Target + '.bak-' + $stamp
    Copy-Item -LiteralPath $Target -Destination $backup -Force
    Write-Output "existing file backed up -> $backup"
}

Copy-Item -LiteralPath $Source -Destination $Target -Force
Write-Output "installed -> $Target"