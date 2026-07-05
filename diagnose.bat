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
echo  This will run all probes automatically and create one report.
echo  No questions will be asked. The report opens in Notepad when done.
echo  It takes about 30 seconds.
echo.

if not exist "%~dp0vendor\hidapitester\hidapitester.exe" (
    echo  [WARNING] hidapitester.exe not found. The report will still
    echo           be generated, but some sections will be skipped.
    echo.
)

echo  Running diagnostics...
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0app\diagnose.ps1" -NoPrompt -OpenReport

echo.
echo  ============================================================
echo  Done. A file named "diagnostic_report.txt" was created in:
echo    %~dp0diagnostic_report.txt
echo.
echo  The report has been opened in Notepad.
echo  Attach diagnostic_report.txt when opening a GitHub issue:
echo    https://github.com/minerva32/wlmouse-battery-tray/issues
echo  ============================================================
