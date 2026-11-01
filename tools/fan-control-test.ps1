# Control test: does the BMC accept the fan mode and duty commands at all?
# Logs every completion code, reads mode and duty back, and watches RPM respond.
# If the X10/X11-style duty command has no effect, tries the older X9-style one.
# Restores Optimal mode at the end. Must run elevated. Writes fan-control-test.txt.
$ErrorActionPreference = 'Stop'
$out = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan-control-test.txt'
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
function Log([string]$s) { $line = "$(Get-Date -Format HH:mm:ss) $s"; $lines.Add($line); Write-Host $line }
function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }
function Rpm([int]$num) { $r = Invoke-Ipmi 0x04 0x2D ([byte[]]@($num)); if ($r[0] -ne 0) { 'n/a' } else { [int]$r[1] * 100 } }
function State([string]$label) {
    $m = Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x00))
    $d0 = Invoke-Ipmi 0x30 0x70 ([byte[]]@(0x66, 0x00, 0x00))
    $d1 = Invoke-Ipmi 0x30 0x70 ([byte[]]@(0x66, 0x00, 0x01))
    Log ("{0,-28} mode[{1}] zone0[{2}] zone1[{3}]  FANA={4} FANB={5} FAN1={6}" -f $label, (Hex $m), (Hex $d0), (Hex $d1), (Rpm 71), (Rpm 72), (Rpm 65))
}
function Send([string]$label, [byte]$netFn, [byte]$cmd, [byte[]]$data) {
    $r = Invoke-Ipmi $netFn $cmd $data
    Log ("SEND {0,-23} -> [{1}]" -f $label, (Hex $r))
}

try {
    State 'initial'
    Send 'mode Full' 0x30 0x45 ([byte[]]@(0x01, 0x01))
    Start-Sleep -Seconds 15
    State 'after Full, 15 s'

    foreach ($pct in 50, 20, 10) {
        Send "zone1 $pct % (X10/X11)" 0x30 0x70 ([byte[]]@(0x66, 0x01, 0x01, $pct))
        Start-Sleep -Seconds 15
        State "zone1 $pct %, 15 s"
    }

    # Zone 0 too, to see which fans each zone actually drives.
    Send 'zone0 50 % (X10/X11)' 0x30 0x70 ([byte[]]@(0x66, 0x01, 0x00, 50))
    Start-Sleep -Seconds 15
    State 'zone0 50 %, 15 s'
    Send 'zone0 20 % (X10/X11)' 0x30 0x70 ([byte[]]@(0x66, 0x01, 0x00, 20))
    Start-Sleep -Seconds 15
    State 'zone0 20 %, 15 s'

    # Older X9-style command: zone 0x10 = CPU, 0x11 = peripheral, duty 0..255.
    Send 'zone1 50 % (X9)' 0x30 0x91 ([byte[]]@(0x5A, 0x03, 0x11, 0x80))
    Start-Sleep -Seconds 15
    State 'X9 zone1 50 %, 15 s'
    Send 'zone1 10 % (X9)' 0x30 0x91 ([byte[]]@(0x5A, 0x03, 0x11, 0x1A))
    Start-Sleep -Seconds 15
    State 'X9 zone1 10 %, 15 s'
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally {
    Send 'mode Optimal' 0x30 0x45 ([byte[]]@(0x01, 0x02))
    Start-Sleep -Seconds 10
    State 'restored'
    $lines | Set-Content -Encoding UTF8 $out
    Write-Host "`nSaved to $out"
}
