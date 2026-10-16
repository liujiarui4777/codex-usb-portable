@echo off
chcp 65001 >nul
title Codex Portable - Desktop App
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\_internal\launch-desktop.ps1" -Root "%ROOT%"
if errorlevel 1 (
  echo.
  echo [Exit code: %errorlevel%]
  pause
)
exit /b 0
