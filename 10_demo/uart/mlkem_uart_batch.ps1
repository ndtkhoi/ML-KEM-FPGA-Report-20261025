param(
    [Parameter(Mandatory = $true)]
    [string]$ComPort,

    [ValidateSet('768', '1024', 'Both')]
    [string]$Mode = 'Both',

    [ValidateRange(1, 100)]
    [int]$Trials = 5,

    [string]$PythonExe = 'python',

    [ValidateRange(1, 1000000000)]
    [int]$CoreClockHz = 150000000
)

$ErrorActionPreference = 'Stop'
$hostScript = Join-Path $PSScriptRoot 'mlkem_uart_host.ps1'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$batchTimestamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss')
$batchDirectory = Join-Path $projectRoot (
    "09_reports\channel\uart\uart_batch_$batchTimestamp"
)
New-Item -ItemType Directory -Force -Path $batchDirectory | Out-Null

$modes = if ($Mode -eq 'Both') { @('768', '1024') } else { @($Mode) }
$completed = 0

foreach ($selectedMode in $modes) {
    for ($trial = 1; $trial -le $Trials; $trial++) {
        Write-Host ''
        Write-Host "=== ML-KEM-$selectedMode random trial $trial/$Trials ==="
        $evidencePath = Join-Path $batchDirectory (
            'mlkem_{0}_trial_{1:D3}.json' -f $selectedMode, $trial
        )
        & $hostScript `
            -ComPort $ComPort `
            -Mode $selectedMode `
            -PythonExe $PythonExe `
            -CoreClockHz $CoreClockHz `
            -EvidencePath $evidencePath
        if ($LASTEXITCODE -ne 0) {
            throw "Trial $trial cua ML-KEM-$selectedMode that bai"
        }
        $completed++
        Start-Sleep -Milliseconds 50
    }
}

Write-Host ''
Write-Host "UART_RANDOM_BATCH: PASS trials=$completed" -ForegroundColor Green
Write-Host "Thu muc bang chung: $batchDirectory"
