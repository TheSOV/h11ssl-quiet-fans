# H11SSL-i + EPYC: quiet fans from Windows, no tools installed

Notes and PowerShell tools from trying to bring the idle fan speed down on a **Supermicro H11SSL-i**
(EPYC 7532) running **Windows 11**. Everything talks to the BMC through the IPMI driver Windows
already ships (`Microsoft_IPMI` in WMI): no `ipmitool`, no IPMICFG, nothing to install.

Companion to [mc62-g40-quad-3090](https://github.com/TheSOV/mc62-g40-quad-3090), which does the
same on a Gigabyte board under Linux. Different board, different BMC, and some of the findings go
the other way.

## What's here

| Problem | Finding | Doc |
|---|---|---|
| A low-RPM Noctua on FAN1 drives every fan to full speed every 20-90 s | In **Optimal** mode its tach reads **0 RPM** for an instant (SEL: `LCR going low`, reading 0), and the BMC enters fail-safe. In **Full** mode at the same 20 % duty: no event in 19 min. A reading of 0 is also what a dead fan gives, so **no threshold separates the two** | [docs/bmc-fans.md](docs/bmc-fans.md#the-fail-safe-spikes) |
| The usual workaround is deleting the fan's sensor record | It works, and it is reversible: the record can be cloned back from a sibling fan with `Partial Add SDR`. The SDR keeps the timestamp of the last erase, so you can tell it was done | [docs/bmc-fans.md](docs/bmc-fans.md#deleting-and-restoring-a-sensor-record) |
| Case fans stay at ~1300 RPM at any duty, even 100 % | They are **3-pin**. Supermicro headers only control speed through the PWM wire, so 3-pin fans get 12 V and run at full speed. The same fans slow down on a desktop board, which varies the voltage | [docs/bmc-fans.md](docs/bmc-fans.md#3-pin-fans-are-not-controllable) |
| No `ipmitool` on Windows | `Invoke-CimMethod ... RequestResponse` on `root/wmi:Microsoft_IPMI` sends any raw IPMI command, elevated | [docs/windows-ipmi.md](docs/windows-ipmi.md) |
| PowerShell byte handling breaks IPMI code silently | `,` binds tighter than `-band`/`-shr`, `[byte] -shl 8` stays a byte, commas inside `.Add(...)` split method arguments | [docs/windows-ipmi.md](docs/windows-ipmi.md#powershell-traps) |

## Hardware

| | |
|---|---|
| Board | Supermicro H11SSL-i, BIOS 2.1 |
| CPU | AMD EPYC 7532 (32 cores, 64 threads) |
| CPU fan | Noctua, on FAN1 (zone 0): 300 RPM at 20 %, 700 at 50 %, 1400 at 100 % |
| Case fans | two 3-pin fans, on FANA and FANB (zone 1) |
| OS | Windows 11 Pro |

## Tools

PowerShell 5.1, nothing else. Every script needs an **elevated** prompt:

    powershell -ExecutionPolicy Bypass -File tools\<script>.ps1

Output goes to `logs\` (ignored by git). Sensor numbers are this board's; check yours with
`fan-diag.ps1` first.

| Script | Changes anything? | What it does |
|---|---|---|
| [`fan-diag.ps1`](tools/fan-diag.ps1) | no | Fan mode, zone duties, BMC LAN IP, every temperature/fan/voltage sensor with its thresholds |
| [`fan-sdr.ps1`](tools/fan-sdr.ps1) | no | Every SDR record by ID, plus direct probes of sensors 64-72, to find a deleted record |
| [`fan-sel.ps1`](tools/fan-sel.ps1) | no | Last SEL entries, decoded: which sensor crossed which threshold, with the reading |
| [`fan-watch.ps1`](tools/fan-watch.ps1) | no | Watches for N minutes and flags fail-safe spikes: a fan at 2x its baseline with the CPU idle, any new SEL entry, any change in zone duty. The last two still work when no fan's RPM can show a spike (3-pin fans, deleted record) |
| [`fan-control-test.ps1`](tools/fan-control-test.ps1) | temporarily | Does the BMC accept Full mode and per-zone duty, and which fans follow each zone? Restores Optimal |
| [`fan-tune.ps1`](tools/fan-tune.ps1) | temporarily | Lowest safe idle duty for zone 1, then zone 0, then 10 min of load on every thread at those floors. Restores Optimal |
| [`fan-optimal.ps1`](tools/fan-optimal.ps1) | yes | Hands control back to the BMC (Optimal mode). Run it if a script was interrupted in Full mode |
| [`fan1-restore.ps1`](tools/fan1-restore.ps1) | with `-Apply` | Re-creates the FAN1 record by cloning FAN2's, lower thresholds at 100 RPM |
| [`fan1-remove.ps1`](tools/fan1-remove.ps1) | with `-Apply` | Deletes the FAN1 record and cold-resets the BMC |
| [`fan-bmc-reset.ps1`](tools/fan-bmc-reset.ps1) | BMC reset | Cold-resets the BMC and reads the fans back. The host keeps running |

The scripts that write were tested against a simulated BMC before running on the real one, and
each one restores Optimal mode in a `finally` block.

## Where this ended

- **FAN1 record deleted** (as it had been before this work), BMC in **Optimal**. The Noctua idles
  at 300 RPM, the BMC ramps it with CPU temperature, and nothing watches its tach.
- **Case fans: to be replaced with 4-pin PWM ones.** Then `fan-control-test.ps1` and
  `fan-tune.ps1` again. Pick fans whose minimum PWM speed stays **at or above 300 RPM**: the BMC
  reads in 100 RPM steps and the lower thresholds sit at 100.

## Disclaimer

Notes from one machine. Running fans near their limits, deleting sensor records or holding the BMC
in Full mode (which does not follow temperature) can leave hardware without cooling. Use at your
own risk. Not affiliated with Supermicro, AMD or Noctua.

## License

MIT
