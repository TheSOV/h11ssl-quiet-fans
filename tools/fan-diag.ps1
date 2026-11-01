# Read-only IPMI diagnostic for a Supermicro H11SSL-i, through the Windows in-box IPMI driver.
# Changes nothing. Must run elevated. Writes fan-diag.txt next to itself.
$ErrorActionPreference = 'Stop'
$out = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan-diag.txt'
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
$lines.Add("== $(Get-Date -Format s)")

$mode = Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x00))
$modeNames = @{ 0 = 'Standard'; 1 = 'Full'; 2 = 'Optimal'; 3 = 'PUE'; 4 = 'HeavyIO' }
[void]$lines.Add(("Fan mode: cc=0x{0:X2} raw={1} ({2})" -f $mode[0], $mode[1], $modeNames[[int]$mode[1]]))
foreach ($zone in 0, 1) {
    $d = Invoke-Ipmi 0x30 0x70 ([byte[]]@(0x66, 0x00, $zone))
    [void]$lines.Add(("Zone $zone duty: cc=0x{0:X2} value={1}%" -f $d[0], $(if ($d.Length -gt 1) { $d[1] } else { '?' })))
}
$ip = Invoke-Ipmi 0x0C 0x02 ([byte[]]@(0x01, 0x03, 0x00, 0x00))
if ($ip[0] -eq 0) { [void]$lines.Add(("BMC LAN IP: {0}.{1}.{2}.{3}" -f $ip[2], $ip[3], $ip[4], $ip[5])) }

$lines.Add("")
[void]$lines.Add(("{0,-14} {1,4} {2,-5} {3,10}  {4,8} {5,8} {6,8} | {7,8} {8,8} {9,8}" -f 'Name', '#', 'Unit', 'Reading', 'LNR', 'LCR', 'LNC', 'UNC', 'UCR', 'UNR'))

$res = Invoke-Ipmi 0x0A 0x22
$resId = $res[1] + ([int]$res[2] -shl 8)
$recId = 0
while ($recId -ne 0xFFFF) {
    $r = Read-SdrRecord $recId $resId
    $recId = $r.Next
    $b = $r.Data
    if ($b[3] -ne 0x01) { continue }              # full sensor records only
    $unit = switch ($b[21]) { 0x01 { 'degC' } 0x12 { 'RPM' } 0x04 { 'V' } default { $null } }
    if (-not $unit) { continue }
    $num = $b[7]
    $m = To-Signed ($b[24] + (([int]$b[25] -shr 6) -shl 8)) 10
    $bb = To-Signed ($b[26] + (([int]$b[27] -shr 6) -shl 8)) 10
    $rExp = To-Signed ($b[29] -shr 4) 4
    $bExp = To-Signed ($b[29] -band 0x0F) 4
    $conv = { param($x) if ($null -eq $x) { return '-' } [Math]::Round(($m * $x + $bb * [Math]::Pow(10, $bExp)) * [Math]::Pow(10, $rExp), 1) }
    $nameLen = $b[47] -band 0x1F
    $name = [Text.Encoding]::ASCII.GetString($b, 48, $nameLen)
    $rd = Invoke-Ipmi 0x04 0x2D ([byte[]]@($num))
    $reading = if ($rd[0] -ne 0 -or ($rd[2] -band 0x20)) { 'n/a' } else { & $conv $rd[1] }
    $th = Invoke-Ipmi 0x04 0x27 ([byte[]]@($num))  # Get Sensor Thresholds: cc, mask, LNC, LCR, LNR, UNC, UCR, UNR
    $t = if ($th[0] -eq 0) { $th[2..7] | ForEach-Object { & $conv $_ } } else { @('-') * 6 }
    [void]$lines.Add(("{0,-14} {1,4} {2,-5} {3,10}  {4,8} {5,8} {6,8} | {7,8} {8,8} {9,8}" -f $name, $num, $unit, $reading, $t[2], $t[1], $t[0], $t[3], $t[4], $t[5]))
}

$lines | Set-Content -Encoding UTF8 $out
$lines | Write-Output
Write-Host "`nSaved to $out"
