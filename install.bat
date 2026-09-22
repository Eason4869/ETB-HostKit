@echo off
rem Same as the one-click installer (kept for convenience). ASCII only on purpose.
setlocal
echo Installing Escape The Backrooms host mod...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
if errorlevel 1 pause
endlocal
