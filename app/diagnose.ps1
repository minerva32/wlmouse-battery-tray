# Diagnostics for WLMouse Battery Tray Monitor
# Runs every relevant probe and writes a single text report suitable for a GitHub issue.

param(
    [switch]$NoPrompt,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Continue'  # Keep collecting evidence after an individual probe fails.

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($null -eq $AppDir -or $AppDir -eq "") { $AppDir = Join-Path "D:\wlbattery" "app" }
$ProjectDir = Split-Path -Parent $AppDir
$DataDir = Join-Path $ProjectDir "data"
$hidapiPath = Join-Path $ProjectDir "vendor\hidapitester\hidapitester.exe"
$ReportPath = Join-Path $ProjectDir "diagnostic_report.txt"
$VendorId = "36A7"

# Must mirror wlmouse_battery_tray.ps1.
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

# 0xA1 and 0xA2 have a live battery value. 0xA0 is a valid receiver response
# while the mouse sleeps, and its battery byte must never be displayed as 0%.
$StatusActive = @(0xA1, 0xA2)
$StatusSleeping = 0xA0

$report = New-Object System.Collections.ArrayList
function Write-Section($title) {
    $null = $report.Add("")
    $null = $report.Add("=" * 60)
    $null = $report.Add($title)
    $null = $report.Add("=" * 60)
}
function Write-Line($line = "") { $null = $report.Add($line) }
function Write-RawOutput($Output, [string]$EmptyText) {
    Write-Line "----"
    $outputLines = @($Output)
    if ($outputLines.Count -eq 0) { Write-Line $EmptyText }
    else { $outputLines | ForEach-Object { Write-Line "    $_" } }
    Write-Line "----"
}

function Parse-HexBytes {
    param([string[]]$Output)
    $outputLines = @($Output)
    if ($outputLines.Count -eq 0) { return $null }
    $readStartIndex = -1
    for ($i = 0; $i -lt $outputLines.Length; $i++) {
        if ($outputLines[$i] -like "*Reading*") { $readStartIndex = $i; break }
    }
    if ($readStartIndex -lt 0 -or $readStartIndex -ge ($outputLines.Length - 1)) { return $null }
    $hexLines = @($outputLines[($readStartIndex + 1)..($outputLines.Length - 1)] | Where-Object { $_ -match "^[0-9a-fA-F\s]+$" })
    $bytes = @($hexLines -join " " -split "\s+" | Where-Object { $_ -ne "" })
    if ($bytes.Count -eq 0) { return $null }
    return $bytes
}

function Get-HidCollections {
    # Parse one object per collection and preserve its exact HID path.
    param([string[]]$Listing)
    $collections = @()
    $cur = $null
    foreach ($line in @($Listing)) {
        if ($line -match "productId:\s*0x([0-9A-Fa-f]{4})") {
            if ($null -ne $cur -and $cur.Path) { $collections += $cur }
            $cur = @{ Pid = $matches[1].ToUpper(); UsagePage = $null; Usage = $null; Interface = $null; Path = $null }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -match "usagePage:\s*0x([0-9A-Fa-f]+)") { $cur.UsagePage = [Convert]::ToInt32($matches[1], 16); continue }
        if ($line -match "usage:\s*0x([0-9A-Fa-f]+)")     { $cur.Usage = [Convert]::ToInt32($matches[1], 16); continue }
        if ($line -match "interface:\s*(-?\d+)")          { $cur.Interface = [int]$matches[1]; continue }
        if ($line -match "path:\s*(\S+)")                 { $cur.Path = $matches[1]; continue }
    }
    if ($null -ne $cur -and $cur.Path) { $collections += $cur }
    return @($collections)
}

function Get-VendorCollections {
    # Keep every vendor-defined page. A887-class receivers can expose FF1C/0092,
    # so filtering only FFFF silently loses the correct collection.
    param($Collections, [string]$DevicePid)
    $mine = @($Collections | Where-Object { $_.Pid -eq $DevicePid })
    $vendor = @($mine | Where-Object { $null -ne $_.UsagePage -and $_.UsagePage -ge 0xFF00 })
    return @($vendor | Sort-Object @{ Expression = { if ($_.UsagePage -eq 0xFFFF -and $_.Usage -eq 0) { 0 } elseif ($_.UsagePage -eq 0xFFFF) { 1 } else { 2 } } }, @{ Expression = { $_.Interface } })
}

function Get-FeatureProbeResult {
    param([string[]]$Response)
    $bytes = Parse-HexBytes -Output $Response
    if ($null -eq $bytes -or $bytes.Length -lt 10) { return @{ State = "NoFeatureResponse"; Bytes = $bytes } }
    $status = [Convert]::ToInt32($bytes[1], 16)
    $cmdAck = [Convert]::ToInt32($bytes[6], 16)
    if ($cmdAck -ne 0x83) { return @{ State = "Unexpected"; Bytes = $bytes; Status = $status; CmdAck = $cmdAck } }
    if ($StatusActive -contains $status) { return @{ State = "Active"; Bytes = $bytes; Status = $status; CmdAck = $cmdAck; Battery = [Convert]::ToInt32($bytes[8], 16); Charging = [Convert]::ToInt32($bytes[7], 16) } }
    if ($status -eq $StatusSleeping) { return @{ State = "Sleeping"; Bytes = $bytes; Status = $status; CmdAck = $cmdAck } }
    return @{ State = "UnknownStatus"; Bytes = $bytes; Status = $status; CmdAck = $cmdAck }
}

function Test-FeatureCollection {
    # Invoke via argument splatting: a device path can contain shell-special characters.
    param($Collection)
    $targetId = 2
    $sendPayload = "0,0,0,$targetId,2,0,131" + (",$([string]::Join(",", (1..57 | ForEach-Object { '0' })))")
    # --open-path opens immediately; do not append --open or hidapitester would
    # reopen an unfiltered device (shown as vid/pid 0x0000/0x0000 in reports).
    $openArgs = @("--open-path", $Collection.Path, "-l", "65", "--send-feature", $sendPayload, "--read-feature", "0", "-q")
    Write-Line "Feature query: --open-path $($Collection.Path)"
    $response = @(& $hidapiPath @openArgs 2>&1)
    Write-RawOutput -Output $response -EmptyText "(empty)"
    $result = Get-FeatureProbeResult -Response $response
    if ($result.State -eq "Active") {
        Write-Line "Interpretation: status 0x$('{0:X2}' -f $result.Status) = ACTIVE / 정상; battery $($result.Battery)%; charging $($result.Charging)."
    } elseif ($result.State -eq "Sleeping") {
        Write-Line "Interpretation: status 0xA0 = SLEEPING / 절전 중 - 배터리 값 없음 (not 0%)."
    } elseif ($result.State -eq "UnknownStatus") {
        Write-Line "Interpretation: status 0x$('{0:X2}' -f $result.Status) with cmd echo 0x83 = unrecognized / 미확인."
    } elseif ($result.State -eq "Unexpected") {
        Write-Line "Interpretation: feature response did not echo cmd 0x83 (got 0x$('{0:X2}' -f $result.CmdAck))."
    } else {
        Write-Line "Interpretation: no parseable feature response."
    }

    if ($result.State -eq "Active" -or $result.State -eq "Sleeping") { return $result }

    # Keep the diagnostic behaviour aligned with the tray script. Some firmware
    # drops the reply when the first single-handle transaction races the receiver,
    # so retry SetFeature then GetFeature on this same exact --open-path.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Line "Retry $attempt/3: send then read on the same --open-path"
        $sendArgs = @("--open-path", $Collection.Path, "-l", "65", "--send-feature", $sendPayload, "--close")
        $null = @(& $hidapiPath @sendArgs 2>&1)
        Start-Sleep -Milliseconds 120
        $readArgs = @("--open-path", $Collection.Path, "-l", "65", "--read-feature", "0", "-q")
        $retryResponse = @(& $hidapiPath @readArgs 2>&1)
        Write-RawOutput -Output $retryResponse -EmptyText "(empty)"
        $result = Get-FeatureProbeResult -Response $retryResponse
        if ($result.State -eq "Active") {
            Write-Line "Interpretation: status 0x$('{0:X2}' -f $result.Status) = ACTIVE / 정상; battery $($result.Battery)%; charging $($result.Charging)."
            return $result
        }
        if ($result.State -eq "Sleeping") {
            Write-Line "Interpretation: status 0xA0 = SLEEPING / 절전 중 - 배터리 값 없음 (not 0%)."
            return $result
        }
    }
    return $result
}

function Test-InterruptCollection {
    param($Collection)
    $outputPayload = "4,0,0,26" + (",$([string]::Join(",", (1..60 | ForEach-Object { '0' })))")
    $openArgs = @("--open-path", $Collection.Path, "-l", "64", "--send-output", $outputPayload, "--read-input", "-t", "500", "-q")
    Write-Line "Interrupt query: --open-path $($Collection.Path)"
    $response = @(& $hidapiPath @openArgs 2>&1)
    Write-RawOutput -Output $response -EmptyText "(empty — normal for Feature-report-only collections)"
    $bytes = Parse-HexBytes -Output $response
    if ($null -ne $bytes -and $bytes.Length -ge 10) {
        $battery = [Convert]::ToInt32($bytes[8], 16)
        if ($battery -gt 0 -and $battery -le 100) {
            Write-Line "Interpretation: active interrupt response / 정상; battery $battery%."
            return @{ State = "Active"; Battery = $battery; Charging = 0; Bytes = $bytes }
        }
        Write-Line "Interpretation: interrupt response has battery byte 0x$($bytes[8]) (not accepted as a battery value)."
        return @{ State = "Unexpected"; Bytes = $bytes }
    }
    Write-Line "Interpretation: no parseable interrupt response."
    return @{ State = "NoInterruptResponse" }
}

Write-Host "Generating diagnostic report -> $ReportPath"
Write-Host "(이 과정은 연결된 모든 리시버별로 수행됩니다 / This probes every connected receiver)"

# Discover once. Never derive a query target from VID alone: 36A7:0000 was the
# source of several misleading reports when a PID was missing from the command.
$listing = @()
$collections = @()
$receivers = @()
if (Test-Path $hidapiPath) {
    $listing = @(& $hidapiPath --vidpid $VendorId --list-detail 2>&1)
    $collections = @(Get-HidCollections -Listing $listing)
    $detectedPids = @($collections | ForEach-Object { $_.Pid } | Select-Object -Unique)
    foreach ($devPid in $detectedPids) {
        # $PID is a read-only automatic variable in Windows PowerShell, so do not
        # use that spelling for a loop variable.
        $vendorCollections = @(Get-VendorCollections -Collections $collections -DevicePid $devPid)
        if ($KnownPids.ContainsKey($devPid)) { $name = $KnownPids[$devPid].Name; $protocol = $KnownPids[$devPid].Protocol; $registered = "등록됨 / known" }
        else { $name = "WLMouse (PID $devPid)"; $protocol = "Auto"; $registered = "미등록 / unknown" }
        $receivers += @{ Pid = $devPid; Name = $name; Protocol = $protocol; Registered = $registered; VendorCollections = $vendorCollections; Final = $null; ResponsePath = $null }
    }
}

Write-Section "WLMouse Battery Tray Monitor - Diagnostic Report"
Write-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Write-Line "Report version: 2"
$SummaryIndex = $report.Count
1..5 | ForEach-Object { Write-Line "__SUMMARY_PENDING__" }

Write-Section "1. System Information"
$os = Get-CimInstance Win32_OperatingSystem
Write-Line "OS: $($os.Caption) $($os.Version) (Build $($os.BuildNumber))"
Write-Line "Architecture: $env:PROCESSOR_ARCHITECTURE"
Write-Line "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Line ".NET version: $($PSVersionTable.CLRVersion)"

Write-Section "2. Tool Check"
if (Test-Path $hidapiPath) {
    $info = Get-Item $hidapiPath
    Write-Line "hidapitester.exe: FOUND ($(($info.Length)) bytes at $($info.FullName))"
    Write-Line "hidapitester version:"
    @(& $hidapiPath --version 2>&1) | ForEach-Object { Write-Line "    $_" }
} else { Write-Line "hidapitester.exe: NOT FOUND at $hidapiPath"; Write-Line "    (Re-download the repo or restore the binary.)" }

Write-Section "3. Connected WLMouse Devices (VID 0x$VendorId)"
if (-not (Test-Path $hidapiPath)) { Write-Line "(skipped — hidapitester.exe missing)" }
else {
    Write-Line "Raw --list-detail output:"; Write-RawOutput -Output $listing -EmptyText "(no devices with VID 0x$VendorId found)"
    if ($receivers.Count -eq 0) { Write-Line "Detected PIDs: (none)" }
    else {
        Write-Line "Detected PIDs: $((@($receivers | ForEach-Object { $_.Pid }) -join ', '))"
        foreach ($receiver in $receivers) {
            Write-Line "  $($receiver.Pid) -> $($receiver.Name) [$($receiver.Registered); protocol: $($receiver.Protocol)]"
            if ($receiver.VendorCollections.Count -eq 0) { Write-Line "    Vendor collections: none found (usagePage >= 0xFF00)" }
            else { foreach ($collection in $receiver.VendorCollections) { Write-Line ("    Vendor collection: interface {0}; usagePage 0x{1:X4}; usage 0x{2:X}; path {3}" -f $collection.Interface, $collection.UsagePage, $collection.Usage, $collection.Path) } }
        }
    }
}

Write-Section "4. Feature Report Protocol Test"
if (-not (Test-Path $hidapiPath) -or $receivers.Count -eq 0) { Write-Line "(skipped — no device present)" }
else {
    foreach ($receiver in $receivers) {
        Write-Line ""; Write-Line ">>> Receiver 36A7:$($receiver.Pid) - $($receiver.Name)"
        if ($receiver.VendorCollections.Count -eq 0) { Write-Line "No vendor-defined collection to open with --open-path."; continue }
        foreach ($collection in $receiver.VendorCollections) {
            Write-Line ("Collection: interface {0}; usagePage 0x{1:X4}; usage 0x{2:X}" -f $collection.Interface, $collection.UsagePage, $collection.Usage)
            $featureResult = Test-FeatureCollection -Collection $collection
            if ($null -eq $receiver.Final -and ($featureResult.State -eq "Active" -or $featureResult.State -eq "Sleeping")) {
                $receiver.Final = $featureResult
                $receiver.ResponsePath = $collection.Path
            }
        }
    }
}

Write-Section "4b. Feature Report - Report Descriptors (every vendor collection)"
if (-not (Test-Path $hidapiPath) -or $receivers.Count -eq 0) { Write-Line "(skipped — no device present)" }
else {
    foreach ($receiver in $receivers) {
        Write-Line ""; Write-Line ">>> Receiver 36A7:$($receiver.Pid) - $($receiver.Name)"
        foreach ($collection in $receiver.VendorCollections) {
            Write-Line ("Descriptor: interface {0}; usagePage 0x{1:X4}; usage 0x{2:X}; --open-path {3}" -f $collection.Interface, $collection.UsagePage, $collection.Usage, $collection.Path)
            $descriptorArgs = @("--open-path", $collection.Path, "--get-report-descriptor", "-q")
            $descriptor = @(& $hidapiPath @descriptorArgs 2>&1)
            Write-RawOutput -Output $descriptor -EmptyText "(empty)"
        }
    }
}

Write-Section "5. Interrupt Endpoint Protocol Test"
if (-not (Test-Path $hidapiPath) -or $receivers.Count -eq 0) { Write-Line "(skipped — no device present)" }
else {
    foreach ($receiver in $receivers) {
        Write-Line ""; Write-Line ">>> Receiver 36A7:$($receiver.Pid) - $($receiver.Name)"
        if ($receiver.VendorCollections.Count -eq 0) { Write-Line "No vendor-defined collection to open with --open-path."; continue }
        foreach ($collection in $receiver.VendorCollections) {
            Write-Line ("Collection: interface {0}; usagePage 0x{1:X4}; usage 0x{2:X}" -f $collection.Interface, $collection.UsagePage, $collection.Usage)
            $interruptResult = Test-InterruptCollection -Collection $collection
            if ($null -eq $receiver.Final -and $interruptResult.State -eq "Active") { $receiver.Final = $interruptResult; $receiver.ResponsePath = $collection.Path }
        }
    }
}

Write-Section "6. Recent Monitor Log (last 30 lines)"
$LogPath = Join-Path $DataDir "wlmouse_battery.log"
if (Test-Path $LogPath) { Write-Line "(from $LogPath)"; Write-RawOutput -Output @(Get-Content $LogPath -Tail 30 -Encoding UTF8) -EmptyText "(empty)" }
else { Write-Line "No log file found at $LogPath" }

Write-Section "7. Settings"
$SettingsPath = Join-Path $DataDir "settings.json"
if (Test-Path $SettingsPath) { Write-Line "(from $SettingsPath)"; Write-RawOutput -Output @(Get-Content $SettingsPath -Encoding UTF8) -EmptyText "(empty)" }
else { Write-Line "No settings.json (using defaults: LowThreshold=20%, PollInterval=300s)" }

# Replace the reserved top-of-report space only after all per-path probes finish.
$summary = New-Object System.Collections.ArrayList
$null = $summary.Add("")
$null = $summary.Add("=" * 60)
$null = $summary.Add("0. Receiver Summary / 리시버 요약")
$null = $summary.Add("=" * 60)
if ($receivers.Count -eq 0) { $null = $summary.Add("No WLMouse receiver detected / 감지된 WLMouse 리시버 없음") }
else {
    foreach ($receiver in $receivers) {
        if ($null -eq $receiver.Final) { $verdict = "무응답 / no response" }
        elseif ($receiver.Final.State -eq "Sleeping") { $verdict = "절전 중 - 배터리 값 없음 / sleeping - no battery value" }
        else { $verdict = "정상 $($receiver.Final.Battery)% / active" }
        $pathText = if ($receiver.ResponsePath) { $receiver.ResponsePath } else { "(none)" }
        $null = $summary.Add("PID $($receiver.Pid) | $($receiver.Name) | $($receiver.Registered) | responded path: $pathText | final: $verdict")
    }
}
$report.RemoveRange($SummaryIndex, 5)
$report.InsertRange($SummaryIndex, $summary)

Write-Section "End of Report"
Write-Line "Please attach this file (diagnostic_report.txt) when opening a GitHub issue."
Write-Line "Issue URL: https://github.com/minerva32/wlmouse-battery-tray/issues"

$report -join "`r`n" | Set-Content $ReportPath -Encoding UTF8
Write-Host ""; Write-Host "============================================================"
Write-Host " Report saved to: $ReportPath"; Write-Host " Size: $((Get-Item $ReportPath).Length) bytes"
Write-Host "============================================================"; Write-Host ""
Write-Host "이 파일을 GitHub 이슈에 첨부해 주세요."
Write-Host "Please attach this file to your GitHub issue: https://github.com/minerva32/wlmouse-battery-tray/issues"

if ($OpenReport) { Start-Process notepad.exe -ArgumentList "`"$ReportPath`"" }
if (-not $NoPrompt) {
    Write-Host "보고서 내용을 미리 보시겠습니까? Preview the report now? (Y/N)"
    $preview = Read-Host
    if ($preview -eq 'Y' -or $preview -eq 'y') { Get-Content $ReportPath -Encoding UTF8 }
}
