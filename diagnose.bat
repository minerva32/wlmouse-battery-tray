@echo off
setlocal

REM ====================================================================
REM  WLMouse Battery Tray Monitor - Diagnostics
REM  Double-click to generate diagnostic_report.txt
REM  Attach that file to a GitHub issue so the maintainer can help you.
REM ====================================================================

title WLMouse Battery Tray - Diagnostics

echo.
echo  ============================================================
echo    WLMouse Battery Tray - Diagnostics
echo  ============================================================
echo.
echo  This will run a series of probes (device detection, protocol
echo  tests, log capture) and produce a single text report.
echo  It takes about 30 seconds.
echo.

if not exist "%~dp0vendor\hidapitester\hidapitester.exe" (
    echo  [WARNING] hidapitester.exe not found. The report will still
    echo           be generated, but some sections will be skipped.
    echo.
)

echo  Running diagnostics...
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0app\diagnose.ps1"

echo.
echo  ============================================================
echo  Done. A file named "diagnostic_report.txt" was created in:
echo    %~dp0diagnostic_report.txt
echo.
echo  Please attach it when opening a GitHub issue at:
echo    https://github.com/minerva32/wlmouse-battery-tray/issues
echo  ============================================================
echo.
pause
