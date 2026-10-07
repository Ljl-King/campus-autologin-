@echo off
rem  Campus Auto Login - remove autostart (ASCII-only file)
chcp 936 >nul 2>nul
cd /d "%~dp0"
title Campus Auto Login - Uninstall

echo ============================================================
echo   Campus Auto Login - Uninstall autostart
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1" -Uninstall

echo.
echo [NOTE] Autostart entries removed.
echo        If a background process is still running, end powershell.exe
echo        in Task Manager, or just reboot.
echo.
pause