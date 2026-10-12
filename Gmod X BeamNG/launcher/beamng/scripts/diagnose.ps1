# One-shot crossover diagnostics: dashboard for both games plus a PASS/FAIL realtime verdict.
#   scripts\diagnose.ps1 [-Seconds 5]
param([double]$Seconds = 5)
. "$PSScriptRoot\common.ps1"
Write-Step "BeamNG $(Get-BeamngVersion) at $(Get-BeamngInstall); BeamNG running: $([bool](Get-BngProcess))"
python (Join-Path $BeamngRoot 'bridge\diagnose.py') $Seconds
exit $LASTEXITCODE
