@echo off
title 清理本机缓存
echo 这将删除本机上的 Codex 便携版程序缓存（不影响 U 盘数据）。
echo 清理后下次启动会重新拷贝程序（1-3 分钟）。
echo.
choice /c YN /m "确定要清理吗"
if errorlevel 2 exit /b 0
rmdir /s /q "%USERPROFILE%\CodexPortable" 2>nul
if exist "%USERPROFILE%\CodexPortable" (
  echo 部分文件未能删除（可能被占用），请先关闭 Codex 再重试。
) else (
  echo 已清理。
)
pause
