# Installs (or removes) the BeamNG side of the crossover as an unpacked mod in a BeamNG user folder.
#
#   scripts\install-beamng-mod.ps1                 # into the dedicated test user folder (default)
#   scripts\install-beamng-mod.ps1 -Player         # into your normal BeamNG user folder
#   scripts\install-beamng-mod.ps1 -Remove [-Player]
#
# Nothing in the BeamNG install folder is touched. The mod is a plain copy (robocopy /MIR) because
# the user folders on this PC live on exFAT, where directory junctions can't be created.
param(
    [switch]$Player,
    [switch]$Remove
)
. "$PSScriptRoot\common.ps1"

$userPath = if ($Player) { Get-BeamngDefaultUserPath } else { Get-BeamngUserPath }
if (-not $userPath) { throw 'BeamNG user folder not found' }
$dest = Join-Path $userPath 'mods\unpacked\mccrossover'
$src = Join-Path $BeamngRoot 'beamng-mod'

if ($Remove) {
    if (Test-Path $dest) {
        Remove-Item -Recurse -Force $dest
        Write-Ok "removed $dest"
    } else {
        Write-Ok "not installed in $userPath"
    }
    return
}

Write-Step "Installing BeamNG mod into $dest"
New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
# /MIR mirrors (deletes stale files in dest), /NJH /NJS /NP keep output short.
robocopy $src $dest /MIR /NJH /NJS /NP /NFL /NDL | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
$global:LASTEXITCODE = 0
$files = (Get-ChildItem $dest -Recurse -File).Count
Write-Ok "$files files installed (BeamNG $(Get-BeamngVersion), user folder $userPath)"
