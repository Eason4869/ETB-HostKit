@echo off
rem One-click installer (auto-detects the game folder). ASCII only on purpose.
setlocal
echo ============================================================
echo   Escape The Backrooms - host mod installer
echo ============================================================
echo.
echo   Auto-detects the game folder (Steam libraries / registry).
echo   Installs UE4SS runtime, ETB_HostKit, stable hook config,
echo   network settings and a desktop shortcut for the console.
echo.
echo   Please CLOSE THE GAME before installing.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
if "%EXITCODE%"=="0" (
  echo Done. Start the game, then open the desktop shortcut "ETB Control Panel".
) else (
  echo Install failed with code %EXITCODE% - please send a screenshot.
)
echo.
pause
endlocal
