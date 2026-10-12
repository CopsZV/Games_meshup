# Closes BeamNG (and a crash-report dialog left by a crash). Only for test runs: unsaved game
# state is lost.
. "$PSScriptRoot\common.ps1"
$p = Get-BngProcess
if ($p) {
    $p | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    if (-not ($p | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue)) { }
    $p = Get-BngProcess
    if ($p) { $p | Stop-Process -Force; Write-Ok 'BeamNG killed (did not close within 15 s)' } else { Write-Ok 'BeamNG closed' }
} else {
    Write-Ok 'BeamNG is not running'
}
Get-Process -Name CrashSender -ErrorAction SilentlyContinue | Stop-Process -Force
