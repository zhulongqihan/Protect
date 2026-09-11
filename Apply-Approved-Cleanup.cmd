@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-Approved-Cleanup.ps1" %*
exit /b %errorlevel%
