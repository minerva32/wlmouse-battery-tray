# WLMouse Battery Tray Monitor
# Live system-tray icon showing the battery percentage of any Feature-Report-compatible
# WLMouse device (Beast MAX 8K / Beast X 8K / receivers, VID 0x36A7).
#
# Protocol (reverse-engineered, matches mee7ya/wlmouse-cli):
#   send 65-byte feature report with cmd 0x83 at offset 6  ->  wait ~120ms  ->  read feature report.
#   Active response: bytes[1]=0xA1 (status) AND bytes[6]=0x83 (cmd echo).
#   bytes[8] = battery %, bytes[9] = charging flag.

$VendorId = "36A7"

# Product IDs that use the Feature-Report protocol (auto-detected at startup).
# Source: https://github.com/mee7ya/wlmouse-cli
$SupportedPids = @{
    "A880" = "Beast MAX 8K Receiver"
    "A883" = "Beast X 8K Receiver"
    "A884" = "Beast X 8K"
}

# Default settings (overridden by settings.json if present)
$PollIntervalSeconds = 300
$LowThreshold        = 20
$ThresholdChoices    = @(10, 15, 20, 30)

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($null -eq $ScriptDir -or $ScriptDir -eq "") { $ScriptDir = "D:\wlbattery" }
$hidapiPath    = Join-Path $ScriptDir "hidapitester\hidapitester.exe"
$LogPath       = Join-Path $ScriptDir "wlmouse_battery.log"
$SettingsPath  = Join-Path $ScriptDir "settings.json"

# --- Load UI assemblies ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Logging ---
function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "[$timestamp] $message"
}

# --- Settings persistence ---
function Load-Settings {
    if (Test-Path $SettingsPath) {
        try {
            $cfg = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.LowThreshold)   { $script:LowThreshold        = [int]$cfg.LowThreshold }
            if ($cfg.PollIntervalSeconds) { $script:PollIntervalSeconds = [int]$cfg.PollIntervalSeconds }
        } catch { Write-Log "settings.json parse error, using defaults: $($_.Exception.Message)" }
    }
}
function Save-Settings {
    $cfg = @{ LowThreshold = $script:LowThreshold; PollIntervalSeconds = $script:PollIntervalSeconds }
    $cfg | ConvertTo-Json | Set-Content $SettingsPath -Encoding UTF8
}

# --- Device auto-detection: find first supported WLMouse receiver/dongle ---
function Detect-Device {
    if (-not (Test-Path $hidapiPath)) { return $null }
    $listing = & $hidapiPath --vidpid $VendorId --list-detail 2>&1
    $lines = $listing -split "`r?`n"
    $currentPid = $null
    foreach ($line in $lines) {
        if ($line -match "productId:\s*0x([0-9A-Fa-f]{4})") {
            $currentPid = $matches[1].ToUpper()
        }
        if ($line -match "usagePage:\s*0xFFFF" -and $line -match "interface:\s*2" -and $currentPid) {
            if ($SupportedPids.ContainsKey($currentPid)) {
                return @{ Pid = $currentPid; Name = $SupportedPids[$currentPid] }
            }
        }
    }
    # Fallback: any supported PID present, even if interface detection missed.
    # ($PID is a read-only automatic variable in PowerShell — use $devPid.)
    foreach ($line in $lines) {
        foreach ($devPid in $SupportedPids.Keys) {
            if ($line -match ("0x" + $devPid)) {
                return @{ Pid = $devPid; Name = $SupportedPids[$devPid] }
            }
        }
    }
    return $null
}

# --- HID battery query (send feature, wait, read, retry until active) ---
$targetId      = 2
$QueryMaxTries = 8
$sendPayload   = "0,0,0,$targetId,2,0,131" + (",$([string]::Join(",", (1..57 | ForEach-Object { '0' })))")

function Query-MouseBattery {
    param([int]$MaxTries)

    for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
        if (-not (Test-Path $hidapiPath)) { return $null }
        & $hidapiPath --vidpid $VendorId --usagePage 0xFFFF --usage 0 -l 65 --open --send-feature $sendPayload --close *> $null
        Start-Sleep -Milliseconds 120
        $output = & $hidapiPath --vidpid $VendorId --usagePage 0xFFFF --usage 0 -l 65 --open --read-feature 0 -q

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

# --- Build the tray icon as a drawn bitmap (black bg, colored fg by state) ---
function New-BatteryIcon {
    param([int]$Battery, [int]$Charging, [int]$LowThreshold)

    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $bg = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
    if ($Charging -eq 1) {
        $fg = [System.Drawing.Color]::FromArgb(255, 80, 170, 255)    # blue (charging)
    } elseif ($Battery -gt $LowThreshold) {
        $fg = [System.Drawing.Color]::FromArgb(255, 80, 220, 100)    # green (healthy)
    } elseif ($Battery -gt 10) {
        $fg = [System.Drawing.Color]::FromArgb(255, 255, 170, 60)    # orange (low)
    } else {
        $fg = [System.Drawing.Color]::FromArgb(255, 240, 70, 70)     # red (critical)
    }

    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $bg
    $g.FillRectangle($brush, 0, 0, 16, 16)
    $brush.Dispose()

    if ($Charging -eq 1) {
        $bolt = New-Object System.Drawing.SolidBrush $fg
        $pts = @(
            (New-Object System.Drawing.PointF 9, 1),
            (New-Object System.Drawing.PointF 4, 9),
            (New-Object System.Drawing.PointF 7, 9),
            (New-Object System.Drawing.PointF 6, 15),
            (New-Object System.Drawing.PointF 12, 6),
            (New-Object System.Drawing.PointF 9, 6)
        )
        $g.FillPolygon($bolt, $pts)
        $bolt.Dispose()
    } else {
        if ($Battery -ge 100) { $label = "F" } else { $label = [string]$Battery }
        $fontSize = if ($label.Length -ge 3) { 6 } elseif ($label.Length -eq 2) { 7 } else { 9 }
        $font = New-Object System.Drawing.Font "Segoe UI", $fontSize, ([System.Drawing.FontStyle]::Bold)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment     = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $textBrush = New-Object System.Drawing.SolidBrush $fg
        $rect = New-Object System.Drawing.RectangleF 0, 0, 16, 16
        $g.DrawString($label, $font, $textBrush, $rect, $sf)
        $font.Dispose(); $textBrush.Dispose(); $sf.Dispose()
    }

    $g.Dispose()
    $hicon = $bmp.GetHicon()
    $bmp.Dispose()
    return [System.Drawing.Icon]::FromHandle($hicon)
}

# --- Bootstrap ---
Load-Settings
$device = Detect-Device
if ($null -eq $device) {
    Write-Log "No supported WLMouse device found (VID $VendorId, PIDs: $($SupportedPids.Keys -join ', '))."
} else {
    Write-Log "Detected $($device.Name) (PID $($device.Pid))."
}

# --- Build the notify icon + context menu ---
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = (New-BatteryIcon -Battery 0 -Charging 0 -LowThreshold $LowThreshold)
$notify.Visible = $true
$notify.Text    = "WLMouse: querying..."

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$refreshItem = $menu.Items.Add("지금 새로고침")

# Submenu: low-battery threshold
$thresholdItem  = $menu.Items.Add("경고 임계값")
$thresholdMenu  = New-Object System.Windows.Forms.ToolStripDropDownMenu
$thresholdItem.DropDown = $thresholdMenu
$thresholdSubitems = @{}
foreach ($choice in $ThresholdChoices) {
    $sub = $thresholdMenu.Items.Add("${choice}%")
    $thresholdSubitems[[string]$choice] = $sub
}

$menu.Items.Add("-") | Out-Null   # separator
$exitItem = $menu.Items.Add("종료")
$notify.ContextMenuStrip = $menu

# --- Refresh logic ---
$script:lastResult = $null

function Update-Tray {
    $result = Query-MouseBattery -MaxTries $QueryMaxTries
    $script:lastResult = $result

    if ($null -eq $result) {
        $notify.Icon = (New-BatteryIcon -Battery 0 -Charging 0 -LowThreshold $script:LowThreshold)
        $dev = if ($device) { $device.Name } else { "장치 없음" }
        $notify.Text = "WLMouse ($dev): 응답 없음"
        Write-Log "No active response from mouse."
        return
    }

    $battery  = $result.Battery
    $charging = $result.Charging

    # Battery 🔋 / lightning ⚡ literals (surrogate-pair code points can't go through [char])
    $tipIcon = if ($charging -eq 1) { "⚡" } else { "🔋" }
    $notify.Text = "$tipIcon $($device.Name): $battery%"
    $notify.Icon = (New-BatteryIcon -Battery $battery -Charging $charging -LowThreshold $script:LowThreshold)
    Write-Log "Tray updated. Battery: $battery%, Charging: $charging, Threshold: $($script:LowThreshold)%"
}

# --- Wire events ---
$refreshItem.Add_Click({ Update-Tray })

foreach ($choice in $ThresholdChoices) {
    $sub = $thresholdSubitems[[string]$choice]
    # Stash the value on the item itself so the click handler reads a stable value
    # (a plain closure would capture the loop variable's final value, not each iteration's).
    $sub.Tag = $choice
    $sub.Add_Click({
        $newThreshold = [int]$this.Tag
        $script:LowThreshold = $newThreshold
        Save-Settings
        # Reflect the new threshold on the icon immediately if we have a reading
        if ($script:lastResult) {
            $r = $script:lastResult
            $notify.Icon = (New-BatteryIcon -Battery $r.Battery -Charging $r.Charging -LowThreshold $script:LowThreshold)
        }
        Write-Log "Low-battery threshold set to ${newThreshold}%."
    })
}

$exitItem.Add_Click({
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# --- Single-shot timer: fire immediately, then every $PollIntervalSeconds ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollIntervalSeconds * 1000
$timer.Add_Tick({ Update-Tray })

Write-Log "WLMouse Battery Tray Monitor started (poll every ${PollIntervalSeconds}s, threshold ${LowThreshold}%)."
Update-Tray
$timer.Start()

# Run the message loop (keeps the process alive for tray events)
[System.Windows.Forms.Application]::Run()
