@echo off
setlocal
title LaptopInspect - Pre-Purchase Diagnostic & Corporate Lock Suite

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges for full BIOS WMI, BitLocker, MDM, and SMART diagnostics...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0inspect.ps1\" %*' -Verb RunAs"
    if %errorlevel% neq 0 (
        echo Elevation canceled or failed. Running in Standard mode...
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0inspect.ps1" -NoElevate %*
    )
    exit /b %errorlevel%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0inspect.ps1" %*
exit /b %errorlevel%
