$ErrorActionPreference = 'Stop'
$capacityRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../.temp/vps-capacity'))
$capacityTools = Join-Path $capacityRoot 'tools'
New-Item -ItemType Directory -Force $capacityTools | Out-Null
$downloads = @(
    @{ Name='k6'; File='k6-v2.3.0-windows-amd64.zip'; Url='https://github.com/grafana/k6/releases/download/v2.3.0/k6-v2.3.0-windows-amd64.zip'; Check='https://github.com/grafana/k6/releases/download/v2.3.0/k6-v2.3.0-checksums.txt' },
    @{ Name='prometheus'; File='prometheus-3.15.1.windows-amd64.zip'; Url='https://github.com/prometheus/prometheus/releases/download/v3.15.1/prometheus-3.15.1.windows-amd64.zip'; Check='https://github.com/prometheus/prometheus/releases/download/v3.15.1/sha256sums.txt' },
    @{ Name='grafana'; File='grafana-13.3.0.windows-amd64.zip'; Url='https://dl.grafana.com/oss/release/grafana-13.3.0.windows-amd64.zip'; Check='https://dl.grafana.com/oss/release/grafana-13.3.0.windows-amd64.zip.sha256' }
)
foreach ($item in $downloads) {
    $archive = Join-Path $capacityTools $item.File
    $checksum = Join-Path $capacityTools ($item.Name + '-checksums.txt')
    if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest $item.Url -OutFile $archive }
    Invoke-WebRequest $item.Check -OutFile $checksum
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not (Select-String -LiteralPath $checksum -SimpleMatch $actual)) { throw "Checksum mismatch: $($item.Name)" }
    Expand-Archive -LiteralPath $archive -DestinationPath $capacityTools -Force
    Write-Output "Installed verified $($item.Name)."
}
python -m pip install --target (Join-Path $capacityRoot 'python') psutil==7.2.2 matplotlib==3.10.8
if ($LASTEXITCODE -ne 0) { throw 'Python dependencies failed' }
