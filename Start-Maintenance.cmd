@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-Maintenance.ps1" %*
exit /b %errorlevel%
