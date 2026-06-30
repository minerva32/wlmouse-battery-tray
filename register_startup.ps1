# Registers a startup shortcut that launches the tray monitor on user login.
# Invoked by install.bat. Takes the project directory as $args[0].
# Uses a .lnk shortcut under the per-user Startup folder pointing at run_silently.vbs.

$ErrorActionPreference = 'Stop'

$ProjectDir = $args[0]
if (-not $ProjectDir) {
    Write-Host "[ERROR] project directory not provided"
    exit 1
}

$VbsPath    = Join-Path $ProjectDir 'run_silently.vbs'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Startup')) 'WLMouseBatteryTray.lnk'

if (-not (Test-Path $VbsPath)) {
    Write-Host "[ERROR] run_silently.vbs not found at: $VbsPath"
    exit 1
}

try {
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Shortcut)
    $s.TargetPath       = (Join-Path $env:WINDIR 'System32\wscript.exe')
    $s.Arguments        = "`"$VbsPath`""
    $s.WorkingDirectory = $ProjectDir
    $s.WindowStyle      = 7   # minimized-no-focus (wscript is GUI anyway)
    $s.Description      = 'WLMouse Battery Tray Monitor'
    $s.Save()
    Write-Host "Registered in Startup: $Shortcut"
    exit 0
} catch {
    Write-Host "[ERROR] failed to create startup shortcut: $($_.Exception.Message)"
    exit 1
}
