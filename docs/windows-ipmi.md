# Raw IPMI from Windows without installing anything

Windows ships an IPMI driver (`Microsoft Generic IPMI Compliant Device` in Device Manager). Its WMI
class `root/wmi:Microsoft_IPMI` has a `RequestResponse` method that sends any raw command to the
BMC over the in-band KCS interface. It needs an elevated prompt; unelevated, WMI answers
`Access denied` (0x80041003).

```powershell
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI

function Invoke-Ipmi([byte]$netFn, [byte]$cmd, [byte[]]$data) {
    if (-not $data) { $data = [byte[]]@() }
    $r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
        NetworkFunction = $netFn; Command = $cmd; Lun = [byte]0; ResponderAddress = [byte]0x20
        RequestData = $data; RequestDataSize = [uint32]$data.Length
    }
    return ,([byte[]]$r.ResponseData)   # byte 0 is the completion code
}

Invoke-Ipmi 0x30 0x45 ([byte[]]@(0x00))   # Supermicro: get fan mode
```

Commands the tools here use:

| Purpose | netfn | cmd | Data |
|---|---|---|---|
| Get Device ID | 0x06 | 0x01 | |
| BMC cold reset | 0x06 | 0x02 | |
| Get Sensor Reading | 0x04 | 0x2D | sensor # |
| Get / Set Sensor Thresholds | 0x04 | 0x27 / 0x26 | sensor # [, mask, LNC, LCR, LNR, UNC, UCR, UNR] |
| Get SDR Repository Info | 0x0A | 0x20 | |
| Reserve SDR / Get SDR | 0x0A | 0x22 / 0x23 | reservation, record ID, offset, length |
| Partial Add SDR / Delete SDR | 0x0A | 0x25 / 0x26 | |
| Get SEL Info / Get SEL Entry | 0x0A | 0x40 / 0x43 | |
| Get LAN parameter (IP = 3) | 0x0C | 0x02 | channel, parameter, set, block |

Read SDR records in 16-byte chunks, a size every BMC accepts. Convert readings with the
record's M, B and exponents (`y = (M*x + B*10^Bexp) * 10^Rexp`); on this board fans are
`raw * 100` RPM and temperatures are `raw` degrees.

## PowerShell traps

All of these produced either a wrong answer or a confusing error in this repo's first drafts. None
of them is IPMI-specific, but byte-level code hits every one.

| Trap | Looks like | What happens | Write instead |
|---|---|---|---|
| Commas inside a method call | `$list.Add("{0} {1}" -f $a, $b)` | The commas separate **method arguments**, so `-f` gets only `$a`. Error: *Index (zero based) must be greater than or equal to zero* | `$list.Add(("{0} {1}" -f $a, $b))` |
| `,` binds tighter than `-band`, `-shr` | `@($id -band 0xFF, $id -shr 8)` | Parsed as `$id -band (0xFF, $id) ...`. Error: *[System.Object[]] does not contain a method named 'op_RightShift'* | `@(($id -band 0xFF), ($id -shr 8))` |
| Shifting a byte | `$b[1] + ($b[2] -shl 8)` | `[byte] -shl 8` stays a byte, so the high byte becomes 0. **No error**: a reservation ID or "next record" pointer is silently wrong | `$b[1] + ([int]$b[2] -shl 8)` |
| Returning an array | `return [byte[]]$r.ResponseData` | PowerShell unrolls it; a one-byte answer becomes a scalar, and `$x[1]` is `$null` | `return ,([byte[]]$r.ResponseData)` |
| Localized counters | `Get-Counter '\Processor(_Total)\% Processor Time'` | Counter paths are translated; on a Spanish Windows this one does not exist | Measure `[Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime` instead |

The third one is the dangerous kind: everything runs, and the numbers are wrong.

## Testing without the hardware

Every script that writes to the BMC was first run against a fake: strip the `$ipmi = ...` line and
the `Invoke-Ipmi` function, prepend a function with the same name that answers from a table, and
shorten the sleeps. That catches parsing and logic errors without touching the BMC. It cannot tell
whether the real BMC accepts a command, which is what `fan-control-test.ps1` is for.
