Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -File D:\wlbattery\wlmouse_battery_tray.ps1", 0, false
