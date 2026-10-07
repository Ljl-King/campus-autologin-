@echo off
rem ============================================================
rem  Campus Auto Login - Step 1: create your config file
rem  This file is ASCII-only on purpose: cmd.exe parses .bat files
rem  using the OEM/ANSI code page, so non-ASCII text here can break
rem  command parsing. All Chinese messages come from the program.
rem ============================================================
chcp 936 >nul 2>nul
cd /d "%~dp0"
title Campus Auto Login - Setup

echo ============================================================
echo   Step 1 - Create your config file
echo ============================================================
echo.

if not exist "config\config.json" (
  if not exist "config\config.example.json" (
    echo [ERROR] config\config.example.json is missing.
    pause
    exit /b 1
  )
  copy /y "config\config.example.json" "config\config.json" >nul
  echo [OK] Created config\config.json
  echo.
  echo   Please fill in these three items, then save the file:
  echo      portal.base_url   - your portal address
  echo      account.username  - your student id
  echo      account.password  - your password
) else (
  echo [INFO] config\config.json already exists. Opening it for editing.
)
echo.
notepad "config\config.json"
echo.
echo   Next step: double-click  install.bat
echo   To test first: double-click  status.bat  then choose action "1"
echo.
pause