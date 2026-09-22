@echo off
rem Chinese-named twin of uninstall.bat (kept for convenience). ASCII only on purpose:
rem cmd.exe mangles non-ASCII text inside .bat files.
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
echo.
pause
endlocal
