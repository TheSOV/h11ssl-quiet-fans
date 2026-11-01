# Read-only: lists every SDR record and probes the sensor numbers around the fans, to find what is left of FAN1.
# Must run elevated. Writes fan-sdr.txt next to itself.
$ErrorActionPreference = 'Stop'
$out = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan-sdr.txt'
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

Log "== $(Get-Date -Format s)"
Log ("SDR repository info: " + (Hex (Invoke-Ipmi 0x0A 0x20)))
Log ""
Log ("{0,6} {1,5} {2,5} {3,5}  {4}" -f 'recId', 'type', 'num', 'unit', 'name')

$res = Invoke-Ipmi 0x0A 0x22
$resId = $res[1] + ([int]$res[2] -shl 8)
$recId = 0
while ($recId -ne 0xFFFF) {
    $r = Read-SdrRecord $recId $resId
    $b = $r.Data
    $type = $b[3]
    $num = '-'; $unit = '-'; $name = ''
    if ($type -eq 0x01 -and $b.Length -gt 48) { $num = $b[7]; $unit = '0x{0:X2}' -f $b[21]; $name = [Text.Encoding]::ASCII.GetString($b, 48, ($b[47] -band 0x1F)) }
    elseif ($type -eq 0x02 -and $b.Length -gt 32) { $num = $b[7]; $unit = '0x{0:X2}' -f $b[21]; $name = [Text.Encoding]::ASCII.GetString($b, 32, ($b[31] -band 0x1F)) }
    elseif ($type -eq 0x03 -and $b.Length -gt 17) { $num = $b[7]; $name = [Text.Encoding]::ASCII.GetString($b, 17, ($b[16] -band 0x1F)) }
    Log ("{0,6} {1,5} {2,5} {3,5}  {4}" -f ('0x{0:X4}' -f $recId), ('0x{0:X2}' -f $type), $num, $unit, $name)
    $recId = $r.Next
}

Log ""
Log "Direct probes (reading = cc raw flags..., thresholds = cc mask LNC LCR LNR UNC UCR UNR):"
foreach ($num in 64..72) {
    $rd = Invoke-Ipmi 0x04 0x2D ([byte[]]@($num))
    $th = Invoke-Ipmi 0x04 0x27 ([byte[]]@($num))
    $ev = Invoke-Ipmi 0x04 0x29 ([byte[]]@($num))
    Log ("sensor {0,3}: reading [{1}]  thresholds [{2}]  event-enable [{3}]" -f $num, (Hex $rd), (Hex $th), (Hex $ev))
}

$lines | Set-Content -Encoding UTF8 $out
Write-Host "`nSaved to $out"
