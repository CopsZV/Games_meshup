# Shared helpers for the BeamNG crossover scripts. Dot-source it: . "$PSScriptRoot\common.ps1"
# Every path is detected, never hardcoded: Steam libraries, the BeamNG install, its version,
# the user folder and a JDK 21. Override any of them with the environment variables below.
#   BNG_INSTALL   folder containing BeamNG.drive.exe
#   BNG_USERPATH  user folder to run BeamNG with (default: the dedicated test folder, see below)
#   BNG_JAVA_HOME JDK 21 used for Gradle and Minecraft

$ErrorActionPreference = 'Stop'

$Script:BeamngRoot = Split-Path -Parent $PSScriptRoot          # ...\beamng
$Script:RepoRoot = Split-Path -Parent $BeamngRoot               # the repo's root
$Script:BngAppId = '284160'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Get-SteamRoot {
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop)
            foreach ($name in 'SteamPath', 'InstallPath') {
                if ($p.$name -and (Test-Path $p.$name)) { return (Resolve-Path $p.$name).Path }
            }
        } catch { }
    }
    $fallback = "${env:ProgramFiles(x86)}\Steam"
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-SteamLibraries {
    $root = Get-SteamRoot
    if (-not $root) { return @() }
    $libs = @($root)
    $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"').Matches) {
            $libs += ($m.Groups[1].Value -replace '\\\\', '\')
        }
    }
    return $libs | Sort-Object -Unique   # case-insensitive, unlike Select-Object -Unique
}

# The live BeamNG install: the Steam library whose appmanifest says the app is installed.
function Get-BeamngInstall {
    if ($env:BNG_INSTALL) {
        if (Test-Path (Join-Path $env:BNG_INSTALL 'BeamNG.drive.exe')) { return $env:BNG_INSTALL }
        throw "BNG_INSTALL=$($env:BNG_INSTALL) has no BeamNG.drive.exe"
    }
    foreach ($lib in Get-SteamLibraries) {
        # Libraries on unplugged drives are still listed in libraryfolders.vdf.
        if (-not (Test-Path -LiteralPath $lib -ErrorAction SilentlyContinue)) { continue }
        $manifest = [IO.Path]::Combine($lib, 'steamapps', "appmanifest_$BngAppId.acf")
        if (-not (Test-Path $manifest)) { continue }
        $dir = (Select-String -Path $manifest -Pattern '"installdir"\s+"([^"]+)"').Matches[0].Groups[1].Value
        $path = [IO.Path]::Combine($lib, 'steamapps', 'common', $dir)
        if (Test-Path (Join-Path $path 'BeamNG.drive.exe')) { return $path }
    }
    throw 'BeamNG.drive install not found in any Steam library (set BNG_INSTALL)'
}

# Version string BeamNG itself wrote last time it ran (e.g. 0.39.4.0).
function Get-BeamngVersion {
    $ini = Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive.ini'
    if (Test-Path $ini) {
        $m = Select-String -Path $ini -Pattern '^\s*version\s*=\s*(\S+)'
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    return 'unknown'
}

# The player's normal user folder (BeamNG uses <LocalAppData>\BeamNG\BeamNG.drive\current).
function Get-BeamngDefaultUserPath {
    $p = Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
    return $null
}

# The folder passed to BeamNG as -userpath for our runs. Default: a dedicated folder in the repo
# (git ignores it), so the crossover never touches the player's own mods, settings and BeamMP setup.
# Checkouts from before 2026-10-06 kept it next to the repo; an existing one there is still used.
function Get-BeamngUserRoot {
    if ($env:BNG_USERPATH) { return $env:BNG_USERPATH }
    $old = Join-Path (Split-Path -Parent $RepoRoot) 'bng-userfolder'
    if (Test-Path (Join-Path $old 'current')) { return $old }
    return (Join-Path $RepoRoot 'bng-userfolder')
}

# The user folder BeamNG actually uses for -userpath X: X\current (verified: 0.39.4 creates
# X\current and writes beamng.log, mods and settings there).
function Get-BeamngUserPath {
    return (Join-Path (Get-BeamngUserRoot) 'current')
}

function Get-Java21Home {
    if ($env:BNG_JAVA_HOME -and (Test-Path (Join-Path $env:BNG_JAVA_HOME 'bin\java.exe'))) { return $env:BNG_JAVA_HOME }
    $candidates = @()
    foreach ($base in "$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Java", "$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Zulu", "$env:USERPROFILE\.jdks") {
        if (Test-Path $base) { $candidates += Get-ChildItem $base -Directory | Where-Object { $_.Name -match '(jdk|zulu)[-_]?21' } }
    }
    $hit = $candidates | Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    throw 'No JDK 21 found (install Temurin 21 or set BNG_JAVA_HOME)'
}

function Get-MsBuildVcVars {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { return $null }
    $bat = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    if (Test-Path $bat) { return $bat }
    return $null
}

function Get-BngProcess {
    Get-Process -Name 'BeamNG.drive.x64' -ErrorAction SilentlyContinue
}

# Says hello to the crossover extension on 127.0.0.1:$Port (protocol.md) and returns its welcome
# (bngVersion, level, ready, ...), or $null if nothing answers within $TimeoutMs. Ends the session
# with bye at once. This, not beamng.log, is how scripts know BeamNG is up: the log reaches the
# disk minutes late and still holds the previous run's lines at startup.
function Get-BngWelcome([int]$Port = 47020, [int]$TimeoutMs = 700) {
    $udp = New-Object System.Net.Sockets.UdpClient (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, 0))
    try {
        $udp.Client.ReceiveTimeout = 200
        $peer = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, $Port)
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        $seq = 0
        while ((Get-Date) -lt $deadline) {
            $seq++
            $hello = '{"v":1,"t":"hello","sid":0,"seq":' + $seq + ',"ts":0,"client":"scripts","protocol":1}'
            $bytes = [Text.Encoding]::UTF8.GetBytes($hello)
            [void]$udp.Send($bytes, $bytes.Length, $peer)
            try {
                $from = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $msg = [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$from)) | ConvertFrom-Json
            } catch [System.Net.Sockets.SocketException] {
                continue   # timeout, or ICMP "port unreachable" while nothing listens yet
            }
            if ($msg.t -eq 'welcome') {
                $bye = [Text.Encoding]::UTF8.GetBytes('{"v":1,"t":"bye","sid":' + $msg.sid + ',"seq":' + ($seq + 1) + ',"ts":0}')
                [void]$udp.Send($bye, $bye.Length, $peer)
                return $msg
            }
        }
        return $null
    } finally {
        $udp.Close()
    }
}

# Merges keys into a BeamNG settings JSON file (created if missing). Written without a BOM: BeamNG's
# parser rejects one and then ignores the whole file. -OnlyIfMissing leaves an existing file alone.
function Set-BngSettings([string]$File, [hashtable]$Values, [switch]$OnlyIfMissing) {
    $obj = [ordered]@{}
    if (Test-Path $File) {
        if ($OnlyIfMissing) { return }
        $raw = Get-Content -Raw -Path $File
        if ($raw.Trim()) {
            ($raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $obj[$_.Name] = $_.Value }
        }
    }
    foreach ($k in $Values.Keys) { $obj[$k] = $Values[$k] }
    New-Item -ItemType Directory -Force (Split-Path $File) | Out-Null
    [IO.File]::WriteAllText($File, ($obj | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}
