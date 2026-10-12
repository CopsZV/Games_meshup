# One click: BeamNG.drive (with BeamGmod's crossover mod) + the BeamGMod relay + Garry's Mod.
# play.bat runs this.
#
#   play.bat                    # asks which mode
#   play.bat flat               # BeamNG cars on a flat GMod map (gm_flatgrass)
#   play.bat terrain            # BeamNG cars on real GMod terrain (gm_construct, sampled into BeamNG)
#   play.bat map                # BeamNG cars on real terrain of ANY map (asks for the map name)
#   play.bat map -Map rp_downtown_v4c_v2
#   play.bat flat -Car etk800 -Config 854_base
#   play.bat terrain -Map gm_fork
#   play.bat flat -CloseBeamNG  # also close BeamNG when you quit Garry's Mod
#
# BeamNG runs on BeamGmod's own user folder (bng-userfolder), so your normal BeamNG mods and
# settings are never touched. Keep this file ASCII: Windows PowerShell 5.1 reads it as ANSI.
param(
    [Parameter(Position = 0)][ValidateSet('', 'flat', 'terrain', 'map')][string]$Mode = '',
    [string]$Car = 'pickup',
    [string]$Config = '',
    [string]$Map = '',
    [int]$Port = 47020,
    [switch]$CloseBeamNG
)

$Here = $PSScriptRoot
$ErrorActionPreference = 'Stop'

function Find-Dir([string]$EnvName, [string]$Pattern, [string]$Needs) {
    $e = [Environment]::GetEnvironmentVariable($EnvName)
    if ($e -and (Test-Path (Join-Path $e $Needs))) { return $e }
    $parent = Split-Path -Parent $Here
    foreach ($d in (Get-ChildItem -Path $parent -Directory -Filter $Pattern -ErrorAction SilentlyContinue)) {
        if (Test-Path (Join-Path $d.FullName $Needs)) { return $d.FullName }
    }
    return $null
}


$BeamGMod = $PSScriptRoot

# BeamGmod files are now expected inside BeamGMod\beamng\...
$BeamGmod = $BeamGMod

$BngScripts = Join-Path $BeamGmod 'beamng\scripts'
if (-not (Test-Path (Join-Path $BngScripts 'common.ps1'))) {
    Write-Host 'BeamNG scripts were not found inside BeamGMod\beamng\scripts.' -ForegroundColor Yellow
    exit 1
}

$Gmod = Find-Dir 'GMOD_DIR' 'GarrysMod' 'gmod.exe'
if (-not $Gmod) {
    Write-Host "Garry's Mod was not found next to this folder (steamapps\common\GarrysMod)." -ForegroundColor Yellow
    Write-Host 'Set GMOD_DIR to the folder with gmod.exe, then run play.bat again.'
    exit 1
}

. "$BngScripts\common.ps1"

# Keep BeamNG's user profile outside Program Files (x86).
# The profile is stored in the user's LocalAppData folder.
if (-not $env:BNG_USERPATH) {
    $userRoot = Join-Path $env:LOCALAPPDATA 'BeamGMod\bng-userfolder'

    if (-not (Test-Path (Join-Path $userRoot 'current'))) {
        $oldCurrent = Join-Path $BeamGMod 'beamng\bng-userfolder\current'

        if (Test-Path $oldCurrent) {
            Write-Step "Copying BeamNG profile to $userRoot (once)"
            & robocopy $oldCurrent (Join-Path $userRoot 'current') /E /XD temp screenshots /NFL /NDL /NJH /NJS /NP | Out-Null
        }
    }

    $env:BNG_USERPATH = $userRoot
}



$addon = Join-Path $Gmod 'garrysmod\addons\beamgmod\lua\autorun\beamgmod.lua'
if (-not (Test-Path $addon)) {
    Write-Warn2 "The GMod addon is missing: $addon"
    exit 1
}

Write-Host ''
Write-Host '  Garry''s Mod x BeamNG.drive' -ForegroundColor White
Write-Host '  ---------------------------' -ForegroundColor DarkGray
Write-Host ''

# 1. BeamNG.drive
try {
    $install = Get-BeamngInstall
    Write-Ok "BeamNG.drive found: $install"
} catch {
    Write-Warn2 'BeamNG.drive was not found in your Steam libraries. Set BNG_INSTALL to the folder with BeamNG.drive.exe.'
    exit 1
}

# 2. Java 21
try {
    $java = Get-Java21Home
    Write-Ok "Java 21 found: $java"
} catch {
    Write-Warn2 'Java 21 (a JDK) is needed for the relay. Install Temurin 21 or set BNG_JAVA_HOME.'
    exit 1
}
$javaExe = Join-Path $java 'bin\java.exe'

# 3. Mode
$AskMap = $false
if ($Mode -eq 'map') { $Mode = 'terrain'; if (-not $Map) { $AskMap = $true } }
if (-not $Mode) {
    Write-Host ''
    Write-Host '  1  BeamNG cars on a flat map          (gm_flatgrass, start here)'
    Write-Host '  2  BeamNG cars on real map terrain    (gm_construct; the map is copied into BeamNG)'
    Write-Host '  3  BeamNG cars on real map terrain    (any map; the map is copied into BeamNG)'
    Write-Host ''
    $pick = Read-Host '  Pick 1, 2 or 3'
    if ($pick -eq '3') { $Mode = 'terrain'; $AskMap = $true }
    elseif ($pick -eq '2') { $Mode = 'terrain' }
    else { $Mode = 'flat' }
}
if ($AskMap) {
    $mapsDir = Join-Path $Gmod 'garrysmod\maps'
    $names = @()
    if (Test-Path $mapsDir) {
        $names = @(Get-ChildItem -Path $mapsDir -Filter '*.bsp' -File | ForEach-Object { $_.BaseName } | Sort-Object)
    }
    Write-Host ''
    if ($names.Count -gt 0) {
        Write-Host '  Installed maps:' -ForegroundColor DarkGray
        for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ('   {0,3}  {1}' -f ($i + 1), $names[$i]) }
        Write-Host ''
    }
    Write-Host '  Type a map name (workshop maps too) or a number from the list.'
    $typed = (Read-Host '  Map [gm_construct]').Trim()
    if (-not $typed) { $typed = 'gm_construct' }
    if ($typed -match '^\d{1,4}$' -and [int]$typed -ge 1 -and [int]$typed -le $names.Count) { $typed = $names[[int]$typed - 1] }
    $typed = $typed -replace '\.bsp$', ''
    if ($typed -notmatch '^[A-Za-z0-9_\-\.]+$') { Write-Warn2 "Invalid map name: $typed"; exit 1 }
    $Map = $typed
}
if (-not $Map) { $Map = if ($Mode -eq 'terrain') { 'gm_construct' } else { 'gm_flatgrass' } }
Write-Step "Mode: $Mode, map: $Map, car: $Car"

if (Get-Process -Name 'gmod' -ErrorAction SilentlyContinue) {
    Write-Warn2 'Garry''s Mod is already running. Close it and run play.bat again.'
    exit 1
}

# 4. Files the addon reads on startup
$dataDir = Join-Path $Gmod 'garrysmod\data\beamgmod'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $dataDir 'mode.txt'), $Mode, $utf8)
[IO.File]::WriteAllText((Join-Path $dataDir 'autospawn.txt'), ($Car + ' ' + $Config).Trim(), $utf8)

# car pictures for the GMod menu (BeamNG's own previews)
try {
    $thumbSrc = Join-Path $env:BNG_USERPATH 'current\temp\mccross\thumbs'
    if (Test-Path $thumbSrc) {
        & robocopy $thumbSrc (Join-Path $dataDir 'thumbs') *.jpg *.png /NFL /NDL /NJH /NJS /NP | Out-Null
    }
} catch { }

# 5. BeamNG, unless it is already up with the mod
$Level = 'smallgrid'
$welcome = Get-BngWelcome -Port $Port -TimeoutMs 1500
if ($welcome) {
    if ($welcome.level -ne $Level) {
        Write-Warn2 "BeamNG is running on '$($welcome.level)', and this needs '$Level'. Close BeamNG and run play.bat again."
        exit 1
    }
    Write-Ok "BeamNG is already running with the crossover mod (level $($welcome.level))"
} elseif (Get-BngProcess) {
    Write-Warn2 'BeamNG is running without the crossover mod. Close it and run play.bat again.'
    exit 1
} else {
    Write-Step 'Starting BeamNG (the first start with a fresh profile can take a few minutes)'
    & "$BngScripts\run-beamng.ps1" -Level $Level -Port $Port -Wait -WaitSeconds 600
}

# 6. The relay (UDP <-> files). Stop any older one first, two would fight over the files.
Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*BeamGmodRelay*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$relaySrc = Join-Path $Here 'relay\BeamGmodRelay.java'
$relayLog = Join-Path $Here 'relay.log'
Write-Step 'Starting the relay'
$relay = Start-Process -FilePath $javaExe `
    -ArgumentList @(('"{0}"' -f $relaySrc), ('"{0}"' -f $dataDir), "$Port") `
    -WindowStyle Hidden -RedirectStandardOutput $relayLog -RedirectStandardError "$relayLog.err" -PassThru

$statusFile = Join-Path $dataDir 'in\status.json'
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    if ($relay.HasExited) { break }
    if (Test-Path $statusFile) {
        try {
            $st = Get-Content -Raw -Path $statusFile | ConvertFrom-Json
            if ($st.connected -eq $true) { $ok = $true; break }
        } catch { }
    }
}
if ($ok) {
    Write-Ok 'relay is connected to BeamNG'
} else {
    Write-Warn2 "The relay did not connect to BeamNG. Log: $relayLog (and $relayLog.err)"
    if ($relay.HasExited) { Get-Content "$relayLog.err" -ErrorAction SilentlyContinue | Select-Object -First 15 }
    try { Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue } catch { }
    exit 1
}

# 7. Garry's Mod
$gmodExe = Join-Path $Gmod 'gmod.exe'
$gArgs = @('-game', 'garrysmod', '-condebug', '-console', '+gamemode', 'sandbox', '+maxplayers', '1', '+map', $Map)
Write-Step "Starting Garry's Mod: $($gArgs -join ' ')"
try {
    if (Get-Process -Name 'gmod' -ErrorAction SilentlyContinue) {
        Write-Warn2 'Garry''s Mod is already open, so it is not started again. If it was open before the relay started, in the game console run: bg_restart'
    } else {
        [void](Start-Process -FilePath $gmodExe -ArgumentList $gArgs -WorkingDirectory $Gmod -PassThru)
    }
    $seen = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if (Get-Process -Name 'gmod' -ErrorAction SilentlyContinue) { $seen = $true; break }
    }
    if (-not $seen) { Write-Warn2 'Garry''s Mod did not start (is Steam running?).' }
    else {
        Write-Ok 'Garry''s Mod is running. In the game: wait for the car, then drive. Console: bg_help'
        while (Get-Process -Name 'gmod' -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }
    }
} finally {
    # tell the relay to say goodbye to BeamNG, then make sure it is gone
    try {
        [IO.File]::WriteAllText((Join-Path $dataDir 'out\999999999.json'), '{"t":"@quit"}', $utf8)
    } catch { }
    Start-Sleep -Milliseconds 1200
    try { Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue } catch { }
    if ($CloseBeamNG) {
        Get-Process -Name 'BeamNG.drive.x64', 'BeamNG.drive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok 'BeamNG closed.'
    } else {
        Write-Ok 'Garry''s Mod closed. BeamNG is still running: run play.bat again to jump back in (or use -CloseBeamNG).'
    }
}
