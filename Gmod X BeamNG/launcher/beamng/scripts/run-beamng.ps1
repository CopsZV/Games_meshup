# Installs the crossover mod and starts BeamNG.drive straight into a level.
#
#   scripts\run-beamng.ps1                          # smallgrid, pickup, dedicated test user folder
#   scripts\run-beamng.ps1 -Level gridmap_v2 -Vehicle etk800
#   scripts\run-beamng.ps1 -Gfx dx11                # force the Direct3D 11 renderer (compositor work)
#   scripts\run-beamng.ps1 -Player                  # use your normal user folder and mods instead
#   scripts\run-beamng.ps1 -Wait                    # block until the extension logs "waiting for bridge"
#
# Steam must be able to start: BeamNG checks ownership through it.
# Never pass BeamNG's -windowed flag: in 0.39.4 it calls a missing global (parseArgs.lua:58,
# setFullScreen) and the game crashes at startup. Window mode is set in the test folder's
# settings.json instead (seeded on first run).
param(
    [string]$Level = 'smallgrid',
    [string]$Vehicle = 'pickup',
    [string]$Gfx = '',
    [int]$Port = 47020,
    [switch]$Player,
    [switch]$Wait,
    [int]$WaitSeconds = 240
)
. "$PSScriptRoot\common.ps1"

if (Get-BngProcess) { throw 'BeamNG is already running. Close it first (or use scripts\logs.ps1 to watch it).' }

$install = Get-BeamngInstall
$userPath = if ($Player) { Get-BeamngDefaultUserPath } else { Get-BeamngUserPath }
& "$PSScriptRoot\install-beamng-mod.ps1" -Player:$Player

$bngArgs = @('-level', $Level)
if ($Vehicle) { $bngArgs += @('-vehicle', $Vehicle) }
if (-not $Player) {
    # Start-Process joins the arguments with spaces, so a path with spaces would be split. Quoting it
    # does not work either: BeamNG's launcher hands it on to the game, which then stops with "Failed to
    # create user directory" (0x03000004). So the game gets a path without spaces (8.3 short form).
    $ur = Get-BeamngUserRoot
    if ($ur -match '\s') {
        try {
            New-Item -ItemType Directory -Force $ur | Out-Null
            $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($ur).ShortPath
            if ($short -and $short -notmatch '\s') { $ur = $short }
        } catch { }
    }
    if ($ur -match '\s') { $ur = '"' + $ur + '"' }
    $bngArgs += @('-userpath', $ur)
    # Test folder only: a window that keeps running at full speed in the background, and the
    # privacy-preserving answers to the first-run "Enable online features?" wizard so it doesn't
    # cover the game (settings/defaults.json: onlineFeatures/telemetry default to "ask").
    Set-BngSettings (Join-Path $userPath 'settings\settings.json') @{ GraphicDisplayModes = 'Window'; fpsLimitBackgroundEnabled = $false } -OnlyIfMissing
    Set-BngSettings (Join-Path $userPath 'settings\cloud\settings.json') @{ onlineFeatures = 'disable'; telemetry = 'disable' }
    # BeamNG mutes itself when it loses focus (settings/defaults.json: AudioMuteOnWindowLoseFocus),
    # and Minecraft has the focus in both directions, so the cars would be silent.
    Set-BngSettings (Join-Path $userPath 'settings\settings.json') @{ AudioMuteOnWindowLoseFocus = $false }
}
if ($Gfx) { $bngArgs += @('-gfx', $Gfx) }
if ($Port -ne 47020) { $bngArgs += @('-mccrossport', "$Port") }

Write-Step "Starting BeamNG $(Get-BeamngVersion): $($bngArgs -join ' ')"
$p = Start-Process -FilePath (Join-Path $install 'BeamNG.drive.exe') -ArgumentList $bngArgs -WorkingDirectory $install -PassThru
Write-Ok "launcher pid $($p.Id); user folder $userPath"

if ($Wait) {
    # Asks the extension itself over UDP: beamng.log reaches the disk minutes late and, right after
    # launch, still holds the previous run's "waiting for bridge" line.
    $log = Join-Path $userPath 'beamng.log'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    Write-Step "Waiting for the crossover extension and level $Level (up to $WaitSeconds s)"
    $answered = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1000
        $w = Get-BngWelcome -Port $Port
        if ($w) {
            if (-not $answered) { Write-Ok "extension is up (BeamNG $($w.bngVersion))"; $answered = $true }
            if ($w.ready -eq $true -and $w.level -eq $Level) {
                Write-Ok "level $Level is loaded"
                return
            }
        }
        # The launcher stub exits once the game process (or Steam) has taken over; only give up
        # when nothing BeamNG-related has been running for a while.
        if (-not (Get-BngProcess) -and $p.HasExited -and ((Get-Date) - $p.StartTime).TotalSeconds -gt 60) {
            throw 'BeamNG is not running 60 s after launch; see scripts\logs.ps1'
        }
    }
    throw "BeamNG did not report level '$Level' as loaded on port $Port within $WaitSeconds s; see $log"
}
