@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-on-github.ps1"
echo.
echo ============================================
echo  Finished. Press any key to close.
echo ============================================
pause >nul
