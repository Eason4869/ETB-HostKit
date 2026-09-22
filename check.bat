@echo off
rem Self check. ASCII only on purpose.
setlocal
echo Checking installation...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check.ps1" %*
echo.
pause
endlocal
