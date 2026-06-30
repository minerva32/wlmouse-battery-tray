# WLMouse Battery Tray Monitor
# Live system-tray icon showing the battery percentage of any WLMouse mouse
# (Beast MAX 8K / Beast X 8K / Beast X / receivers / Mini / Pro / Miao, VID 0x36A7).
#
# Protocol is reverse-engineered (matches mee7ya/wlmouse-cli + snems/WLPower):
#   - Feature Report devices (A880/A883/A884): send 65-byte feature report with
#     cmd 0x83 at offset 6 -> ~120ms wait -> read feature report.
#     Active response: bytes[1]=0xA1 (status) AND bytes[6]=0x83 (cmd echo).
#     bytes[8] = battery %, bytes[7] = charging flag (0x01 = charging).
#   - Interrupt Endpoint devices (A887/A888): write 64-byte output report with
#     cmd 0x1a at offset 3 -> ~100ms wait -> read input report.
#     bytes[8] = battery %.
# Unknown PIDs in the 0x36A7 vendor are tried with BOTH protocols in sequence.

$VendorId = "36A7"

# Known WLMouse product IDs (auto-detected at startup).
# Source: mee7ya/wlmouse-cli + ebnimaa/wlmouse-beastx-windows + linux-usb.org
$KnownPids = @{
    "A880" = @{ Name = "Beast MAX 8K Receiver"; Protocol = "Feature" }
    "A883" = @{ Name = "Beast X 8K Receiver";   Protocol = "Feature" }
    "A884" = @{ Name = "Beast X 8K";            Protocol = "Feature" }
    "A887" = @{ Name = "Beast X Receiver";      Protocol = "Interrupt" }
    "A888" = @{ Name = "Beast X";               Protocol = "Interrupt" }
}

# Default settings (overridden by settings.json if present)
$PollIntervalSeconds = 300
$LowThreshold        = 20
$ThresholdChoices    = @(10, 15, 20, 30)

# Paths
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($null -eq $AppDir -or $AppDir -eq "") { $AppDir = Join-Path "D:\wlbattery" "app" }
$ProjectDir = Split-Path -Parent $AppDir
$DataDir = Join-Path $ProjectDir "data"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$hidapiPath    = Join-Path $ProjectDir "vendor\hidapitester\hidapitester.exe"
$LogPath       = Join-Path $DataDir "wlmouse_battery.log"
$SettingsPath  = Join-Path $DataDir "settings.json"

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
            if ($cfg.LowThreshold)         { $script:LowThreshold        = [int]$cfg.LowThreshold }
            if ($cfg.PollIntervalSeconds)  { $script:PollIntervalSeconds = [int]$cfg.PollIntervalSeconds }
        } catch { Write-Log "settings.json parse error, using defaults: $($_.Exception.Message)" }
    }
}
function Save-Settings {
    $cfg = @{ LowThreshold = $script:LowThreshold; PollIntervalSeconds = $script:PollIntervalSeconds }
    $cfg | ConvertTo-Json | Set-Content $SettingsPath -Encoding UTF8
}

# --- Device auto-detection: find the WLMouse config interface ---
function Detect-Device {
    if (-not (Test-Path $hidapiPath)) { return $null }
    $listing = & $hidapiPath --vidpid $VendorId --list-detail 2>&1
    $lines = $listing -split "`r?`n"

    # 1) Try known PIDs first, preferring the WLMouse config interface
    #    (usagePage 0xFFFF, interface 2 for Feature devices; usage 0x06 control interface for Interrupt devices).
    # NOTE: $PID is a read-only automatic variable in PowerShell, so use $devPid.
    $devPid = $null
    foreach ($line in $lines) {
        if ($line -match "productId:\s*0x([0-9A-Fa-f]{4})") { $devPid = $matches[1].ToUpper() }
        if ($devPid -and $KnownPids.ContainsKey($devPid)) {
            if ($line -match "usagePage:\s*0xFFFF" -or $line -match "interface:\s*2") {
                return @{ Pid = $devPid; Name = $KnownPids[$devPid].Name; Protocol = $KnownPids[$devPid].Protocol }
            }
        }
    }

    # 2) Fallback: any known PID present anywhere in the listing.
    foreach ($line in $lines) {
        foreach ($devPid in $KnownPids.Keys) {
            if ($line -match ("0x" + $devPid)) {
                return @{ Pid = $devPid; Name = $KnownPids[$devPid].Name; Protocol = $KnownPids[$devPid].Protocol }
            }
        }
    }

    # 3) Final fallback: unknown WLMouse PID — detect with both protocols at query time.
    foreach ($line in $lines) {
        if ($line -match "productId:\s*0x([0-9A-Fa-f]{4})") {
            $unknownPid = $matches[1].ToUpper()
            return @{ Pid = $unknownPid; Name = "WLMouse (PID $unknownPid)"; Protocol = "Auto" }
        }
    }
    return $null
}

# --- HID query: dispatches to Feature or Interrupt protocol, with retry until active ---
$QueryMaxTries = 8

function Parse-HexBytes {
    # Walks hidapitester output, locates the "Reading ... " section, returns the hex byte tokens.
    param([string[]]$Output)
    if ($null -eq $Output -or $Output.Length -eq 0) { return $null }
    $readStartIndex = -1
    for ($i = 0; $i -lt $Output.Length; $i++) {
        if ($Output[$i] -like "*Reading*") { $readStartIndex = $i; break }
    }
    if ($readStartIndex -eq -1) { return $null }
    $readSection = $Output[($readStartIndex + 1)..($Output.Length - 1)]
    $hexLines = $readSection | Where-Object { $_ -match "^[0-9a-fA-F\s]+$" }
    $bytes = $hexLines -join " " -split "\s+" | Where-Object { $_ -ne "" }
    return $bytes
}

function Query-BatteryFeature {
    # Feature Report protocol (A880/A883/A884). Returns @{Battery;Charging} or $null.
    param([int]$MaxTries)
    $targetId = 2
    $sendPayload = "0,0,0,$targetId,2,0,131" + (",$([string]::Join(",", (1..57 | ForEach-Object { '0' })))")

    for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
        & $hidapiPath --vidpid $VendorId --usagePage 0xFFFF --usage 0 -l 65 --open --send-feature $sendPayload --close *> $null
        Start-Sleep -Milliseconds 120
        $output = & $hidapiPath --vidpid $VendorId --usagePage 0xFFFF --usage 0 -l 65 --open --read-feature 0 -q

        $bytes = Parse-HexBytes -Output $output
        if ($null -eq $bytes -or $bytes.Length -lt 10) { Start-Sleep -Milliseconds 80; continue }

        $status = [Convert]::ToInt32($bytes[1], 16)
        $cmdAck = [Convert]::ToInt32($bytes[6], 16)
        if ($status -eq 0xA1 -and $cmdAck -eq 0x83) {
            return @{ Battery = [Convert]::ToInt32($bytes[8], 16); Charging = [Convert]::ToInt32($bytes[7], 16) }
        }
        Start-Sleep -Milliseconds 80
    }
    return $null
}

function Query-BatteryInterrupt {
    # Interrupt Endpoint protocol (A887/A888). Returns @{Battery;Charging} or $null.
    # Writes a 64-byte output report, then reads an input report.
    # hidapitester --send-output/--read-input use a buffer of -l length; for no-reportId devices
    # the report byte itself is data (no reportId prefix).
    param([int]$MaxTries)

    # 64-byte output report: [0]=0x04, [3]=0x1a (battery cmd), rest 0
    $outputPayload = "4,0,0,26" + (",$([string]::Join(",", (1..60 | ForEach-Object { '0' })))")

    for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
        # Open with the WLMouse vendor filter (PID is implicit via --vidpid prefix).
        # usage 0x06 = "control" interface per wlmouse-cli; pick it when available, else fall through.
        & $hidapiPath --vidpid $VendorId --usage 6 -l 64 --open --send-output $outputPayload --close *> $null
        Start-Sleep -Milliseconds 120
        $output = & $hidapiPath --vidpid $VendorId --usage 6 -l 64 --open --read-input -t 500 -q

        $bytes = Parse-HexBytes -Output $output
        if ($null -eq $bytes -or $bytes.Length -lt 10) { Start-Sleep -Milliseconds 80; continue }

        # Per wlmouse-cli, battery is at offset 8 of the interrupt read buffer.
        $battery = [Convert]::ToInt32($bytes[8], 16)
        # Validate: must be a plausible percentage (0..100). Anything else means stale/garbage.
        if ($battery -ge 0 -and $battery -le 100) {
            # Charging flag offset is not consistently documented for Interrupt devices; default to 0.
            return @{ Battery = $battery; Charging = 0 }
        }
        Start-Sleep -Milliseconds 80
    }
    return $null
}

function Query-MouseBattery {
    # Dispatches to the right protocol based on the detected device, with fallback for unknown PIDs.
    param([string]$Protocol, [int]$MaxTries)

    if ($Protocol -eq "Feature")   { return Query-BatteryFeature   -MaxTries $MaxTries }
    if ($Protocol -eq "Interrupt") { return Query-BatteryInterrupt -MaxTries $MaxTries }

    # Auto: try Feature first (more common on recent models), then Interrupt.
    $r = Query-BatteryFeature -MaxTries $MaxTries
    if ($null -ne $r) { return $r }
    return Query-BatteryInterrupt -MaxTries $MaxTries
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
    Write-Log "No WLMouse device found (VID $VendorId)."
} else {
    Write-Log "Detected $($device.Name) (PID $($device.Pid), protocol: $($device.Protocol))."
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
    $protocol = if ($device) { $device.Protocol } else { "Auto" }
    $result = Query-MouseBattery -Protocol $protocol -MaxTries $QueryMaxTries
    $script:lastResult = $result

    if ($null -eq $result) {
        $notify.Icon = (New-BatteryIcon -Battery 0 -Charging 0 -LowThreshold $script:LowThreshold)
        $dev = if ($device) { $device.Name } else { "장치 없음" }
        $notify.Text = "WLMouse ($dev): 응답 없음"
        Write-Log "No active response from mouse (protocol: $protocol)."
        return
    }

    $battery  = $result.Battery
    $charging = $result.Charging

    # Battery 🔋 / lightning ⚡ literals (surrogate-pair code points can't go through [char])
    $tipIcon = if ($charging -eq 1) { "⚡" } else { "🔋" }
    $notify.Text = "$tipIcon $($device.Name): $battery%"
    $notify.Icon = (New-BatteryIcon -Battery $battery -Charging $charging -LowThreshold $script:LowThreshold)
    Write-Log "Tray updated. Battery: $battery%, Charging: $charging, Threshold: $($script:LowThreshold)%, Protocol: $protocol"
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
