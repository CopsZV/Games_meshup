@echo off
rem Starts the Garry's Mod x BeamNG.drive crossover. See README.md for modes and controls.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play.ps1" %*
if errorlevel 1 pause
