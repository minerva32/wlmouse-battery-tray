@echo off
setlocal

REM ====================================================================
REM  WLMouse Battery Tray Monitor - Installer
REM  Double-click this file to install. Runs the tray monitor now and
REM  optionally registers it to start automatically on login.
REM ====================================================================

title WLMouse Battery Tray Monitor - Installer

echo.
echo  ============================================================
echo    WLMouse Battery Tray Monitor - Installer
echo  ============================================================
echo.
echo  This will start the tray monitor now and optionally
echo  register it to auto-start when you log in.
echo.

REM --- sanity check ---
if not exist "%~dp0hidapitester\hidapitester.exe" (
    echo  [ERROR] hidapitester\hidapitester.exe not found.
    echo         Make sure the repository was fully downloaded.
    pause
    exit /b 1
)
if not exist "%~dp0wlmouse_battery_tray.ps1" (
    echo  [ERROR] wlmouse_battery_tray.ps1 not found.
    pause
    exit /b 1
)

echo  All files present.
echo.

REM --- start the tray monitor now (silent, background) ---
echo  [1/2] Starting the tray monitor...
wscript.exe "%~dp0run_silently.vbs"
echo       Look for the battery icon in the system tray (right side of taskbar).
echo.

REM --- ask whether to auto-start on login ---
set /p AUTOSTART="Register to auto-start on login? (Y/N): "
if /i "%AUTOSTART%"=="Y" (
    set "VBS_PATH=%~dp0run_silently.vbs"
    set "SHORTCUT=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\WLMouseBatteryTray.lnk"
    powershell -NoProfile -Command ^
        "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%SHORTCUT%');" ^
        "$s.TargetPath='wscript.exe';" ^
        "$s.Arguments='\"%VBS_PATH%\"';" ^
        "$s.WorkingDirectory='%~dp0';" ^
        "$s.WindowStyle=7;" ^
        "$s.Save()"
    echo  [2/2] Registered in Startup: %SHORTCUT%
) else (
    echo  [2/2] Auto-start registration skipped.
)

echo.
echo  ============================================================
echo    Install complete!
echo    - Tray icon: check the system tray (^ overflow area)
echo    - To exit: right-click the tray icon ^> Exit
echo    - Settings: right-click ^> Warning threshold
echo  ============================================================
echo.
pause
