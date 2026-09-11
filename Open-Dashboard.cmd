@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Open-Dashboard.ps1" %*
exit /b %errorlevel%
