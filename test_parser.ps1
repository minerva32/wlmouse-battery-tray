$hidapiPath = "D:\wlbattery\hidapitester\hidapitester.exe"
$activeId = 2 # Always query virtual ID 2 for the active mouse!
$vidPid = "36A7"
$usagePage = "0xFFFF"
$usage = "0"
$length = 65

# 65-byte feature report: report-id(0), 0,0, <slotId=2>, 2, 0, <batteryCmd=0x83>, ...
$sendPayload = "0,0,0,$activeId,2,0,131" + (",$([string]::Join(",", (1..57 | ForEach-Object { '0' })))")

Write-Host "Querying battery status for Device ID $activeId..."

function Get-MouseResponse {
    # 1) send feature report (do NOT read yet)
    & $hidapiPath --vidpid $vidPid --usagePage $usagePage --usage $usage -l $length --open --send-feature $sendPayload --close *> $null

    # 2) sleep so the device can prepare the result (required, per wlmouse-cli protocol)
    Start-Sleep -Milliseconds 120

    # 3) read feature report separately
    return & $hidapiPath --vidpid $vidPid --usagePage $usagePage --usage $usage -l $length --open --read-feature 0 -q
}

$bytes = $null
$maxTries = 8
for ($attempt = 1; $attempt -le $maxTries; $attempt++) {
    $output = Get-MouseResponse

    if ($null -eq $output -or $output.Length -eq 0) {
        Write-Host "No output (attempt $attempt)"
        continue
    }

    # Locate the read response section
    $readStartIndex = -1
    for ($i = 0; $i -lt $output.Length; $i++) {
        if ($output[$i] -like "*Reading*") { $readStartIndex = $i; break }
    }
    if ($readStartIndex -eq -1) { continue }

    $readSection = $output[($readStartIndex + 1)..($output.Length - 1)]
    $hexLines = $readSection | Where-Object { $_ -match "^[0-9a-fA-F\s]+$" }
    $bytes = $hexLines -join " " -split "\s+" | Where-Object { $_ -ne "" }
    if ($bytes.Length -lt 10) { continue }

    # Accept only "active" responses: status 0xA1 AND command echo 0x83 at offset 6
    $status = [Convert]::ToInt32($bytes[1], 16)
    $cmdAck = [Convert]::ToInt32($bytes[6], 16)
    if ($status -eq 0xA1 -and $cmdAck -eq 0x83) { break }
    Write-Host "Not ready yet (status=$($bytes[1])), retrying... (attempt $attempt)"
    Start-Sleep -Milliseconds 80
}

if ($null -eq $bytes -or $bytes.Length -lt 10) {
    Write-Host "Failed to get a valid response after $maxTries attempts"
    exit
}

$status   = [Convert]::ToInt32($bytes[1], 16)
$battery  = [Convert]::ToInt32($bytes[8], 16)
$charging = [Convert]::ToInt32($bytes[9], 16)

Write-Host "Status:   0x$($bytes[1]) ($status)"
Write-Host "Battery:  $battery% (0x$($bytes[8]))"
Write-Host "Charging: $charging (0x$($bytes[9]))"
