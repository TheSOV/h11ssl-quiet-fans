# Read-only: watches the fans for a while in whatever mode the BMC is in and flags fail-safe spikes
# (fans jumping to high speed with no temperature reason). Must run elevated.
# Usage: fan-watch.ps1 [-Minutes 60]. Appends to logs\fan-watch.log.
param([int]$Minutes = 60)
$ErrorActionPreference = 'Stop'
$log = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan-watch.log'
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI

function Invoke-Ipmi([byte]$netFn, [byte]$cmd, [byte[]]$data) {
    if (-not $data) { $data = [byte[]]@() }
    $r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
        NetworkFunction = $netFn; Command = $cmd; Lun = [byte]0; ResponderAddress = [byte]0x20
        RequestData = $data; RequestDataSize = [uint32]$data.Length
    }
    return ,([byte[]]$r.ResponseData)
}
function Read-Rpm([int]$num) {
    $r = Invoke-Ipmi 0x04 0x2D ([byte[]]@($num))
    if ($r[0] -ne 0 -or ($r[2] -band 0x20)) { return $null }
    return [int]$r[1] * 100
}
function Read-Temp([int]$num) {
    $r = Invoke-Ipmi 0x04 0x2D ([byte[]]@($num))
    if ($r[0] -ne 0 -or ($r[2] -band 0x20)) { return $null }
    return [int]$r[1]
}
function Log([string]$s) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $s"; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Host $line }

# Sensor numbers on the H11SSL-i. Fans the BMC cannot read (absent, or removed from the SDR) are skipped.
$FANS = [ordered]@{ FAN1 = 65; FAN2 = 66; FAN3 = 67; FAN4 = 68; FAN5 = 69; FANA = 71; FANB = 72 }
$CPU_TEMP = 1
$SAMPLE_SECONDS = 10
$IDLE_CPU_C = 55
# A spike is any fan reading at least SPIKE_FACTOR times its idle baseline (and SPIKE_MIN_DELTA RPM
# more) while the CPU is idle: the fail-safe drives fans to full speed, the temperature curve does not.
$SPIKE_FACTOR = 2.0
$SPIKE_MIN_DELTA = 400

# Second, independent trace: the SEL. Every fail-safe seen on this board was triggered by a
# threshold event, and each one added SEL entries. 'Get SEL Info' carries the timestamp of the most
# recent addition, so a change means a new event, even for a fan the BMC no longer reads.
function Get-SelAddStamp { $i = Invoke-Ipmi 0x0A 0x40; return [BitConverter]::ToUInt32($i, 6) }
function Get-LastSel {
    $r = Invoke-Ipmi 0x0A 0x43 ([byte[]]@(0, 0, 0xFF, 0xFF, 0, 0xFF))   # record 0xFFFF = last entry
    if ($r[0] -ne 0) { return "cc=0x{0:X2}" -f $r[0] }
    $e = [byte[]]$r[3..18]
    $dir = if ($e[12] -band 0x80) { 'deassert' } else { 'assert' }
    return "sensor $($e[11]) $dir offset $($e[13] -band 0x0F) reading $($e[14])"
}
function Get-Duty([int]$zone) { (Invoke-Ipmi 0x30 0x70 ([byte[]]@(0x66, 0x00, $zone)))[1] }

$mode = (Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x00)))[1]
$selStamp = Get-SelAddStamp
$selEvents = 0
$duty = @{ 0 = (Get-Duty 0); 1 = (Get-Duty 1) }
$baseline = [ordered]@{}
foreach ($k in $FANS.Keys) { $v = Read-Rpm $FANS[$k]; if ($null -ne $v -and $v -gt 0) { $baseline[$k] = $v } }
if ($baseline.Count -eq 0) { throw 'No fan is readable' }
Log ("== watch $Minutes min, mode $mode (2 = Optimal), every $SAMPLE_SECONDS s, duty $($duty[0])/$($duty[1]) %, baseline: " + (($baseline.Keys | ForEach-Object { "$_=$($baseline[$_])" }) -join ' '))

$spikes = 0; $inSpike = $false; $spikeStart = $null; $samples = 0
$t0 = Get-Date
while (((Get-Date) - $t0).TotalMinutes -lt $Minutes) {
    $rpm = [ordered]@{}
    foreach ($k in $baseline.Keys) { $rpm[$k] = Read-Rpm $FANS[$k] }
    $cpu = Read-Temp $CPU_TEMP
    $samples++
    $high = @($baseline.Keys | Where-Object {
        $null -ne $rpm[$_] -and $rpm[$_] -ge [Math]::Max($baseline[$_] * $SPIKE_FACTOR, $baseline[$_] + $SPIKE_MIN_DELTA)
    })
    $spiking = ($high.Count -gt 0 -and $null -ne $cpu -and $cpu -lt $IDLE_CPU_C)
    $now = ($rpm.Keys | ForEach-Object { "$_=$($rpm[$_])" }) -join ' '
    if ($spiking -and -not $inSpike) { $spikes++; $spikeStart = Get-Date; Log "SPIKE #$spikes start ($($high -join ', ')): $now CPU=$cpu" }
    if (-not $spiking -and $inSpike) { Log ("SPIKE #{0} end after {1:N0} s" -f $spikes, ((Get-Date) - $spikeStart).TotalSeconds) }
    $inSpike = $spiking
    $stamp = Get-SelAddStamp
    if ($stamp -ne $selStamp) { $selEvents++; $selStamp = $stamp; Log "SEL new entry #${selEvents}: $(Get-LastSel)" }
    foreach ($z in 0, 1) {
        $d = Get-Duty $z
        if ($d -ne $duty[$z]) { Log "zone $z duty $($duty[$z]) -> $d % (CPU=$cpu)"; $duty[$z] = $d }
    }
    if ($samples % 30 -eq 0) { Log ("  t={0,4:N0} min {1} CPU={2} duty={3}/{4}" -f ((Get-Date) - $t0).TotalMinutes, $now, $cpu, $duty[0], $duty[1]) }
    Start-Sleep -Seconds $SAMPLE_SECONDS
}
Log "== DONE: $spikes RPM spike(s), $selEvents new SEL entr(ies) in $Minutes min ($samples samples)"
