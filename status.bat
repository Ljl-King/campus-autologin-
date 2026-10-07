@echo off
rem  Campus Auto Login - menu for status / test / diagnose / log
rem  ASCII-only file (see setup.bat for the reason)
chcp 936 >nul 2>nul
cd /d "%~dp0"
title Campus Auto Login - Status

:menu
cls
echo ============================================================
echo   Campus Auto Login - Menu
echo ============================================================
echo.
echo   1 . Check status
echo   2 . Network and portal diagnosis
echo   3 . Try logging in once
echo   4 . Local self check
echo   5 . Show recent log
echo   6 . Re-download portal crypto script
echo   7 . Run in foreground and watch live log
echo   0 . Exit
echo.
set "CH="
set /p "CH=Please enter a number and press Enter: "

if "%CH%"=="1" goto do_status
if "%CH%"=="2" goto do_diag
if "%CH%"=="3" goto do_once
if "%CH%"=="4" goto do_selftest
if "%CH%"=="5" goto do_log
if "%CH%"=="6" goto do_crypto
if "%CH%"=="7" goto do_run
if "%CH%"=="0" exit /b 0
goto menu

:do_status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1" -Status
pause
goto menu

:do_diag
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1" -Diagnose
pause
goto menu

:do_once
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1" -Once
pause
goto menu

:do_selftest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1" -SelfTest
pause
goto menu

:do_crypto
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1" -FetchCrypto
pause
goto menu

:do_run
echo Running in foreground. Press Ctrl+C to stop.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\main.ps1"
pause
goto menu

:do_log
if exist "data\autologin.log" (
  powershell.exe -NoProfile -Command "Get-Content -Path 'data\autologin.log' -Tail 60 -Encoding UTF8"
) else (
  echo No log file yet: data\autologin.log
)
pause
goto menu