@echo off
rem  Campus Auto Login - Step 2: install autostart (ASCII-only file)
chcp 936 >nul 2>nul
cd /d "%~dp0"
title Campus Auto Login - Install

echo ============================================================
echo   Campus Auto Login - Install autostart
echo ============================================================
echo.

if not exist "config\config.json" (
  echo [ERROR] config\config.json not found.
  echo         Please double-click  setup.bat  first.
  echo.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1" -Install
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
  echo [OK] Autostart installed. The program is running in background.
  echo      Check status : status.bat
  echo      Remove       : uninstall.bat
) else (
  echo [FAILED] Install did not complete.
  echo          Run status.bat and choose action "2" for diagnosis.
)
echo.
pause