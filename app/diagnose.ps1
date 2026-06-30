# Diagnostics for WLMouse Battery Tray Monitor
# Runs every probe that matters and writes a single text report a user can attach
# to a GitHub issue. Collects only technical info (no credentials, no PII beyond
# Windows version / device model).

$ErrorActionPreference = 'Continue'  # keep going so one failure doesn't abort the whole report

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($null -eq $AppDir -or $AppDir -eq "") { $AppDir = Join-Path "D:\wlbattery" "app" }
$ProjectDir = Split-Path -Parent $AppDir
$DataDir = Join-Path $ProjectDir "data"
$hidapiPath = Join-Path $ProjectDir "vendor\hidapitester\hidapitester.exe"
$ReportPath = Join-Path $ProjectDir "diagnostic_report.txt"
$VendorId = "36A7"

# Known PIDs (must mirror wlmouse_battery_tray.ps1)
$KnownPids = @{
    "A880" = @{ Name = "Beast MAX 8K Receiver"; Protocol = "Feature" }
    "A883" = @{ Name = "Beast X 8K Receiver";   Protocol = "Feature" }
    "A884" = @{ Name = "Beast X 8K";            Protocol = "Feature" }
    "A887" = @{ Name = "Beast X Receiver";      Protocol = "Interrupt" }
    "A888" = @{ Name = "Beast X";               Protocol = "Interrupt" }
}

# Start with a fresh report
$report = New-Object System.Collections.ArrayList

function Write-Section($title) {
    $null = $report.Add("")
    $null = $report.Add("=" * 60)
    $null = $report.Add($title)
    $null = $report.Add("=" * 60)
}
function Write-Line($line = "") { $null = $report.Add($line) }

Write-Host "Generating diagnostic report -> $ReportPath"
Write-Host "(이 과정은 약 30초 소요됩니다 / This takes ~30 seconds)"

# --- Header ---
Write-Section "WLMouse Battery Tray Monitor - Diagnostic Report"
Write-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Write-Line "Report version: 1"

# --- System info ---
Write-Section "1. System Information"
$os = Get-CimInstance Win32_OperatingSystem
Write-Line "OS: $($os.Caption) $($os.Version) (Build $($os.BuildNumber))"
Write-Line "Architecture: $env:PROCESSOR_ARCHITECTURE"
Write-Line "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Line ".NET version: $($PSVersionTable.CLRVersion)"

# --- Tool presence ---
Write-Section "2. Tool Check"
if (Test-Path $hidapiPath) {
    $info = Get-Item $hidapiPath
    Write-Line "hidapitester.exe: FOUND ($(($info.Length)) bytes at $($info.FullName))"
    Write-Line ""
    Write-Line "hidapitester version:"
    $verOut = & $hidapiPath --version 2>&1
    $verOut | ForEach-Object { Write-Line "    $_" }
} else {
    Write-Line "hidapitester.exe: NOT FOUND at $hidapiPath"
    Write-Line "    (This is the root cause. Re-download the repo or restore the binary.)"
}

# --- Connected WLMouse devices ---
Write-Section "3. Connected WLMouse Devices (VID 0x$VendorId)"
if (-not (Test-Path $hidapiPath)) {
    Write-Line "(skipped — hidapitester.exe missing)"
} else {
    Write-Line "Raw --list-detail output:"
    Write-Line "----"
    $listing = & $hidapiPath --vidpid $VendorId --list-detail 2>&1
    if ($null -eq $listing -or $listing.Count -eq 0) {
        Write-Line "(no devices with VID 0x$VendorId found)"
        Write-Line ""
        Write-Line "Likely causes:"
        Write-Line "  - Receiver not plugged in"
        Write-Line "  - Mouse powered off / battery dead"
        Write-Line "  - Driver not installed"
    } else {
        $listing | ForEach-Object { Write-Line "    $_" }
    }
    Write-Line "----"

    # Detect PID(s)
    $detectedPids = @()
    foreach ($line in $listing) {
        if ($line -match "productId:\s*0x([0-9A-Fa-f]{4})") {
            $p = $matches[1].ToUpper()
            if ($detectedPids -notcontains $p) { $detectedPids += $p }
        }
    }
    Write-Line ""
    Write-Line "Detected PIDs: $(if ($detectedPids) { ($detectedPids -join ', ') } else { '(none)' })"
    foreach ($p in $detectedPids) {
        if ($KnownPids.ContainsKey($p)) {
            Write-Line "  $p -> $($KnownPids[$p].Name) [protocol: $($KnownPids[$p].Protocol)]"
        } else {
            Write-Line "  $p -> UNKNOWN model (will try both protocols at runtime)"
        }
    }
}

# --- Protocol test: Feature Report (if any device is present) ---
Write-Section "4. Feature Report Protocol Test"
if (-not (Test-Path $hidapiPath) -or $detectedPids.Count -eq 0) {
    Write-Line "(skipped — no device present)"
} else {
    $targetId = 2
    $sendPayload = "0,0,0,$targetId,2,0,131" + (",$([string]::Join(",", (1..57 | ForEach-Object { '0' })))")
    Write-Line "Sending battery query (cmd 0x83) and reading response..."
    & $hidapiPath --vidpid $VendorId --usagePage 0xFFFF --usage 0 -l 65 --open --send-feature $sendPayload --close *> $null
    Start-Sleep -Milliseconds 150
    $response = & $hidapiPath --vidpid $VendorId --usagePage 0xFFFF --usage 0 -l 65 --open --read-feature 0 -q 2>&1

    Write-Line "Raw response:"
    Write-Line "----"
    if ($null -eq $response -or $response.Count -eq 0) {
        Write-Line "(empty)"
    } else {
        $response | ForEach-Object { Write-Line "    $_" }
    }
    Write-Line "----"

    # Parse and interpret
    $readStartIndex = -1
    for ($i = 0; $i -lt $response.Length; $i++) {
        if ($response[$i] -like "*Reading*") { $readStartIndex = $i; break }
    }
    if ($readStartIndex -ge 0) {
        $hexLines = $response[($readStartIndex + 1)..($response.Length - 1)] | Where-Object { $_ -match "^[0-9a-fA-F\s]+$" }
        $bytes = $hexLines -join " " -split "\s+" | Where-Object { $_ -ne "" }
        if ($bytes.Length -ge 10) {
            $statusHex = $bytes[1]
            $cmdAckHex = $bytes[6]
            $status = [Convert]::ToInt32($statusHex, 16)
            $cmdAck = [Convert]::ToInt32($cmdAckHex, 16)
            Write-Line ""
            Write-Line "Interpretation:"
            Write-Line "  status byte:  0x$statusHex ($status)  -> $(if ($status -eq 0xA1) { 'ACTIVE (good)' } elseif ($status -eq 0xA0) { 'IDLE/ASLEEP (try moving the mouse)' } else { 'unknown' })"
            Write-Line "  cmd echo:     0x$cmdAckHex ($cmdAck)  -> $(if ($cmdAck -eq 0x83) { 'matches request (good)' } else { 'mismatch' })"
            Write-Line "  battery byte: 0x$($bytes[8]) -> $(if ($bytes[8] -match '^[0-9a-fA-F]{2}$') { [Convert]::ToInt32($bytes[8], 16).ToString() + '%' } else { '?' })"
            Write-Line "  charging byte: 0x$($bytes[9])"

            if ($status -ne 0xA1) {
                Write-Line ""
                Write-Line "NOTE: device did not respond as active. Move/wake the mouse and re-run diagnose."
            }
        } else {
            Write-Line "Response too short to parse."
        }
    } else {
        Write-Line "No 'Reading' section in response — device did not return a feature report."
    }
}

# --- Protocol test: Interrupt Endpoint ---
Write-Section "5. Interrupt Endpoint Protocol Test"
if (-not (Test-Path $hidapiPath) -or $detectedPids.Count -eq 0) {
    Write-Line "(skipped — no device present)"
} else {
    $outputPayload = "4,0,0,26" + (",$([string]::Join(",", (1..60 | ForEach-Object { '0' })))")
    Write-Line "Sending output report (cmd 0x1a) and reading input report..."
    & $hidapiPath --vidpid $VendorId --usage 6 -l 64 --open --send-output $outputPayload --close *> $null
    Start-Sleep -Milliseconds 150
    $response = & $hidapiPath --vidpid $VendorId --usage 6 -l 64 --open --read-input -t 500 -q 2>&1

    Write-Line "Raw response:"
    Write-Line "----"
    if ($null -eq $response -or $response.Count -eq 0) {
        Write-Line "(empty — device may not use Interrupt protocol, which is normal for Feature-report devices)"
    } else {
        $response | ForEach-Object { Write-Line "    $_" }
    }
    Write-Line "----"
}

# --- Recent tray monitor log (last 30 lines) ---
$LogPath = Join-Path $DataDir "wlmouse_battery.log"
Write-Section "6. Recent Monitor Log (last 30 lines)"
if (Test-Path $LogPath) {
    Write-Line "(from $LogPath)"
    Write-Line "----"
    Get-Content $LogPath -Tail 30 -Encoding UTF8 | ForEach-Object { Write-Line "    $_" }
    Write-Line "----"
} else {
    Write-Line "No log file found at $LogPath"
    Write-Line "(This means the tray monitor has never run successfully.)"
}

# --- Settings ---
$SettingsPath = Join-Path $DataDir "settings.json"
Write-Section "7. Settings"
if (Test-Path $SettingsPath) {
    Write-Line "(from $SettingsPath)"
    Write-Line "----"
    Get-Content $SettingsPath -Encoding UTF8 | ForEach-Object { Write-Line "    $_" }
    Write-Line "----"
} else {
    Write-Line "No settings.json (using defaults: LowThreshold=20%, PollInterval=300s)"
}

# --- Footer ---
Write-Section "End of Report"
Write-Line "Please attach this file (diagnostic_report.txt) when opening a GitHub issue."
Write-Line "Issue URL: https://github.com/minerva32/wlmouse-battery-tray/issues"

# --- Write to disk ---
$report -join "`r`n" | Set-Content $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " Report saved to: $ReportPath"
Write-Host " Size: $((Get-Item $ReportPath).Length) bytes"
Write-Host "============================================================"
Write-Host ""
Write-Host "이 파일을 GitHub 이슈에 첨부해 주세요."
Write-Host "Please attach this file to your GitHub issue:"
Write-Host "  https://github.com/minerva32/wlmouse-battery-tray/issues"
Write-Host ""
Write-Host "보고서 내용을 미리 보시겠습니까? Preview the report now? (Y/N)"
$preview = Read-Host
if ($preview -eq 'Y' -or $preview -eq 'y') {
    Get-Content $ReportPath -Encoding UTF8
}
