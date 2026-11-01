# Deletes the FAN1 sensor record from the BMC's SDR again (the state before 2026-11-01), so the BMC
# stops reading the CPU Noctua, whose tach drops to 0 RPM at low duty and trips the fail-safe.
# Without -Apply it only shows what it would delete. With -Apply it also cold-resets the BMC so it
# stops scanning FAN1 (fans go to full for 1-2 min; the host keeps running).
# Must run elevated. Logs to logs\fan1-remove.txt. To undo, run fan1-restore.ps1 -Apply.
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$out = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan1-remove.txt'
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI

function Invoke-Ipmi([byte]$netFn, [byte]$cmd, [byte[]]$data) {
    if (-not $data) { $data = [byte[]]@() }
    $r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
        NetworkFunction = $netFn; Command = $cmd; Lun = [byte]0; ResponderAddress = [byte]0x20
        RequestData = $data; RequestDataSize = [uint32]$data.Length
    }
    return ,([byte[]]$r.ResponseData)
}

function To-Signed([int]$v, [int]$bits) { if ($v -band (1 -shl ($bits - 1))) { $v - (1 -shl $bits) } else { $v } }

function Read-SdrRecord([int]$recId, [int]$resId) {
    # Comma binds tighter than -band/-shr in PowerShell, so every element is parenthesised.
    $key = [byte[]]@(($resId -band 0xFF), ($resId -shr 8), ($recId -band 0xFF), ($recId -shr 8))
    $hdr = Invoke-Ipmi 0x0A 0x23 ([byte[]]($key + @(0, 5)))
    if ($hdr[0] -ne 0) { throw "Get SDR header failed cc=0x{0:X2}" -f $hdr[0] }
    $next = $hdr[1] + ([int]$hdr[2] -shl 8)
    $len = $hdr[7]
    $rec = [System.Collections.Generic.List[byte]]::new()
    $rec.AddRange([byte[]]$hdr[3..7])
    $off = 5
    while ($off -lt $len + 5) {
        $n = [Math]::Min(16, $len + 5 - $off)
        $r = Invoke-Ipmi 0x0A 0x23 ([byte[]]($key + @($off, $n)))
        if ($r[0] -ne 0) { throw "Get SDR body failed cc=0x{0:X2}" -f $r[0] }
        $rec.AddRange([byte[]]$r[3..($r.Length - 1)])
        $off += $n
    }
    return @{ Next = $next; Data = $rec.ToArray() }
}

$lines = [System.Collections.Generic.List[string]]::new()
function Log([string]$s) { $line = "$(Get-Date -Format HH:mm:ss) $s"; $lines.Add($line); Write-Host $line }
function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

function Find-Fan1 {
    $res = Invoke-Ipmi 0x0A 0x22
    $resId = $res[1] + ([int]$res[2] -shl 8)
    $recId = 0
    while ($recId -ne 0xFFFF) {
        $r = Read-SdrRecord $recId $resId
        $b = $r.Data
        if ($b[3] -eq 0x01 -and $b.Length -gt 48 -and $b[7] -eq 65) {
            return @{ Id = $recId; Name = [Text.Encoding]::ASCII.GetString($b, 48, ($b[47] -band 0x1F)) }
        }
        $recId = $r.Next
    }
    return $null
}

try {
    Log "== $(Get-Date -Format s)  Apply=$Apply"
    $f = Find-Fan1
    if ($null -eq $f) { Log "No record for sensor 65 (FAN1). Nothing to delete."; return }
    if ($f.Name -ne 'FAN1') { throw "Sensor 65 is named '$($f.Name)', not FAN1. Not touching it." }
    Log ("Found FAN1 at record ID 0x{0:X4}" -f $f.Id)
    if (-not $Apply) { Log "Dry run. Re-run with -Apply to delete it and reset the BMC."; return }

    $res = Invoke-Ipmi 0x0A 0x22
    $resId = $res[1] + ([int]$res[2] -shl 8)
    $del = Invoke-Ipmi 0x0A 0x26 ([byte[]]@(($resId -band 0xFF), ($resId -shr 8), ($f.Id -band 0xFF), ($f.Id -shr 8)))
    Log "Delete SDR: [$(Hex $del)]"
    if ($del[0] -ne 0) { throw ("Delete SDR failed: cc=0x{0:X2}" -f $del[0]) }
    if ($null -ne (Find-Fan1)) { throw "FAN1 is still in the SDR after deleting" }
    Log "FAN1 record gone."

    Log "BMC cold reset..."
    try { [void](Invoke-Ipmi 0x06 0x02) } catch { }
    Start-Sleep -Seconds 30
    # Ready means sensors read again, not just that the BMC answers (it answers before scanning).
    $t0 = Get-Date
    $ready = $false
    while (((Get-Date) - $t0).TotalSeconds -lt 600) {
        try { $r = Invoke-Ipmi 0x04 0x2D ([byte[]]@(71)); if ($r[0] -eq 0 -and -not ($r[2] -band 0x20)) { $ready = $true; break } } catch { }
        Start-Sleep -Seconds 10
    }
    if (-not $ready) { Log "Sensors not readable 10 min after the reset. Check the BMC web UI."; return }
    Start-Sleep -Seconds 20
    $mode = Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x00))
    $fan1 = Invoke-Ipmi 0x04 0x2D ([byte[]]@(65))
    $fana = Invoke-Ipmi 0x04 0x2D ([byte[]]@(71))
    Log "After reset: mode [$(Hex $mode)] (2 = Optimal), FAN1 [$(Hex $fan1)] (CB = not scanned), FANA [$(Hex $fana)]"
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally {
    $lines | Set-Content -Encoding UTF8 $out
    Write-Host "`nSaved to $out"
}
