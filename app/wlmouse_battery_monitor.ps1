# WLMouse Battery Monitor
# This script monitors your WLMouse battery level and sends a Windows notification when it is low.

# Settings
$LowThreshold = 20        # Notify when battery is <= 20%
$PollIntervalSeconds = 300 # Check every 5 minutes (300 seconds)
$MinMinutesBetweenAlerts = 30 # Alert at most once every 30 minutes

# Paths
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($null -eq $AppDir -or $AppDir -eq "") { $AppDir = Join-Path "D:\wlbattery" "app" }
$ProjectDir = Split-Path -Parent $AppDir
$DataDir = Join-Path $ProjectDir "data"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$hidapiPath = Join-Path $ProjectDir "vendor\hidapitester\hidapitester.exe"
$LogPath = Join-Path $DataDir "wlmouse_battery.log"

# WinRT Notification Types
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $message"
    Write-Host $logLine
    Add-Content -Path $LogPath -Value $logLine
}

function Show-Notification($batteryLevel) {
    $xml = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>WLMouse 배터리 부족 경고</text>
            <text>마우스 배터리가 현재 ${batteryLevel}% 입니다. 충전기를 연결해 주세요!</text>
        </binding>
    </visual>
</toast>
"@
    $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xmlDoc.LoadXml($xml)
    $AppId = "{1AC14E77-C8E7-4A22-B7C6-3EB1BBF82227}\WindowsPowerShell\v1.0\powershell.exe"
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($xmlDoc)
}

Write-Log "WLMouse Battery Monitor started."
$lastAlertTime = [DateTime]::MinValue
$lastBatteryLevel = 100
$targetId = 2 # Always query virtual ID 2 for the active mouse!

# 65-byte feature report payload: report-id(0), 0,0, <slotId=2>, 2, 0, <batteryCmd=0x83>, 0-padded to 65 bytes
$sendPayload = "0,0,0,$targetId,2,0,131" + (",$([string]::Join(",", (1..57 | ForEach-Object { '0' })))")
$QueryMaxTries = 8

# Query the mouse: send feature, wait ~120ms for the device to prepare the result, then read.
# A single combined send+read returns a stale 0xA0 / 0% packet; the delay is mandatory.
function Query-MouseBattery {
    param([string]$HidPath, [string]$VidPid, [string]$UsagePage, [string]$Usage, [int]$Length, [string]$Payload, [int]$MaxTries)

    for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
        & $HidPath --vidpid $VidPid --usagePage $UsagePage --usage $Usage -l $Length --open --send-feature $Payload --close *> $null
        Start-Sleep -Milliseconds 120
        $output = & $HidPath --vidpid $VidPid --usagePage $UsagePage --usage $Usage -l $Length --open --read-feature 0 -q

        if ($null -eq $output -or $output.Length -eq 0) { Start-Sleep -Milliseconds 80; continue }

        $readStartIndex = -1
        for ($i = 0; $i -lt $output.Length; $i++) {
            if ($output[$i] -like "*Reading*") { $readStartIndex = $i; break }
        }
        if ($readStartIndex -eq -1) { Start-Sleep -Milliseconds 80; continue }

        $readSection = $output[($readStartIndex + 1)..($output.Length - 1)]
        $hexLines = $readSection | Where-Object { $_ -match "^[0-9a-fA-F\s]+$" }
        $bytes = $hexLines -join " " -split "\s+" | Where-Object { $_ -ne "" }
        if ($bytes.Length -lt 10) { Start-Sleep -Milliseconds 80; continue }

        $status = [Convert]::ToInt32($bytes[1], 16)
        $cmdAck = [Convert]::ToInt32($bytes[6], 16)
        # Accept only active responses: status 0xA1 AND command echo 0x83
        if ($status -eq 0xA1 -and $cmdAck -eq 0x83) {
            return @{
                Status   = $status
                Battery  = [Convert]::ToInt32($bytes[8], 16)
                Charging = [Convert]::ToInt32($bytes[9], 16)
            }
        }
        Start-Sleep -Milliseconds 80
    }
    return $null
}

while ($true) {
    if (-not (Test-Path $hidapiPath)) {
        Write-Log "Error: hidapitester.exe not found at $hidapiPath"
        Start-Sleep -Seconds 60
        continue
    }

    # Query the mouse using virtual ID 2 (send -> 120ms delay -> read, with retry until active)
    $result = Query-MouseBattery -HidPath $hidapiPath -VidPid "36A7" -UsagePage "0xFFFF" -Usage "0" -Length 65 -Payload $sendPayload -MaxTries $QueryMaxTries

    if ($null -eq $result) {
        Write-Log "No active response from mouse (asleep, off, or receiver unreachable)."
        Start-Sleep -Seconds $PollIntervalSeconds
        continue
    }

    $battery  = $result.Battery
    $charging = $result.Charging

    $chargeStr = if ($charging -eq 1) { "Charging" } else { "Discharging" }
    Write-Log "Mouse connected. Battery: $battery%, Mode: $chargeStr"

    if ($battery -le $LowThreshold -and $charging -eq 0) {
        $timeSinceLastAlert = (Get-Date) - $lastAlertTime
        # Alert if enough time has passed OR if battery dropped further
        if ($timeSinceLastAlert.TotalMinutes -ge $MinMinutesBetweenAlerts -or $battery -lt $lastBatteryLevel) {
            Write-Log "Battery is low ($battery%). Sending notification..."
            Show-Notification -batteryLevel $battery
            $lastAlertTime = Get-Date
            $lastBatteryLevel = $battery
        }
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
