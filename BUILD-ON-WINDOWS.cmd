@echo off
setlocal
cd /d "%~dp0"
where dotnet >nul 2>&1 || (echo ERROR: Install trusted .NET 8 SDK before building. & pause & exit /b 1)
where node >nul 2>&1 || (echo ERROR: Install Node.js 22 from nodejs.org before building. & pause & exit /b 1)
where npm >nul 2>&1 || (echo ERROR: Install npm before building. & pause & exit /b 1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1"
if errorlevel 1 (echo BUILD FAILED. Check error above. & pause & exit /b 1)
echo BUILD OK: see dist\YandexDiskRescue-Portable.zip and dist\YandexDiskRescue-Setup.exe
pause
