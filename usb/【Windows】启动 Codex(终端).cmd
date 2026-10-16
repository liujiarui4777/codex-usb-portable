@echo off
chcp 65001 >nul
title Codex Portable - Terminal
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "LOG=%ROOT%\_launch-log.txt"
> "%LOG%" (
  echo date=%DATE% %TIME%
  echo root=%ROOT%
  echo cwd=%CD%
  echo arch=%PROCESSOR_ARCHITECTURE%
  echo ps=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
  where powershell
  where codex
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\codex\launch-cli.ps1" -Root "%ROOT%"
set RC=%errorlevel%
>> "%LOG%" echo exit=%RC%
echo.
echo [Launcher exited, code %RC%]
pause
exit /b %RC%
