@echo off
rem ASCII only on purpose: cmd.exe mangles non-ASCII text in .bat files.
rem Everything else lives in uninstall.ps1 (UTF-8 with BOM).
setlocal
cd /d "%~dp0"

echo ==========================================================
echo   Escape The Backrooms - uninstall the host mod
echo ==========================================================
echo.
echo   no option      remove the mod, restore configs, delete shortcut
echo   -RemoveUE4SS   also remove the UE4SS runtime (clean game folder)
echo   -Purge         delete instead of moving to the backup folder
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set EXITCODE=%ERRORLEVEL%

echo.
if not "%EXITCODE%"=="0" echo Something went wrong. Read the messages above.
pause
endlocal
