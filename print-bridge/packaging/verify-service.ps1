param([Parameter(Mandatory=$true)][string]$ReleaseDirectory, [Parameter(Mandatory=$true)][string]$ResultFile)
$ErrorActionPreference = 'Stop'
$report = [System.Collections.Generic.List[string]]::new()
$journal = $null
$networkJournal = $null
$listener = $null
$receiver = $null
function Health {
    try { return (Invoke-RestMethod 'http://127.0.0.1:17891/health' -Headers @{'X-LPG-Print-Client'='1'} -TimeoutSec 2).version -eq 1 } catch { return $false }
}
function ServiceProcess {
    return Get-CimInstance Win32_Service -Filter "Name='LPGPrintBridge'"
}
function Wait-Recovery([uint32]$Previous) {
    $until = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $current = ServiceProcess
        if ($current.State -eq 'Running' -and $current.ProcessId -ne $Previous -and (Health)) { return $current }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $until)
    throw 'Service recovery did not produce a healthy replacement.'
}
function Run-Exe([string]$File, [string]$Arguments = '') {
    $info = [Diagnostics.ProcessStartInfo]::new($File, $Arguments)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    if (!$process.WaitForExit(90000)) { throw 'Service verification executable timed out.' }
    if ($process.ExitCode -ne 0) { throw "Service verification executable exited with $($process.ExitCode)." }
}
try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator elevation is required for service verification.' }
    Run-Exe (Join-Path $ReleaseDirectory 'LPG Print Bridge Setup.exe') '--quiet'
    $service = ServiceProcess
    if ($service.State -ne 'Running' -or $service.StartMode -ne 'Auto' -or $service.StartName -ne 'LocalSystem' -or !(Health)) { throw 'Automatic LocalSystem service verification failed.' }
    $configuration = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\LPGPrintBridge'
    if ($configuration.DependOnService -notcontains 'Spooler') { throw 'Missing Spooler dependency.' }
    $failure = (& "$env:SystemRoot\System32\sc.exe" qfailure LPGPrintBridge | Out-String)
    foreach ($delay in @('5000', '15000', '60000', '86400')) { if ($failure -notmatch $delay) { throw 'Crash recovery configuration mismatch.' } }
    $report.Add('PASS: installer; Automatic boot startup registered; LocalSystem; Spooler dependency; 5/15/60 second crash recovery.')
    $printers = Invoke-RestMethod 'http://127.0.0.1:17891/printers' -Headers @{'X-LPG-Print-Client'='1'} -TimeoutSec 25
    $report.Add("PASS: Windows Session 0 service discovery returned $(@($printers.printers).Count) installed queues. No physical USB printing.")

    # The receiver is this computer's private adapter and an ephemeral port, never a physical printer.
    $adapter = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object OperationalStatus -eq 'Up' | ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.IPAddressToString -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } | Select-Object -First 1
    if (!$adapter) { throw 'A private network adapter is required for service TCP testing.' }
    $ip = $adapter.Address.IPAddressToString
    $listener = [Net.Sockets.TcpListener]::new($adapter.Address, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $accept = $listener.AcceptTcpClientAsync()
    $requestId = [guid]::NewGuid().ToString()
    $data = Join-Path $env:ProgramData 'LPGManager\PrintBridge'
    $networkJournal = Join-Path $data ("jobs\" + $requestId + '.json')
    $payload = @{
        request_id=$requestId
        config=@{ tenant_id=[guid]::NewGuid().ToString(); paper_width_mm=58; printable_width_dots=384; auto_cut=$false
            printer=@{ transport='network_tcp'; ip_address=$ip; port=$port; protocol='escpos'; device=$null; queue_id="tcp:${ip}:${port}"; host_id='local-network'; queue_name='Service fixture'; port_name="${ip}:${port}"; driver_name='ESC/POS over TCP' } }
        receipt=@{ sale_id=[guid]::NewGuid().ToString(); created_at=[DateTime]::UtcNow.ToString('o'); shop_name='Service rendering fixture'; customer_name='Not a business sale'; customer_phone=''; customer_tier='retail'
            items=@(@{name='TCP fixture receipt'; type='package'; quantity=1; unit_price=100; line_total=100})
            subtotal=100; discount_amount=0; exchange_fee=0; total_amount=100; paid_amount=0; due_amount=100; payments=@(); unattributed_paid=0 }
    } | ConvertTo-Json -Depth 8 -Compress
    $printed = Invoke-RestMethod 'http://127.0.0.1:17891/print' -Method Post -ContentType 'application/json' -Headers @{'X-LPG-Print-Client'='1'} -Body $payload -TimeoutSec 60
    if (!$accept.Wait(5000)) { throw 'Service TCP fixture did not connect.' }
    $receiver = $accept.Result
    $receiver.ReceiveTimeout = 5000
    $stream = $receiver.GetStream()
    $bytes = [IO.MemoryStream]::new()
    $buffer = [byte[]]::new(8192)
    do { $count = $stream.Read($buffer, 0, $buffer.Length); if ($count) { $bytes.Write($buffer, 0, $count) } } while ($count)
    $raster = $bytes.ToArray(); $bytes.Dispose(); $receiver.Close(); $receiver=$null; $listener.Stop(); $listener=$null
    if ($raster.Length -lt 100 -or $raster[0] -ne 27 -or $raster[1] -ne 64 -or !$printed.job_id) { throw 'Service did not render/send an ESC/POS raster receipt.' }
    # The receiver is now closed; success must come from the journal, without a second send.
    $repeated = Invoke-RestMethod 'http://127.0.0.1:17891/print' -Method Post -ContentType 'application/json' -Headers @{'X-LPG-Print-Client'='1'} -Body $payload -TimeoutSec 10
    if ($printed.job_id -ne $repeated.job_id) { throw 'Service request deduplication failed.' }
    $report.Add('PASS: Session 0 rendering and Ethernet delivery to a TCP receiver; same-request deduplication with the receiver closed.')

    $oldHost = [uint32]$service.ProcessId
    $runtime = Get-CimInstance Win32_Process -Filter "ParentProcessId=$oldHost AND Name='node.exe'"
    if (@($runtime).Count -ne 1) { throw 'Expected one contained Node runtime.' }
    Stop-Process -Id $runtime.ProcessId -Force
    $service = Wait-Recovery $oldHost
    $recovered = Invoke-RestMethod 'http://127.0.0.1:17891/print' -Method Post -ContentType 'application/json' -Headers @{'X-LPG-Print-Client'='1'} -Body $payload -TimeoutSec 10
    if ($printed.job_id -ne $recovered.job_id) { throw 'Service crash recovery lost completed job history.' }
    $report.Add('PASS: killed embedded runtime; Windows recovered the service and health endpoint.')
    $oldHost = [uint32]$service.ProcessId
    $oldRuntime = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$oldHost AND Name='node.exe'").ProcessId
    Stop-Process -Id $oldHost -Force
    $service = Wait-Recovery $oldHost
    if (Get-Process -Id $oldRuntime -ErrorAction SilentlyContinue) { throw 'Host crash left an orphan Node runtime.' }
    $report.Add('PASS: killed native host; child containment and Windows service recovery.')
    $oldHost = $service.ProcessId
    Run-Exe (Join-Path $ReleaseDirectory 'Restart LPG Print Bridge.exe')
    $service = Wait-Recovery $oldHost
    Stop-Service LPGPrintBridge
    Run-Exe (Join-Path $ReleaseDirectory 'Restart LPG Print Bridge.exe')
    if (!(Health)) { throw 'Manual start of stopped service failed.' }
    $report.Add('PASS: manual restart launcher; stopped-service start; graceful service stop.')

    $data = Join-Path $env:ProgramData 'LPGManager\PrintBridge'
    $journal = Join-Path $data ("jobs\" + [guid]::NewGuid().ToString() + '.json')
    $reservation = '{"fingerprint":"service-update-verification-reservation"}'
    [IO.File]::WriteAllText($journal, $reservation)
    $settings = (Get-FileHash -LiteralPath (Join-Path $data 'settings.json') -Algorithm SHA256).Hash
    Run-Exe (Join-Path $ReleaseDirectory 'LPG Print Bridge Setup.exe') '--quiet'
    if ([IO.File]::ReadAllText($journal) -ne $reservation -or $settings -ne (Get-FileHash -LiteralPath (Join-Path $data 'settings.json') -Algorithm SHA256).Hash -or !(Health)) { throw 'Update did not preserve settings/journal.' }
    $report.Add('PASS: reinstall/update preserves exact settings and pending job reservation.')
    $service = ServiceProcess
    $runtime = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($service.ProcessId) AND Name='node.exe'"
    $processes = @(Get-Process -Id $service.ProcessId, $runtime.ProcessId)
    $cpu = ($processes | Measure-Object CPU -Sum).Sum
    Start-Sleep -Seconds 5
    $processes = @(Get-Process -Id $service.ProcessId, $runtime.ProcessId)
    $delta = ($processes | Measure-Object CPU -Sum).Sum - $cpu
    $memory = [Math]::Round(($processes | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
    if (@($processes | Where-Object MainWindowHandle -ne 0).Count -ne 0) { throw 'Unexpected application window.' }
    $report.Add("MEASURED: host+runtime idle working set $memory MiB; CPU seconds over 5s: $delta; no application windows.")
    $report.Add('LIMIT: no actual reboot/login interruption or physical printer output was performed.')
} catch {
    $report.Add("FAIL: $($_.Exception.Message)")
    exit 1
} finally {
    if ($receiver) { $receiver.Close() }
    if ($listener) { $listener.Stop() }
    if ($journal -and (Test-Path -LiteralPath $journal)) { Remove-Item -LiteralPath $journal }
    if ($networkJournal -and (Test-Path -LiteralPath $networkJournal)) { Remove-Item -LiteralPath $networkJournal }
    [IO.File]::WriteAllLines($ResultFile, $report)
}
