@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
set "setupResult=%errorlevel%"
echo.
pause
exit /b %setupResult%
