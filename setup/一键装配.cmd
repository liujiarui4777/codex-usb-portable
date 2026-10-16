@echo off
chcp 65001 >nul
title Codex Portable - Setup
setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
echo ============================================
echo    Codex Portable - one-click setup
echo ============================================
echo Target drive : the drive this repository sits on
echo It will download program components from their official
echo upstream releases (about 1.5 GB) and put them in place.
echo.
choice /c YN /m "Continue"
if errorlevel 2 exit /b 0
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%\setup.ps1"
set RC=%errorlevel%
echo.
if not "%RC%"=="0" echo [Setup exited with code %RC%]
pause
exit /b %RC%
