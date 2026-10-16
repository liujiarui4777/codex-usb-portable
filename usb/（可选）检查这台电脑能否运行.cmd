@echo off
chcp 65001 >nul
title Codex Portable - Environment Check
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\check-pc.ps1" -Root "%ROOT%"
exit /b 0
