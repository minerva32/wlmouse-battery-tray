# WLMouse Battery Tray Monitor
# Live system-tray icon showing the battery percentage of any WLMouse mouse
# (Beast MAX 8K / Beast X 8K / Beast X / receivers / Mini / Pro / Miao, VID 0x36A7).
#
# Protocol is reverse-engineered (matches mee7ya/wlmouse-cli + snems/WLPower):
#   - Feature Report devices (A870/A878/A880/A883/A884): send 65-byte feature report with
#     cmd 0x83 at offset 6 -> ~120ms wait -> read feature report.
#     Active response: bytes[1]=0xA1 (status) AND bytes[6]=0x83 (cmd echo).
#     bytes[8] = battery %, bytes[7] = charging flag (0x01 = charging).
#   - Interrupt Endpoint devices (A887/A888): write 64-byte output report with
#     cmd 0x1a at offset 3 -> ~100ms wait -> read input report.
#     bytes[8] = battery %.
# Exact VID:PID is used after detection; vendor-only opens can select the wrong HID collection.
# Unknown PIDs in the 0x36A7 vendor are tried with BOTH protocols in sequence.

$VendorId = "36A7"

# Known WLMouse product IDs (auto-detected at startup).
# Source: mee7ya/wlmouse-cli + ebnimaa/wlmouse-beastx-windows + linux-usb.org
$KnownPids = @{
    "A860" = @{ Name = "WLMouse Receiver (A860)";  Protocol = "Feature" }
    "A866" = @{ Name = "Miao 8K Receiver";         Protocol = "Feature" }
    "A867" = @{ Name = "Miao";                     Protocol = "Feature" }
    "A868" = @{ Name = "Beast X Mini Pro";         Protocol = "Feature" }
    "A870" = @{ Name = "Beast X Pro 8K Receiver";  Protocol = "Feature" }
    "A878" = @{ Name = "Sword X 8K Receiver";      Protocol = "Feature" }
    "A880" = @{ Name = "Beast MAX 8K Receiver";    Protocol = "Feature" }
    "A883" = @{ Name = "Beast X 8K Receiver";      Protocol = "Feature" }
    "A884" = @{ Name = "Beast X 8K";               Protocol = "Feature" }
    "A885" = @{ Name = "Beast X Mini Receiver";    Protocol = "Feature" }
    "A887" = @{ Name = "Beast X Receiver";         Protocol = "Interrupt" }
    "A888" = @{ Name = "Beast X";                  Protocol = "Interrupt" }
}

# Status bytes seen at response[1]. 0xA1/0xA2 carry a live battery value;
# 0xA0 is a valid reply from a sleeping/idle mouse (battery byte is 0 and must NOT be shown as 0%).
$StatusActive   = @(0xA1, 0xA2)
$StatusSleeping = 0xA0

# Default settings (overridden by settings.json if present)
$PollIntervalSeconds = 300
$LowThreshold        = 20
$ThresholdChoices    = @(10, 15, 20, 30)
$StartupRefreshDelaysSeconds = @(5, 15, 30, 60)

# Minimum gap between multi-receiver rescans. Detection probes every receiver, and that work
# happens on the UI thread, so a sleeping mouse must not trigger a full rescan on every poll.
$RescanCooldownSeconds = 60

# Paths
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($null -eq $AppDir -or $AppDir -eq "") { $AppDir = Join-Path "D:\wlbattery" "app" }
$ProjectDir = Split-Path -Parent $AppDir
$DataDir = Join-Path $ProjectDir "data"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$hidapiPath    = Join-Path $ProjectDir "vendor\hidapitester\hidapitester.exe"
$LogPath       = Join-Path $DataDir "wlmouse_battery.log"
$SettingsPath  = Join-Path $DataDir "settings.json"
$DiagnosePath  = Join-Path $AppDir "diagnose.ps1"

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
function Get-HidCollections {
    # Parses `--list-detail` into one object per HID collection, keeping the exact device path.
    # The path is what makes queries reliable: --usagePage/--usage filters can select the wrong
    # collection (or none) on receivers whose vendor page is not 0xFFFF, which is the root cause of
    # "Get Input/Feature Report DeviceIoControl: (0x00000001)" on several models.
    if (-not (Test-Path $hidapiPath)) { return @() }
    $lines = (& $hidapiPath --vidpid $VendorId --list-detail 2>&1) -split "`r?`n"

    $collections = @()
    $cur = $null
    foreach ($line in $lines) {
        if ($line -match "productId:\s*0x([0-9A-Fa-f]{4})") {
            if ($null -ne $cur -and $cur.Path) { $collections += $cur }
            $cur = @{ Pid = $matches[1].ToUpper(); UsagePage = $null; Usage = $null; Interface = $null; Path = $null }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -match "usagePage:\s*0x([0-9A-Fa-f]+)") { $cur.UsagePage = [Convert]::ToInt32($matches[1], 16); continue }
        if ($line -match "usage:\s*0x([0-9A-Fa-f]+)")     { $cur.Usage     = [Convert]::ToInt32($matches[1], 16); continue }
        if ($line -match "interface:\s*(-?\d+)")          { $cur.Interface = [int]$matches[1]; continue }
        if ($line -match "path:\s*(\S+)")                 { $cur.Path      = $matches[1]; continue }
    }
    if ($null -ne $cur -and $cur.Path) { $collections += $cur }
    return $collections
}

function Get-VendorCollections {
    # Vendor-defined collections only, best candidate first.
    # Rank: 0xFFFF/usage 0 (documented config interface) > other 0xFFFF > any vendor page >= 0xFF00
    # (covers A887-class receivers that expose 0xFF1C instead of 0xFFFF).
    param($Collections, [string]$DevicePid)

    $mine = @($Collections | Where-Object { $_.Pid -eq $DevicePid })
    $vendor = @($mine | Where-Object { $null -ne $_.UsagePage -and $_.UsagePage -ge 0xFF00 })
    if ($vendor.Count -eq 0) { return @() }

    return @($vendor | Sort-Object @{
        Expression = {
            if ($_.UsagePage -eq 0xFFFF -and $_.Usage -eq 0) { 0 }
            elseif ($_.UsagePage -eq 0xFFFF)                 { 1 }
            else                                             { 2 }
        }
    }, @{ Expression = { $_.Interface } })
}

function Detect-Devices {
    # Returns EVERY connected WLMouse receiver, not just the first one.
    # Previously a known PID won over an unknown one, so a user with several receivers
    # (e.g. mini + Miao + Sword X) could have the app query a receiver they were not using.
    $collections = Get-HidCollections
    if ($collections.Count -eq 0) { return @() }

    $devices = @()
    foreach ($devPid in (@($collections | ForEach-Object { $_.Pid }) | Select-Object -Unique)) {
        $vendorCols = Get-VendorCollections -Collections $collections -DevicePid $devPid
        if ($KnownPids.ContainsKey($devPid)) {
            $name = $KnownPids[$devPid].Name
            $protocol = $KnownPids[$devPid].Protocol
        } else {
            $name = "WLMouse (PID $devPid)"
            $protocol = "Auto"
        }
        $devices += @{
            Pid         = $devPid
            Name        = $name
            Protocol    = $protocol
            VendorPaths = @($vendorCols | ForEach-Object { $_.Path })
            VendorInfo  = $vendorCols
        }
    }
    return $devices
}

function Detect-Device {
    # Backwards-compatible single-device entry point: prefer a receiver whose mouse is AWAKE.
    #
    # Two-pass selection matters when several receivers are plugged in at once (issue #8).
    # A sleeping receiver answers status 0xA0, which proves the transport works but carries no
    # battery value. Returning on the first 0xA0 meant a powered-off mini could win over an
    # awake Miao, so the tray showed the wrong model and never displayed a percentage.
    # NOTE: @() is required. PowerShell unrolls a single-element array on return, so a lone
    # receiver would come back as a bare hashtable and $devices[0] / .Count would be wrong.
    $devices = @(Detect-Devices)
    if ($devices.Count -eq 0) { return $null }
    if ($devices.Count -eq 1) { return $devices[0] }

    # Pass 1: a receiver reporting a real battery percentage always wins.
    $sleeping = @()
    foreach ($d in $devices) {
        $probe = Query-MouseBattery -Protocol $d.Protocol -DevicePid $d.Pid -MaxTries 1 -VendorPaths $d.VendorPaths
        if ($null -eq $probe) { continue }
        if ($probe.Battery -ge 0) {
            # Name already includes the PID for unknown devices ("WLMouse (PID A881)"), so do
            # not append it again here.
            Write-Log "Selected $($d.Name): active reading $($probe.Battery)%."
            return $d
        }
        if ($probe.Sleeping) { $sleeping += $d }
    }

    # Pass 2: nobody is awake. Fall back to a receiver that at least answered the protocol.
    if ($sleeping.Count -gt 0) {
        $pick = $sleeping[0]
        $names = ($sleeping | ForEach-Object { "$($_.Name) (PID $($_.Pid))" }) -join ", "
        Write-Log "No awake mouse found; all sleeping: $names. Provisionally using $($pick.Name)."
        return $pick
    }

    # PowerShell 5.1 has no null-coalescing operator; fall back explicitly.
    $knownFirst = @($devices | Where-Object { $KnownPids.ContainsKey($_.Pid) }) | Select-Object -First 1
    if ($null -ne $knownFirst) { return $knownFirst }
    return $devices[0]
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
    # Feature Report protocol. Returns @{Battery;Charging} or $null.
    param([string]$DevicePid, [int]$MaxTries, [string[]]$VendorPaths)
    $targetId = 2
    $vidPid = if ($DevicePid) { "${VendorId}:$($DevicePid)" } else { $VendorId }
    $sendPayload = "0,0,0,$targetId,2,0,131" + (",$([string]::Join(",", (1..57 | ForEach-Object { '0' })))")

    # Prefer exact device paths from --list-detail. Filtering by --usagePage/--usage can open the
    # wrong HID collection (or fail outright) on receivers whose vendor page is not 0xFFFF.
    # Verified locally on 36A7:A880: --open-path on the interface-2 collection returns
    # `00 A0 00 02 02 00 83 ...` while the usage-1 collection fails with HidD_SetFeature error 1.
    $targets = @()
    foreach ($vp in @($VendorPaths)) { if ($vp) { $targets += @{ Kind = "Path"; Value = $vp } } }
    foreach ($u in @(0, 1))          { $targets += @{ Kind = "Usage"; Value = $u } }

    # Set when any target returns a valid sleeping reply (status 0xA0 + cmd echo 0x83).
    $sleepSeen = $false

    foreach ($target in $targets) {
        if ($target.Kind -eq "Path") {
            # --open-path opens the device immediately. Appending --open makes hidapitester
            # run a SECOND open with EMPTY filters (vid/pid 0x0000, usagePage/usage 0), which
            # silently rebinds the handle to an arbitrary HID device (a keyboard on the test
            # machine). Every feature request then failed with HidD_SetFeature (0x00000001),
            # surfacing as "응답 없음". diagnose.ps1 never appended --open, which is why the
            # diagnostic report looked healthy while the tray reported no response.
            $openArgs = @("--open-path", $target.Value)
        } else {
            $openArgs = @("--vidpid", $vidPid, "--usagePage", "0xFFFF", "--usage", $target.Value, "--open")
        }

        # A 0xA0 reply only means "asleep" when it comes from a read that the device had a
        # chance to prepare. Confirm it on the reliable send/close + reopen/read path below
        # before showing "절전 중", so an awake mouse is never mislabelled.
        # Confirmations are tracked per target path; $sleepSeen records that at least one target
        # produced a valid sleeping reply so the caller can distinguish "asleep" from "no answer".
        $sleepConfirmations = 0

        # Fast path: single-handle Set+Get on ONE hidapitester session. Some firmware answers
        # here immediately, so it is worth one attempt.
        # Only an ACTIVE status is trusted from this path. Measured on 36A7:A880 while the
        # mouse was awake and reporting 82%, this zero-delay read returned a stale buffer
        # (status 0x00) or a stale 0xA0 on every single attempt, while send/close + reopen/read
        # returned 0xA1/82% every time. Accepting 0xA0 here therefore made the tray announce
        # "절전 중"/"응답 없음" for a healthy mouse and skip the read that actually works.
        $output = & $hidapiPath @openArgs -l 65 --send-feature $sendPayload --read-feature 0 -q
        $bytes = Parse-HexBytes -Output $output
        if ($null -ne $bytes -and $bytes.Length -ge 10) {
            $status = [Convert]::ToInt32($bytes[1], 16)
            $cmdAck = [Convert]::ToInt32($bytes[6], 16)
            # 0xA1 and 0xA2 both carry a live reading (0xA2 seen on Beast X Mini Pro-class firmware).
            if ($StatusActive -contains $status -and $cmdAck -eq 0x83) {
                return @{ Battery = [Convert]::ToInt32($bytes[8], 16); Charging = [Convert]::ToInt32($bytes[7], 16) }
            }
        }
        for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
            & $hidapiPath @openArgs -l 65 --send-feature $sendPayload --close *> $null
            Start-Sleep -Milliseconds 120
            $output = & $hidapiPath @openArgs -l 65 --read-feature 0 -q

            $bytes = Parse-HexBytes -Output $output
            if ($null -eq $bytes -or $bytes.Length -lt 10) { Start-Sleep -Milliseconds 80; continue }

            $status = [Convert]::ToInt32($bytes[1], 16)
            $cmdAck = [Convert]::ToInt32($bytes[6], 16)
            if ($StatusActive -contains $status -and $cmdAck -eq 0x83) {
                return @{ Battery = [Convert]::ToInt32($bytes[8], 16); Charging = [Convert]::ToInt32($bytes[7], 16) }
            }
            # 0xA0 = receiver answered but the mouse is asleep. Require two confirmations so a
            # mouse that wakes mid-poll still gets a chance to report a real percentage.
            if ($status -eq $StatusSleeping -and $cmdAck -eq 0x83) {
                $sleepConfirmations++
                $sleepSeen = $true
                if ($sleepConfirmations -ge 2) {
                    return @{ Battery = -1; Charging = 0; Sleeping = $true }
                }
            }
            Start-Sleep -Milliseconds 80
        }
    }
    # Only after every target has been tried: a single valid 0xA0 anywhere still means the
    # receiver is reachable and the mouse is idle, which is more accurate than "응답 없음".
    # Reporting it here (instead of returning early) lets a later vendor path still win with a
    # real percentage.
    if ($sleepSeen) {
        return @{ Battery = -1; Charging = 0; Sleeping = $true }
    }
    return $null
}

function Query-BatteryInterrupt {
    # Interrupt Endpoint protocol. Returns @{Battery;Charging} or $null.
    # Writes a 64-byte output report, then reads an input report.
    # hidapitester --send-output/--read-input use a buffer of -l length; for no-reportId devices
    # the report byte itself is data (no reportId prefix).
    param([string]$DevicePid, [int]$MaxTries, [string[]]$VendorPaths)

    # 64-byte output report: [0]=0x04, [3]=0x1a (battery cmd), rest 0
    $outputPayload = "4,0,0,26" + (",$([string]::Join(",", (1..60 | ForEach-Object { '0' })))")
    $vidPid = if ($DevicePid) { "${VendorId}:$($DevicePid)" } else { $VendorId }

    # A887-class receivers expose no 0xFFFF page at all (only e.g. 0xFF1C/usage 0x92), so the old
    # `--usage 6` filter opened the wrong collection. Try exact vendor paths first.
    $targets = @()
    foreach ($vp in @($VendorPaths)) { if ($vp) { $targets += @{ Kind = "Path"; Value = $vp } } }
    $targets += @{ Kind = "Usage"; Value = 6 }

    foreach ($target in $targets) {
        if ($target.Kind -eq "Path") {
            # See Query-BatteryFeature: --open-path already opens the device, and appending
            # --open rebinds the handle to an arbitrary HID device with empty filters.
            $openArgs = @("--open-path", $target.Value)
        } else {
            $openArgs = @("--vidpid", $vidPid, "--usage", $target.Value, "--open")
        }

    # Fast path: single-handle write+read on ONE hidapitester session.
    # Matches the verified reference (mee7ya/wlmouse-cli), which does write() then read()
    # on the SAME device handle. The two-handle write/close + reopen/read below can drop the
    # device-side response on some firmware revisions (root cause for Interrupt devices too).
        $output = & $hidapiPath @openArgs -l 64 --send-output $outputPayload --read-input -t 500 -q
    $bytes = Parse-HexBytes -Output $output
    if ($null -ne $bytes -and $bytes.Length -ge 10) {
        $battery = [Convert]::ToInt32($bytes[8], 16)
            if ($battery -gt 0 -and $battery -le 100) {
            return @{ Battery = $battery; Charging = 0 }
        }
    }

    for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
        # Open the exact detected receiver PID; vendor-only filtering can hit the wrong collection.
        # usage 0x06 = "control" interface per wlmouse-cli; pick it when available, else fall through.
            & $hidapiPath @openArgs -l 64 --send-output $outputPayload --close *> $null
        Start-Sleep -Milliseconds 120
            $output = & $hidapiPath @openArgs -l 64 --read-input -t 500 -q

        $bytes = Parse-HexBytes -Output $output
        if ($null -eq $bytes -or $bytes.Length -lt 10) { Start-Sleep -Milliseconds 80; continue }

        # Per wlmouse-cli, battery is at offset 8 of the interrupt read buffer.
        $battery = [Convert]::ToInt32($bytes[8], 16)
            # Require 1..100: a literal 0 here is almost always a stale/empty buffer, not a real reading.
            # Trade-off: a genuinely fully-drained mouse is reported as "no answer" rather than 0%.
            if ($battery -gt 0 -and $battery -le 100) {
            # Charging flag offset is not consistently documented for Interrupt devices; default to 0.
            return @{ Battery = $battery; Charging = 0 }
        }
            if ($battery -eq 0) {
                Write-Log "Interrupt read returned battery byte 0 (treated as stale buffer, not 0%)."
            }
        Start-Sleep -Milliseconds 80
    }
    }
    return $null
}

function Query-MouseBattery {
    # Dispatches to the right protocol based on the detected device, with fallback for unknown PIDs.
    param([string]$Protocol, [string]$DevicePid, [int]$MaxTries, [string[]]$VendorPaths)

    if ($Protocol -eq "Feature")   { return Query-BatteryFeature   -DevicePid $DevicePid -MaxTries $MaxTries -VendorPaths $VendorPaths }
    if ($Protocol -eq "Interrupt") { return Query-BatteryInterrupt -DevicePid $DevicePid -MaxTries $MaxTries -VendorPaths $VendorPaths }

    # Auto: try Feature first (more common on recent models), then Interrupt.
    $r = Query-BatteryFeature -DevicePid $DevicePid -MaxTries $MaxTries -VendorPaths $VendorPaths
    if ($null -ne $r) { return $r }
    return Query-BatteryInterrupt -DevicePid $DevicePid -MaxTries $MaxTries -VendorPaths $VendorPaths
}

# --- Build the tray icon as a drawn bitmap (black bg, colored fg by state) ---
function New-BatteryIcon {
    param([int]$Battery, [int]$Charging, [int]$LowThreshold)

    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $bg = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
    if ($Battery -lt 0) {
        $fg = [System.Drawing.Color]::FromArgb(255, 180, 180, 180)   # gray (unknown / no response yet)
    } elseif ($Charging -eq 1) {
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
        if ($Battery -lt 0) { $label = "?" } elseif ($Battery -ge 100) { $label = "F" } else { $label = [string]$Battery }
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
$script:device = Detect-Device
$device = $script:device
if ($null -eq $device) {
    Write-Log "No WLMouse device found (VID $VendorId)."
} else {
    Write-Log "Detected $($device.Name) (PID $($device.Pid), protocol: $($device.Protocol))."
}

# --- Build the notify icon + context menu ---
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = (New-BatteryIcon -Battery -1 -Charging 0 -LowThreshold $LowThreshold)
$notify.Visible = $true
$notify.Text    = "WLMouse: querying..."

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$refreshItem = $menu.Items.Add("지금 새로고침")
$diagnoseItem = $menu.Items.Add("진단 리포트 만들기")

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
$script:startupRetryTimers = @()
# Last multi-receiver rescan (UTC). MinValue means "never", so the first miss may rescan.
$script:lastRescanUtc = [DateTime]::MinValue

function Update-Tray {
    # Re-detect when the cached receiver has nothing to report. The device used to be chosen once
    # at startup, so a receiver picked while its mouse was asleep stayed selected forever and a
    # mouse woken up later (or plugged in later) was never queried again (issue #8).
    #
    # This runs on the WinForms UI thread, so the rescan is bounded: it only happens when more
    # than one receiver is present (with a single receiver there is nothing else to choose) and
    # at most once per $RescanCooldownSeconds, so a sleeping mouse cannot re-probe every poll.
    $protocol    = if ($script:device) { $script:device.Protocol } else { "Auto" }
    $devicePid   = if ($script:device) { $script:device.Pid } else { $null }
    $vendorPaths = if ($script:device) { $script:device.VendorPaths } else { @() }
    $result = Query-MouseBattery -Protocol $protocol -DevicePid $devicePid -MaxTries $QueryMaxTries -VendorPaths $vendorPaths

    if ($null -eq $result -or $result.Sleeping) {
        $livePids = @(Get-HidCollections | ForEach-Object { $_.Pid } | Select-Object -Unique)
        $receiverCount = $livePids.Count
        $cachedPid = if ($script:device) { $script:device.Pid } else { $null }
        # A charging dock or USB replug can expose a transient receiver PID (e.g. A880 briefly
        # becomes A881), then disappear. When that happens the cached device points at a PID
        # that is no longer connected, so every subsequent poll reports "응답 없음" until the
        # tray is restarted. Detect that and re-detect immediately, ignoring the cooldown.
        $cachedGone = ($null -ne $cachedPid) -and ($livePids -notcontains $cachedPid)
        $sinceRescan = ([DateTime]::UtcNow - $script:lastRescanUtc).TotalSeconds
        if ($cachedGone -or ($receiverCount -gt 1 -and $sinceRescan -ge $RescanCooldownSeconds)) {
            $script:lastRescanUtc = [DateTime]::UtcNow
            $previousPid = if ($script:device) { $script:device.Pid } else { "none" }
            $rescan = Detect-Device
            if ($null -ne $rescan -and $rescan.Pid -ne $previousPid) {
                Write-Log "Re-detected receiver: $($rescan.Name) (PID $($rescan.Pid)) replaces $previousPid."
                $script:device = $rescan
                $result = Query-MouseBattery -Protocol $rescan.Protocol -DevicePid $rescan.Pid -MaxTries $QueryMaxTries -VendorPaths $rescan.VendorPaths
            }
        }
    }

    $device = $script:device
    if ($null -eq $result) {
        $dev = if ($device) { $device.Name } else { "장치 없음" }
        if ($script:lastResult) {
            $r = $script:lastResult
            $notify.Icon = (New-BatteryIcon -Battery $r.Battery -Charging $r.Charging -LowThreshold $script:LowThreshold)
            $notify.Text = "WLMouse ($dev): 응답 없음 (마지막: $($r.Battery)%)"
            Write-Log "No active response from mouse; keeping last reading $($r.Battery)% (protocol: $protocol)."
        } else {
            $notify.Icon = (New-BatteryIcon -Battery -1 -Charging 0 -LowThreshold $script:LowThreshold)
            $notify.Text = "WLMouse ($dev): 응답 없음"
            Write-Log "No active response from mouse (protocol: $protocol)."
        }
        return
    }

    # Receiver replied with status 0xA0: the mouse itself is asleep. This is NOT a 0% battery.
    if ($result.Sleeping) {
        $dev = if ($device) { $device.Name } else { "장치 없음" }
        if ($script:lastResult) {
            $r = $script:lastResult
            $notify.Icon = (New-BatteryIcon -Battery $r.Battery -Charging $r.Charging -LowThreshold $script:LowThreshold)
            $notify.Text = "WLMouse ($dev): 절전 중 (마지막: $($r.Battery)%)"
        } else {
            $notify.Icon = (New-BatteryIcon -Battery -1 -Charging 0 -LowThreshold $script:LowThreshold)
            $notify.Text = "WLMouse ($dev): 절전 중 - 마우스를 움직여 주세요"
        }
        Write-Log "Receiver answered but mouse is asleep (status 0xA0, protocol: $protocol). Not reporting 0%."
        return
    }

    $script:lastResult = $result

    $battery  = $result.Battery
    $charging = $result.Charging

    # Battery 🔋 / lightning ⚡ literals (surrogate-pair code points can't go through [char])
    $tipIcon = if ($charging -eq 1) { "⚡" } else { "🔋" }
    $notify.Text = "$tipIcon $($device.Name): $battery%"
    $notify.Icon = (New-BatteryIcon -Battery $battery -Charging $charging -LowThreshold $script:LowThreshold)
    Write-Log "Tray updated. Battery: $battery%, Charging: $charging, Threshold: $($script:LowThreshold)%, Protocol: $protocol"
}

function Start-StartupRefreshRetries {
    # During Windows boot the receiver can enumerate before the mouse is ready.
    # Retry quickly for the first minute so the tray does not sit at 0% until the normal 5-minute poll.
    foreach ($delaySeconds in $StartupRefreshDelaysSeconds) {
        $startupTimer = New-Object System.Windows.Forms.Timer
        $startupTimer.Interval = [Math]::Max(1, [int]$delaySeconds) * 1000
        $startupTimer.Tag = $delaySeconds
        $startupTimer.Add_Tick({
            $this.Stop()
            Write-Log "Startup quick refresh after $($this.Tag)s."
            Update-Tray
            $script:startupRetryTimers = @($script:startupRetryTimers | Where-Object { $_ -ne $this })
            $this.Dispose()
        })
        $script:startupRetryTimers += $startupTimer
        $startupTimer.Start()
    }
}

# --- Wire events ---
$refreshItem.Add_Click({ Update-Tray })

$diagnoseItem.Add_Click({
    Write-Log "Launching one-click diagnostic report."
    Start-Process powershell.exe -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$DiagnosePath`"",
        "-NoPrompt",
        "-OpenReport"
    ) -WindowStyle Normal
})

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
    foreach ($startupTimer in $script:startupRetryTimers) {
        $startupTimer.Stop()
        $startupTimer.Dispose()
    }
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# --- Timers: fire immediately, retry quickly at startup, then every $PollIntervalSeconds ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollIntervalSeconds * 1000
$timer.Add_Tick({ Update-Tray })

Write-Log "WLMouse Battery Tray Monitor started (poll every ${PollIntervalSeconds}s, threshold ${LowThreshold}%)."
Update-Tray
Start-StartupRefreshRetries
$timer.Start()

# Run the message loop (keeps the process alive for tray events)
[System.Windows.Forms.Application]::Run()
