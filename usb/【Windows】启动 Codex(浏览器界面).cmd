@echo off
chcp 65001 >nul
title Codex Portable - Browser
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\web\launch-web.ps1" -Root "%ROOT%"
if errorlevel 1 (
  echo.
  echo [Exit code: %errorlevel%]
  pause
)
exit /b 0
