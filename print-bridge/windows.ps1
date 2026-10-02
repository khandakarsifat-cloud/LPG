param([ValidateSet('discover', 'render', 'print')][string]$Action)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function DeviceProperty([string]$Id, [string]$Key) {
  $property = Get-PnpDeviceProperty -InstanceId $Id -KeyName $Key -ErrorAction SilentlyContinue
  if ($property) { return [string]$property.Data }
  return $null
}

try {
  $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
  if ($Action -eq 'discover') {
    # Include remembered USBPRINT devices, so disconnected hardware retains its identity.
    $present = @{}
    foreach ($device in @(Get-PnpDevice -PresentOnly -ErrorAction Stop)) { $present[$device.InstanceId] = ($device.Status -eq 'OK') }
    $devices = @(
      foreach ($device in @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.InstanceId -like 'USBPRINT\*' })) {
        $parent = DeviceProperty $device.InstanceId 'DEVPKEY_Device_Parent'
        $usbId = $parent
        for ($depth = 0; $depth -lt 4 -and $usbId -and $usbId -notmatch '^USB\\VID_'; $depth++) {
          $usbId = DeviceProperty $usbId 'DEVPKEY_Device_Parent'
        }
        $vid = $null; $productId = $null; $serial = $null
        if ($usbId -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})[^\\]*\\(.+)$') {
          $vid = $Matches[1]; $productId = $Matches[2]
          # Windows-generated location identifiers contain '&'; do not call them serial numbers.
          if ($Matches[3] -notmatch '&') { $serial = $Matches[3] }
        }
        $port = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters" -ErrorAction SilentlyContinue).PortName
        [pscustomobject]@{
          device_id = [string]$device.InstanceId
          serial_number = $serial; vendor_id = $vid; product_id = $productId
          manufacturer = (DeviceProperty $device.InstanceId 'DEVPKEY_Device_Manufacturer')
          model = [string]$device.FriendlyName
          present = [bool]$present[$device.InstanceId]
          port_name = $port
        }
      }
    )
    $ports = @(Get-PrinterPort -ErrorAction Stop)
    $queues = @(
      foreach ($printer in @(Get-Printer -ErrorAction Stop)) {
        $port = $ports | Where-Object { $_.Name -eq $printer.PortName } | Select-Object -First 1
        $usb = [bool]($printer.PortName -match 'USB' -or $port.PortMonitor -match 'USB' -or $port.Description -match 'USB')
        $status = [int]$printer.PrinterStatus
        $reason = $null
        if ($status -band 0x0054109B) { $reason = "Windows reports $($printer.PrinterStatus). Check paper, cover, connection and queue." }
        $mapped = $devices | Where-Object { $_.port_name -eq $printer.PortName } | Sort-Object -Property present -Descending | Select-Object -First 1
        if ($mapped -and -not $mapped.present) { $reason = 'USB device disconnected.' }
        [pscustomobject]@{
          queue_name = [string]$printer.Name; port_name = [string]$printer.PortName
          driver_name = [string]$printer.DriverName; supported = $usb
          available = [bool]($usb -and -not $reason); unavailable_reason = $reason
        }
      }
    )
    $machineId = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    @{ host_id = $machineId; printers = $queues; usb_devices = $devices } | ConvertTo-Json -Depth 8 -Compress
  } else {
    Add-Type -Path (Join-Path $PSScriptRoot 'WindowsPrinting.cs') -ReferencedAssemblies System.Drawing
    if ($Action -eq 'render') {
      $lines = @($payload.lines)
      $left = [string[]]@($lines | ForEach-Object { [string]$_.text })
      $right = [string[]]@($lines | ForEach-Object { [string]$_.right })
      $bold = [bool[]]@($lines | ForEach-Object { [bool]$_.bold })
      $center = [bool[]]@($lines | ForEach-Object { [bool]$_.center })
      $bytes = [LPG.WindowsPrinting]::Render($left, $right, $bold, $center, [int]$payload.settings.printable_width_dots, [bool]$payload.settings.auto_cut)
      @{ bytes = [Convert]::ToBase64String($bytes) } | ConvertTo-Json -Compress
    } else {
      $queue = Get-Printer -Name $payload.queue_name -ErrorAction Stop
      if ([int]$queue.PrinterStatus -band 0x0054109B) { throw "Printer unavailable: $($queue.PrinterStatus)." }
      $job = [LPG.WindowsPrinting]::Send([string]$payload.queue_name, [Convert]::FromBase64String($payload.bytes), [string]$payload.title)
      # Drivers can accept RAW bytes while reporting a device error later. Inspect the job briefly.
      Start-Sleep -Milliseconds 1500
      $state = Get-PrintJob -PrinterName $payload.queue_name -ID $job -ErrorAction SilentlyContinue
      if ($state -and ([int]$state.JobStatus -band 0x0662)) { throw "Windows print job $job reports $($state.JobStatus). Check the printer before reprinting." }
      @{ job_id = $job } | ConvertTo-Json -Compress
    }
  }
} catch {
  @{ code = $(if ($Action -eq 'print') { 'PRINT_FAILED' } else { 'WINDOWS_FAILED' }); error = $_.Exception.Message } | ConvertTo-Json -Compress
  exit 1
}

