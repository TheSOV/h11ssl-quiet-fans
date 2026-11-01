# Cold-resets the BMC so it starts scanning the re-created FAN1 sensor, then reads FAN1 back.
# The host keeps running; fans go to full speed for 1-2 minutes while the BMC boots.
# Must run elevated. Logs to fan-bmc-reset.txt.
$ErrorActionPreference = 'Stop'
$out = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan-bmc-reset.txt'
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI

function Invoke-Ipmi([byte]$netFn, [byte]$cmd, [byte[]]$data) {
    if (-not $data) { $data = [byte[]]@() }
    $r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
        NetworkFunction = $netFn; Command = $cmd; Lun = [byte]0; ResponderAddress = [byte]0x20
        RequestData = $data; RequestDataSize = [uint32]$data.Length
    }
    return ,([byte[]]$r.ResponseData)
}

$lines = [System.Collections.Generic.List[string]]::new()
function Log([string]$s) { $lines.Add($s); Write-Host $s }
function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

$FAN1 = 65
$LOWER_RAW = 1        # 100 RPM
$TIMEOUT_SECONDS = 300

try {
    Log "== $(Get-Date -Format s)  BMC cold reset"
    try { [void](Invoke-Ipmi 0x06 0x02) } catch { }   # the BMC may drop the reply while resetting
    Start-Sleep -Seconds 20

    $deadline = (Get-Date).AddSeconds($TIMEOUT_SECONDS)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        try { $id = Invoke-Ipmi 0x06 0x01; if ($id -and $id[0] -eq 0) { $up = $true; break } } catch { }
        Start-Sleep -Seconds 5
    }
    if (-not $up) { Log "BMC did not answer within $TIMEOUT_SECONDS s. Check the BMC web UI."; return }
    Log "BMC back after $([int]((Get-Date) - $deadline.AddSeconds(-$TIMEOUT_SECONDS)).TotalSeconds) s"
    Start-Sleep -Seconds 30                        # let it finish its first sensor scan

    $th = Invoke-Ipmi 0x04 0x26 ([byte[]]@($FAN1, 0x07, $LOWER_RAW, $LOWER_RAW, $LOWER_RAW, 0, 0, 0))
    Log ("Set FAN1 lower thresholds: cc=0x{0:X2}" -f $th[0])
    foreach ($num in $FAN1, 71, 72) {
        $rd = Invoke-Ipmi 0x04 0x2D ([byte[]]@($num))
        $t = Invoke-Ipmi 0x04 0x27 ([byte[]]@($num))
        $rpm = if ($rd[0] -eq 0 -and -not ($rd[2] -band 0x20)) { "$([int]$rd[1] * 100) RPM" } else { 'n/a' }
        Log ("sensor {0}: {1,-9} reading [{2}] thresholds [{3}]" -f $num, $rpm, (Hex $rd), (Hex $t))
    }
    $mode = Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x00))
    Log "Fan mode after reset: $($mode[1]) (2 = Optimal)"
}
finally {
    $lines | Set-Content -Encoding UTF8 $out
    Write-Host "`nSaved to $out"
}
