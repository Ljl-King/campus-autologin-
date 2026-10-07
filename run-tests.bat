@echo off
rem  Campus Auto Login - offline end-to-end test (ASCII-only)
chcp 936 >nul 2>nul
cd /d "%~dp0"
title Campus Auto Login - Tests

echo ============================================================
echo   Offline end-to-end test (no campus network needed)
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests\Run-Tests.ps1"
echo.
pause