@echo off
chcp 65001 >nul
title Codex Portable - Set API Key
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\set-api-key.ps1" -CodexHome "%ROOT%"
if errorlevel 1 (
  echo.
  echo [Exit code: %errorlevel%]
)
echo.
pause
exit /b 0
