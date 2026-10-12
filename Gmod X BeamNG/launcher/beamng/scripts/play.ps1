# One click: checks what's needed, starts BeamNG.drive with the crossover mod, then Minecraft.
# play.bat in the repo's root runs this. Everything the other scripts do, in the right order:
#
#   play.bat                       # asks which mode
#   play.bat host                  # BeamNG cars in a flat Minecraft world
#   play.bat terrain               # BeamNG cars on a normal Minecraft world ("BeamNG Terrain")
#   play.bat terrain -World name   # ...on a save of your own in beamng\minecraft\run\saves
#   play.bat bridge                # Minecraft inside BeamNG (the overlay direction)
#
# BeamNG runs on its own user folder (bng-userfolder in the repo), so your normal BeamNG mods and
# settings are never touched. Keep this file ASCII: Windows PowerShell 5.1 reads it as ANSI.
param(
    [Parameter(Position = 0)][ValidateSet('', 'host', 'terrain', 'bridge')][string]$Mode = '',
    [string]$World = '',
    [string]$Level = 'smallgrid',
    [switch]$NoShaderMods,
    [switch]$NoControllerMods
)
. "$PSScriptRoot\common.ps1"

function Ask([string]$Question) {
    $a = Read-Host "$Question [Y/n]"
    return (-not $a) -or ($a -match '^(y|yes)$')
}

Write-Host ''
Write-Host '  Minecraft x BeamNG.drive' -ForegroundColor White
Write-Host '  ------------------------' -ForegroundColor DarkGray
Write-Host ''

# 1. BeamNG.drive (from Steam)
try {
    $install = Get-BeamngInstall
    Write-Ok "BeamNG.drive found: $install"
} catch {
    Write-Warn2 'BeamNG.drive was not found in your Steam libraries.'
    Write-Warn2 'Install it from Steam, or set BNG_INSTALL to the folder with BeamNG.drive.exe, then run play.bat again.'
    exit 1
}

# 2. Java 21 (Gradle builds the mod and runs Minecraft on it)
try {
    $java = Get-Java21Home
    Write-Ok "Java 21 found: $java"
} catch {
    Write-Warn2 'Java 21 (a JDK) is needed to build the mod and run Minecraft.'
    if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Ask '    Install Eclipse Temurin 21 now with winget?')) {
        winget install --id EclipseAdoptium.Temurin.21.JDK -e --accept-package-agreements --accept-source-agreements
        try {
            $java = Get-Java21Home
            Write-Ok "Java 21 installed: $java"
        } catch {
            Write-Warn2 'Java 21 still not found. Close this window, open a new one and run play.bat again.'
            exit 1
        }
    } else {
        Write-Warn2 'Get it from https://adoptium.net (Temurin 21, JDK) or set BNG_JAVA_HOME, then run play.bat again.'
        exit 1
    }
}

# 3. Which way round
if (-not $Mode) {
    Write-Host ''
    Write-Host '  1  BeamNG cars in Minecraft, flat world        (start here)'
    Write-Host '  2  BeamNG cars in Minecraft, normal terrain'
    Write-Host '  3  Minecraft inside BeamNG                     (overlay)'
    Write-Host ''
    $pick = Read-Host '  Pick 1, 2 or 3'
    $Mode = switch ($pick) { '2' { 'terrain' } '3' { 'bridge' } default { 'host' } }
}
# The cars-in-Minecraft modes build their own ground in BeamNG's empty smallgrid level.
if ($Mode -ne 'bridge') { $Level = 'smallgrid' }
Write-Step "Mode: $Mode"

# 4. BeamNG, unless it's already up with the mod
$welcome = Get-BngWelcome -TimeoutMs 1500
if ($welcome) {
    if ($Mode -ne 'bridge' -and $welcome.level -ne $Level) {
        Write-Warn2 "BeamNG is running on '$($welcome.level)', and this mode needs '$Level'. Close BeamNG and run play.bat again."
        exit 1
    }
    Write-Ok "BeamNG is already running with the crossover mod (level $($welcome.level))"
} elseif (Get-BngProcess) {
    Write-Warn2 'BeamNG is running without the crossover mod. Close it and run play.bat again.'
    exit 1
} else {
    Write-Step 'Starting BeamNG (the first start with a fresh profile can take a few minutes)'
    & "$PSScriptRoot\run-beamng.ps1" -Level $Level -Wait -WaitSeconds 600
}

# 5. Minecraft
$firstRun = -not (Test-Path (Join-Path $BeamngRoot 'minecraft\run\options.txt'))
if ($firstRun) {
    Write-Step 'First Minecraft start: Gradle downloads Minecraft, Fabric and the shader mods and builds the crossover'
    Write-Ok 'this takes a few minutes once; later starts are quicker'
}
$mcArgs = @{ Mode = $Mode }
if ($World) { $mcArgs.World = $World }
if ($NoShaderMods) { $mcArgs.NoShaderMods = $true }
if ($NoControllerMods) { $mcArgs.NoControllerMods = $true }
& "$PSScriptRoot\run-minecraft.ps1" @mcArgs

Write-Host ''
Write-Ok 'Minecraft closed. BeamNG is still running: run play.bat again to jump back in, or close it.'
