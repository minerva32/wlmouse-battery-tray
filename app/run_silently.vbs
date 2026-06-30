Set FSO = CreateObject("Scripting.FileSystemObject")
Set WshShell = CreateObject("WScript.Shell")

ScriptDir = FSO.GetParentFolderName(WScript.ScriptFullName)
ProjectDir = FSO.GetParentFolderName(ScriptDir)
PsScript = FSO.BuildPath(ScriptDir, "wlmouse_battery_tray.ps1")
WshShell.CurrentDirectory = ProjectDir

Cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & PsScript & """"
WshShell.Run Cmd, 0, False
