@echo off
setlocal

set "SCRIPT_PATH=%~dp0make_release_zip.ps1"

if not exist "%SCRIPT_PATH%" (
  echo Packaging script was not found:
  echo   %SCRIPT_PATH%
  exit /b 1
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo Windows PowerShell was not found.
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo Release package creation failed.
)

exit /b %EXIT_CODE%
