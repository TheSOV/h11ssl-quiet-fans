# H11SSL-i BMC: fan control, the fail-safe spikes, and 3-pin fans

Board: Supermicro H11SSL-i, BIOS 2.1, Windows 11. All commands below are raw IPMI, sent through the
Windows IPMI driver (see [windows-ipmi.md](windows-ipmi.md)).

## Fan zones and commands

| Zone | Headers | Here |
|---|---|---|
| 0 | FAN1-FAN5 | CPU Noctua on FAN1 |
| 1 | FANA, FANB | two case fans |

| Purpose | netfn | Command and data | Notes |
|---|---|---|---|
| Get fan mode | 0x30 | `0x45 0x00` | 0 Standard, 1 Full, 2 Optimal, 4 HeavyIO |
| Set fan mode | 0x30 | `0x45 0x01 <mode>` | persists across host reboots |
| Get zone duty | 0x30 | `0x70 0x66 0x00 <zone>` | percent |
| Set zone duty | 0x30 | `0x70 0x66 0x01 <zone> <0-100>` | only holds in **Full** mode |
| X9-style duty | 0x30 | `0x91 0x5A 0x03 ...` | **not supported** here (cc 0x82) |

Verified on this board with [`fan-control-test.ps1`](../tools/fan-control-test.ps1): every command
answered cc 0x00, the duty read back as set, and FAN1 followed it.

| Command | FAN1 (zone 0) | FANA / FANB (zone 1) |
|---|---|---|
| Optimal | 300 RPM (20 %) | 1300 |
| Full, before any duty (100 %) | 1400 | 1200-1300 |
| zone 0 at 50 % | 700 | 1300 |
| zone 0 at 20 % | 300 | 1300 |
| zone 1 at 50 / 20 / 10 % | 1400 | 1300 / 1300 / 1200 |

## The fail-safe spikes

**Symptom:** every 20-90 s, every fan goes to full speed for 10-20 s. CPU at 37-39 C.

**Cause (from the SEL):** the Noctua's tach reads **0 RPM** for an instant. That crosses LCR and
LNR at once, the BMC goes to fail-safe, and three seconds later the reading is back at 1200-1300
RPM because the fan is now at full speed:

    assert    FAN1  LCR going low   reading 0
    assert    FAN1  LNR going low   reading 0
    deassert  FAN1  LNR going low   reading 13   (x100 RPM)
    deassert  FAN1  LCR going low   reading 13

[`fan-sel.ps1`](../tools/fan-sel.ps1) decodes these. The BMC clock on this board was years off, so
match by pattern, not by timestamp.

**It depends on the mode, not only on the duty:**

| Mode | Zone 0 duty | FAN1 | Watched | Spikes |
|---|---|---|---|---|
| Full | 20 % | 300 RPM | 19 min, every 10 s | 0 |
| Optimal | 20 % (read back) | 300 RPM | 25 min, every 10 s | 8 |

Same duty as read back, same RPM between events. The likely explanation is that Optimal briefly
drives the duty below what `0x70 0x66 0x00` reports, low enough for the Noctua to stall or for its
tach to drop out. That is inferred from the contrast above, not observed directly.

**Why lowering the threshold does not fix it:** the reading is 0, not 100. A threshold of 0 is still
crossed by a reading of 0, and a fan that has really stopped also reads 0. On this board there is
no threshold that separates the glitch from a dead fan.

**What was done:** the FAN1 record was deleted (see below). The BMC no longer reads that fan, the
spikes stop, and Optimal keeps ramping it with CPU temperature. What is lost is stall detection on
the CPU fan; the CPU temperature curve and the CPU's own throttling are what is left.

The alternative is Full mode with a fixed floor (20 % held for 19 min with no event) plus a
controller on the host that follows temperature. That keeps FAN1 monitored, but if the controller
or Windows stops, the fans stay wherever they were. Not done here.

## Deleting and restoring a sensor record

A Supermicro BMC keeps sensor definitions in its SDR repository, and a record can be removed
(`Delete SDR`, netfn 0x0A cmd 0x26) or added back (`Partial Add SDR`, 0x0A 0x25). Removing a
fan's record is a common fix for the spikes above; here it had been done months earlier, with
IPMICFG or ipmitool, and nobody remembered exactly how.

**How to tell a record was deleted, without anyone's memory:**

- Record IDs on this BMC are spaced 0x43 apart. FAN1 was missing between DIMMH1 at `0x03F1` and
  FAN2 at `0x0477`, exactly one slot.
- `Get SDR Repository Info` (0x0A 0x20) carries a **most-recent-erase timestamp**. Here it decoded
  to the date the record was removed.
- A header with nothing plugged in still has a record and reads `n/a`; a deleted one is absent from
  the SDR and answers `Get Sensor Reading` with cc 0xCB.

**Restoring** ([`fan1-restore.ps1`](../tools/fan1-restore.ps1)): clone FAN2's full record, set
the sensor number to 65, the entity instance one below FAN2's, the name to `FAN1`, and the lower
thresholds to 100 RPM, then write it with `Partial Add SDR` in 16-byte chunks. The BMC gave it back
its old ID, `0x0434`. Dry run by default.

**Removing** ([`fan1-remove.ps1`](../tools/fan1-remove.ps1)): find the record by sensor number,
`Delete SDR` it, check it is gone, cold-reset.

**After either, the BMC needs a cold reset** (netfn 0x06 cmd 0x02) before it starts or stops
scanning the sensor. The host keeps running and the fans go to full for 1-2 minutes. The BMC
answers `Get Device ID` well before its sensors are ready: for some time afterwards **every**
sensor, FANA and FANB included, returns cc 0xCB. Wait until a known sensor reads again before
concluding anything.

## 3-pin fans are not controllable

FANA and FANB stayed at 1200-1300 RPM from 10 % to 100 %. They are 3-pin. Supermicro fan headers
drive speed through the PWM wire only and keep the supply at 12 V, so a 3-pin fan runs at full
speed. The same fans slow down on a desktop board, which varies the voltage on 3-pin headers
instead.

Fix: 4-pin PWM fans. Choose ones whose minimum PWM speed stays at or above **300 RPM**: the BMC
reads fans in 100 RPM steps and the lower thresholds here are 100 RPM, so a fan idling at 200 is
one step from the fail-safe, and one that stalls is at it.

## Thresholds as found

| Sensor | LNR / LCR / LNC | UNC / UCR / UNR |
|---|---|---|
| FANA, FANB, FAN1 (restored) | 100 / 100 / 100 RPM | 25300 / 25400 / 25500 RPM |
| CPU Temp | 5 / 5 / 10 C | 90 / 95 / 95 C |
| VRM temps | 5 / 5 / 10 C | 95 / 100 / 105 C |
| DIMM temps | 5 / 5 / 10 C | 80 / 85 / 90 C |

The fan lower thresholds look hand-lowered (all three at the minimum step); the factory values were
not recorded.
