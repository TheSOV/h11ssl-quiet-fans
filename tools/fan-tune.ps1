# Finds the lowest safe idle duty, first for the case fans (zone 1: FANA/FANB) and then for the CPU fan
# (zone 0: FAN1), then loads every CPU thread
# with both zones held at those floors and logs temperatures. Puts the BMC back in Optimal mode at the end.
# Must run elevated. Takes up to about 60 minutes. Appends to fan-tune.log as it goes.
#
# Safety:
#   - zone 0 (CPU Noctua on FAN1) stays at 20 % while zone 1 is searched; its own floor must keep
#     FAN1 at 300 RPM or more (its critical threshold is 100) and the idle CPU under 60 C.
#   - a step fails if FANA/FANB read 300 RPM or less, FAN1 reads 200 or less, or the BMC fail-safe
#     fires (fans jump to full speed); the floor is the lowest step that passed.
#   - the stress phase stops the load and sets every fan to 100 % if CPU >= 80 C, any VRM >= 90 C
#     or any DIMM >= 75 C.
#   - whatever happens, the load is stopped and Optimal mode restored in 'finally'.
#   If the window is closed mid-run, run fan-optimal.ps1 to hand control back to the BMC.
$ErrorActionPreference = 'Stop'
$log = Join-Path (New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot '..\logs')).FullName 'fan-tune.log'
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI

function Invoke-Ipmi([byte]$netFn, [byte]$cmd, [byte[]]$data) {
    if (-not $data) { $data = [byte[]]@() }
    $r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
        NetworkFunction = $netFn; Command = $cmd; Lun = [byte]0; ResponderAddress = [byte]0x20
        RequestData = $data; RequestDataSize = [uint32]$data.Length
    }
    return ,([byte[]]$r.ResponseData)
}

# Sensor numbers from fan-diag.txt. Fans are raw*100 RPM, temperatures are raw degC.
$FAN = [ordered]@{ FANA = 71; FANB = 72; FAN1 = 65 }
$TEMP = [ordered]@{ CPU = 1; SYS = 11; VRMCpu = 16; VRMSoc = 18; VRMABCD = 20; VRMEFGH = 22; DIMMA1 = 176; DIMMC1 = 180 }

$ZONE0_PCT = 20
$IDLE_STEPS = 20, 16, 13, 11, 9, 7, 5, 4
$SOAK_SECONDS = 180
$SAMPLE_SECONDS = 10
$CASE_MIN_RPM = 400          # above this with a 100 RPM reading step, 300 is the hard stop
$CASE_STOP_RPM = 300
$FAN1_MIN_RPM = 300          # accepted floor keeps FAN1 two 100 RPM steps above its 100 RPM alarm
$FAN1_STOP_RPM = 200
$ZONE0_STEPS = 16, 13, 11, 9, 7, 5
$IDLE_CPU_LIMIT = 60
$STRESS_SECONDS = 600
$COOLDOWN_SECONDS = 120
$LIMIT = @{ CPU = 80; VRM = 90; DIMM = 75 }

function Log([string]$s) { $line = "$(Get-Date -Format HH:mm:ss) $s"; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Host $line }

function Read-Raw([int]$num) {
    $r = Invoke-Ipmi 0x04 0x2D ([byte[]]@($num))
    if ($r[0] -ne 0 -or ($r[2] -band 0x20)) { return $null }
    return [int]$r[1]
}
function Read-All {
    $s = [ordered]@{}
    foreach ($k in $FAN.Keys) { $v = Read-Raw $FAN[$k]; $s[$k] = if ($null -eq $v) { $null } else { $v * 100 } }
    foreach ($k in $TEMP.Keys) { $s[$k] = Read-Raw $TEMP[$k] }
    return $s
}
function Format-Sample($s) { ($s.Keys | ForEach-Object { "$_=$($s[$_])" }) -join ' ' }
function Set-Zone([int]$zone, [int]$pct) { [void](Invoke-Ipmi 0x30 0x70 ([byte[]]@(0x66, 0x01, $zone, $pct))) }
function Set-FullMode { [void](Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x01, 0x01))) }
function Set-OptimalMode { [void](Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x01, 0x02))) }

# CPU load: one thread per logical CPU running dependent floating-point math until told to stop.
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class Burner {
    static volatile bool running;
    static Thread[] threads = new Thread[0];
    public static void Start(int n) {
        running = true;
        threads = new Thread[n];
        for (int i = 0; i < n; i++) {
            threads[i] = new Thread(() => {
                double a = 1.0001, b = 0.9999, c = 0.5;
                while (running) {
                    for (int j = 0; j < 1000000; j++) { c = c * a + b; c = c * b - a + 1.0; }
                }
                if (c == 42) Console.Write("");
            });
            threads[i].IsBackground = true;
            threads[i].Priority = ThreadPriority.BelowNormal;
            threads[i].Start();
        }
    }
    public static void Stop() { running = false; foreach (var t in threads) t.Join(5000); }
}
'@

function Test-Spike($s, $baseline) {
    # The BMC fail-safe drives every fan to full: FANA jumps well above where this step started.
    return ($null -ne $baseline -and $null -ne $s.FANA -and $s.FANA -gt [Math]::Max($baseline * 1.6, $baseline + 800))
}

# Steps down one zone while the other is held, soaking each step. Returns the lowest passing duty,
# or $null if none passed. A failing step ends the search; the zone is then left at that failing
# duty, and the caller sets both zones explicitly before using them.
function Find-Floor([int]$zone, [int[]]$steps, [int]$otherPct) {
    $other = 1 - $zone
    $passed = $null
    foreach ($pct in $steps) {
        Set-Zone $zone $pct
        Set-Zone $other $otherPct
        Start-Sleep -Seconds 20
        $base = (Read-All).FANA
        $minCase = [int]::MaxValue; $minFan1 = [int]::MaxValue; $maxCpu = 0; $fail = $null
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt $SOAK_SECONDS) {
            $s = Read-All
            Log ("  zone{0} {1,2}% {2}" -f $zone, $pct, (Format-Sample $s))
            foreach ($k in 'FANA', 'FANB') { if ($null -eq $s[$k]) { $fail = "$k unreadable" } elseif ($s[$k] -lt $minCase) { $minCase = $s[$k] } }
            if ($null -eq $s.FAN1) { if ($HAS_FAN1) { $fail = 'FAN1 unreadable' } } elseif ($s.FAN1 -lt $minFan1) { $minFan1 = $s.FAN1 }
            if ($s.CPU -gt $maxCpu) { $maxCpu = $s.CPU }
            if (Test-Spike $s $base) { $fail = "BMC fail-safe spike (FANA $base -> $($s.FANA))" }
            if ($minCase -le $CASE_STOP_RPM) { $fail = "case fan at $minCase RPM" }
            if ($minFan1 -le $FAN1_STOP_RPM) { $fail = "FAN1 at $minFan1 RPM" }
            if ($s.CPU -ge $IDLE_CPU_LIMIT) { $fail = "CPU at $($s.CPU) C at idle" }
            if ($fail) { break }
            Start-Sleep -Seconds $SAMPLE_SECONDS
        }
        if ($fail) { Log "STEP zone$zone $pct % FAILED: $fail"; break }
        if ($minCase -lt $CASE_MIN_RPM -or $minFan1 -lt $FAN1_MIN_RPM) {
            Log "STEP zone$zone $pct % held but too close to the alarm (case $minCase, FAN1 $minFan1 RPM); not used"
            break
        }
        $fan1Text = if ($minFan1 -eq [int]::MaxValue) { 'n/a' } else { $minFan1 }
        $passed = $pct
        Log "STEP zone$zone $pct % OK: case min $minCase, FAN1 min $fan1Text RPM, CPU max $maxCpu C"
    }
    return $passed
}

$floor = $null; $floor0 = $null
try {
    Log "== start: idle floor search, soak $SOAK_SECONDS s per step"
    $before = Read-All
    Log ("before: " + (Format-Sample $before))
    $script:HAS_FAN1 = $null -ne $before.FAN1
    if (-not $HAS_FAN1) { Log "FAN1 not readable (sensor removed from the SDR?): its RPM checks are skipped" }
    Set-FullMode
    Start-Sleep -Seconds 5

    # ---- phase 1a: case fans (zone 1), CPU fan held at 20 % ----
    Log "== phase 1a: zone1 floor, zone0 at $ZONE0_PCT %"
    $floor = Find-Floor 1 $IDLE_STEPS $ZONE0_PCT
    if ($null -eq $floor) { Log "No zone1 step passed. Stopping before the stress test."; return }
    Log "== zone1 floor: $floor %"

    # ---- phase 1b: CPU fan (zone 0), case fans held at their floor ----
    Log "== phase 1b: zone0 floor, zone1 at $floor %"
    if ($HAS_FAN1) {
        $floor0 = Find-Floor 0 $ZONE0_STEPS $floor
        if ($null -eq $floor0) { $floor0 = $ZONE0_PCT; Log "No zone0 step below $ZONE0_PCT % passed; keeping $ZONE0_PCT %" }
    } else {
        # Without a tach reading nothing would notice the CPU fan stopping, so do not go lower.
        $floor0 = $ZONE0_PCT
        Log "FAN1 has no sensor: skipping the zone0 search, keeping $ZONE0_PCT %"
    }
    Log "== zone0 floor: $floor0 %"

    # ---- phase 2: CPU stress at both floors ----
    Set-Zone 0 $floor0
    Set-Zone 1 $floor
    Start-Sleep -Seconds 20
    $n = [Environment]::ProcessorCount
    Log "== stress: $n threads for $STRESS_SECONDS s, zone0 $floor0 %, zone1 $floor %"
    $base = (Read-All).FANA
    [Burner]::Start($n)
    $t0 = Get-Date
    $abort = $null
    while (((Get-Date) - $t0).TotalSeconds -lt $STRESS_SECONDS) {
        Start-Sleep -Seconds $SAMPLE_SECONDS
        $s = Read-All
        Log ("  stress t={0,3}s {1}" -f [int]((Get-Date) - $t0).TotalSeconds, (Format-Sample $s))
        $vrm = @($s.VRMCpu, $s.VRMSoc, $s.VRMABCD, $s.VRMEFGH) | Measure-Object -Maximum
        $dimm = @($s.DIMMA1, $s.DIMMC1) | Measure-Object -Maximum
        if ($s.CPU -ge $LIMIT.CPU) { $abort = "CPU $($s.CPU) C" }
        elseif ($vrm.Maximum -ge $LIMIT.VRM) { $abort = "VRM $($vrm.Maximum) C" }
        elseif ($dimm.Maximum -ge $LIMIT.DIMM) { $abort = "DIMM $($dimm.Maximum) C" }
        elseif (Test-Spike $s $base) { $abort = "BMC fail-safe spike (FANA $base -> $($s.FANA))" }
        if ($abort) { break }
    }
    [Burner]::Stop()
    if ($abort) {
        Log "STRESS ABORTED: $abort. Fans to 100 % for cooldown."
        Set-Zone 0 100; Set-Zone 1 100
    } else {
        Log "STRESS COMPLETED at zone1 $floor %"
    }

    Log "== cooldown $COOLDOWN_SECONDS s"
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $COOLDOWN_SECONDS) {
        Start-Sleep -Seconds 20
        Log ("  cool {0}" -f (Format-Sample (Read-All)))
    }
}
catch {
    Log "ERROR: $($_.Exception.Message)"
}
finally {
    try { [Burner]::Stop() } catch { }
    Set-OptimalMode
    Log "== DONE. Optimal mode restored. zone1 floor: $floor %, zone0 floor: $floor0 %"
}
