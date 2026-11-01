# Re-creates the FAN1 sensor record (deleted from the BMC's SDR on 2026-02-12) by cloning FAN2's.
# Without -Apply it only prints what it would write. Must run elevated. Logs to fan1-restore.txt.
# Undo: Delete SDR (netfn 0x0A cmd 0x26) on the record ID this script prints.
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$out = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan1-restore.txt'
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
function Log([string]$s) { $lines.Add($s); Write-Host $s }
function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }
function Name-Of([byte[]]$b) { [Text.Encoding]::ASCII.GetString($b, 48, ($b[47] -band 0x1F)) }

$FAN1_NUMBER = 65          # FAN2..FAN5 are 66..69
$LOWER_RAW = 1             # 100 RPM, the same lower thresholds FANA/FANB already carry

try {
    Log "== $(Get-Date -Format s)  Apply=$Apply"
    $res = Invoke-Ipmi 0x0A 0x22
    $resId = $res[1] + ([int]$res[2] -shl 8)

    $records = @{}
    $recId = 0
    while ($recId -ne 0xFFFF) {
        $r = Read-SdrRecord $recId $resId
        if ($r.Data[3] -eq 0x01 -and $r.Data.Length -gt 48) { $records[(Name-Of $r.Data)] = $r.Data }
        $recId = $r.Next
    }
    if ($records.ContainsKey('FAN1')) { Log "FAN1 already has a record. Nothing to do."; return }
    if (-not ($records.ContainsKey('FAN2') -and $records.ContainsKey('FAN3'))) { throw 'FAN2/FAN3 records not found' }

    $fan2 = $records['FAN2']; $fan3 = $records['FAN3']
    if ($fan2[7] -ne ($FAN1_NUMBER + 1)) { throw "FAN2 is sensor $($fan2[7]), expected $($FAN1_NUMBER + 1)" }

    $new = [byte[]]$fan2.Clone()
    $new[0] = 0; $new[1] = 0                         # record ID: the BMC assigns one
    $new[7] = $FAN1_NUMBER                           # sensor number
    $new[9] = $fan2[9] - ($fan3[9] - $fan2[9])       # entity instance, following FAN2 -> FAN3
    $new[39] = $LOWER_RAW; $new[40] = $LOWER_RAW; $new[41] = $LOWER_RAW   # LNR, LCR, LNC
    $nameAt = 48 + (Name-Of $fan2).IndexOf('2')
    $new[$nameAt] = [byte][char]'1'

    Log "FAN2 record : $(Hex $fan2)"
    Log "FAN1 record : $(Hex $new)"
    Log ("FAN1 = sensor {0}, entity instance {1}, name '{2}', lower thresholds {3} RPM" -f $new[7], $new[9], (Name-Of $new), ($LOWER_RAW * 100))
    if (-not $Apply) { Log "Dry run. Re-run with -Apply to write it."; return }

    # Partial Add SDR, 16 bytes at a time: resId, recId (0 first), offset, progress (1 = last), data.
    $newId = 0
    for ($off = 0; $off -lt $new.Length; $off += 16) {
        $end = [Math]::Min($off + 16, $new.Length) - 1
        $last = [byte]$(if ($end -eq $new.Length - 1) { 1 } else { 0 })
        $hdr = [byte[]]@(($resId -band 0xFF), ($resId -shr 8), ($newId -band 0xFF), ($newId -shr 8), $off, $last)
        $r = Invoke-Ipmi 0x0A 0x25 ([byte[]]($hdr + $new[$off..$end]))
        if ($r[0] -ne 0) { throw ("Partial Add SDR failed at offset {0}: cc=0x{1:X2}" -f $off, $r[0]) }
        $newId = $r[1] + ([int]$r[2] -shl 8)
    }
    Log ("Added. New record ID 0x{0:X4}" -f $newId)

    $th = [byte[]]@($FAN1_NUMBER, 0x07, $LOWER_RAW, $LOWER_RAW, $LOWER_RAW, 0, 0, 0)  # mask: lower three only
    $r = Invoke-Ipmi 0x04 0x26 $th
    Log ("Set thresholds: cc=0x{0:X2}" -f $r[0])
    Start-Sleep -Seconds 5
    $rd = Invoke-Ipmi 0x04 0x2D ([byte[]]@($FAN1_NUMBER))
    Log "FAN1 reading now: [$(Hex $rd)]  (CB = BMC is not scanning it yet; it needs a BMC restart)"
}
finally {
    $lines | Set-Content -Encoding UTF8 $out
    Write-Host "`nSaved to $out"
}
