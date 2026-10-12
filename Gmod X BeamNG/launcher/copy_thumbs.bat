@echo off
rem Copies BeamNG's car preview pictures into Garry's Mod so the BeamNG menu can show them.
set "SRC=%LOCALAPPDATA%\BeamGMod\bng-userfolder\current\temp\mccross\thumbs"
set "DST=%~dp0..\GarrysMod\garrysmod\data\beamgmod\thumbs"
if not exist "%SRC%" (
  echo Pictures not found: %SRC%
  pause
  exit /b 1
)
if not exist "%DST%" mkdir "%DST%"
robocopy "%SRC%" "%DST%" *.jpg *.png /NFL /NDL /NJH /NJS /NP
echo.
echo Done. Pictures copied to: %DST%
pause
