@echo off
chcp 65001 >nul
title Codex Portable - Collect Host Profile
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
echo Collecting this PC profile: hardware / OS / compatibility / speed test...
echo (takes about 30 seconds)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\collect-pc.ps1" -Root "%ROOT%"
set RC=%errorlevel%
echo.
if not "%RC%"=="0" echo [Collector exited with code %RC%]
echo Close this window when done; you may unplug the USB drive.
echo.
pause
exit /b %RC%
