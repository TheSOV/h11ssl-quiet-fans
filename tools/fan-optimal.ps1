# Emergency: hands fan control back to the BMC (Optimal mode). Must run elevated.
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI
$r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
    NetworkFunction = [byte]0x30; Command = [byte]0x45; Lun = [byte]0; ResponderAddress = [byte]0x20
    RequestData = [byte[]]@(0x01, 0x02); RequestDataSize = [uint32]2
}
"Optimal mode set: cc=0x{0:X2}" -f $r.ResponseData[0]
