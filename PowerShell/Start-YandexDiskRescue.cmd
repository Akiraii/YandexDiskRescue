@echo off
setlocal
cd /d "%~dp0"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo Windows PowerShell 5.1 not found.
  pause
  exit /b 1
)
start "" "%POWERSHELL%" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%~dp0YandexDiskRescue.ps1"
