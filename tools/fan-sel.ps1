# Read-only: prints the last entries of the BMC System Event Log (SEL), to see which sensor
# crossed which threshold when the fans spiked. Must run elevated. Writes logs\fan-sel.txt.
param([int]$Last = 40)
$ErrorActionPreference = 'Stop'
$out = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan-sel.txt'
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI

function Invoke-Ipmi([byte]$netFn, [byte]$cmd, [byte[]]$data) {
    if (-not $data) { $data = [byte[]]@() }
    $r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
        NetworkFunction = $netFn; Command = $cmd; Lun = [byte]0; ResponderAddress = [byte]0x20
        RequestData = $data; RequestDataSize = [uint32]$data.Length
    }
    return ,([byte[]]$r.ResponseData)
}
function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

$NAMES = @{ 1 = 'CPU Temp'; 11 = 'System Temp'; 12 = 'Peripheral Temp'; 65 = 'FAN1'; 66 = 'FAN2'; 67 = 'FAN3'
            68 = 'FAN4'; 69 = 'FAN5'; 71 = 'FANA'; 72 = 'FANB'; 170 = 'Chassis Intru' }
$THRESHOLD_EVENT = @{ 0 = 'LNC going low'; 1 = 'LNC going high'; 2 = 'LCR going low'; 3 = 'LCR going high'
                      4 = 'LNR going low'; 5 = 'LNR going high'; 6 = 'UNC going low'; 7 = 'UNC going high'
                      8 = 'UCR going low'; 9 = 'UCR going high'; 10 = 'UNR going low'; 11 = 'UNR going high' }

$info = Invoke-Ipmi 0x0A 0x40
$count = $info[2] + ([int]$info[3] -shl 8)
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("SEL entries: $count   (Windows clock now: $(Get-Date -Format s); the BMC clock may be offset)")

$entries = [System.Collections.Generic.List[string]]::new()
$recId = 0
$guard = 0
while ($recId -ne 0xFFFF -and $guard -lt 5000) {
    $guard++
    $r = Invoke-Ipmi 0x0A 0x43 ([byte[]]@(0, 0, ($recId -band 0xFF), ($recId -shr 8), 0, 0xFF))
    if ($r[0] -ne 0) { $lines.Add(("Get SEL Entry 0x{0:X4} failed: cc=0x{1:X2}" -f $recId, $r[0])); break }
    $next = $r[1] + ([int]$r[2] -shl 8)
    $e = [byte[]]$r[3..18]
    $ts = [BitConverter]::ToUInt32($e, 3)
    $when = if ($ts -gt 0x20000000) { [DateTimeOffset]::FromUnixTimeSeconds($ts).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { "t+$ts" }
    $sensor = $e[11]
    $name = if ($NAMES.ContainsKey([int]$sensor)) { $NAMES[[int]$sensor] } else { "sensor $sensor" }
    $dir = if ($e[12] -band 0x80) { 'deassert' } else { 'assert' }
    $evType = $e[12] -band 0x7F
    $offset = $e[13] -band 0x0F
    $what = if ($evType -eq 0x01 -and $THRESHOLD_EVENT.ContainsKey([int]$offset)) { $THRESHOLD_EVENT[[int]$offset] } else { "type 0x{0:X2} offset {1}" -f $evType, $offset }
    $entries.Add(("{0}  #{1,-5} {2,-16} {3,-9} {4,-16} data[{5}] reading={6}" -f $when, ('{0:X4}' -f $recId), $name, $dir, $what, (Hex $e[13..15]), $e[14]))
    $recId = $next
}
$start = [Math]::Max(0, $entries.Count - $Last)
for ($i = $start; $i -lt $entries.Count; $i++) { $lines.Add($entries[$i]) }

$lines | Set-Content -Encoding UTF8 $out
$lines | Write-Output
Write-Host "`nSaved to $out"
