Set FSO = CreateObject("Scripting.FileSystemObject")
Set WshShell = CreateObject("WScript.Shell")

ScriptDir = FSO.GetParentFolderName(WScript.ScriptFullName)
PsScript = FSO.BuildPath(ScriptDir, "wlmouse_battery_tray.ps1")
WshShell.CurrentDirectory = ScriptDir

Cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & PsScript & """"
WshShell.Run Cmd, 0, False
