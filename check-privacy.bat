@echo off
rem  Campus Auto Login - privacy self check before publishing (ASCII-only)
chcp 936 >nul 2>nul
cd /d "%~dp0"
title Campus Auto Login - Privacy Check

echo ============================================================
echo   Privacy self check  (run this BEFORE publishing)
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests\Check-Privacy.ps1"
echo.
pause