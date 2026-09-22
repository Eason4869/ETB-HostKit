@echo off
rem Launch the visual console with no console window.
rem ASCII only on purpose - Chinese text inside .bat breaks cmd parsing.
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HostPanel.ps1" %*
