param(
    [Parameter(Mandatory = $true)]
    [string]$ComPort,

    [ValidateSet('768', '1024')]
    [string]$Mode = '768',

    [string]$PythonExe = 'python',

    [int]$TimeoutSeconds = 180,

    [string]$SeedD = '',

    [string]$SeedZ = '',

    [string]$Message = '',

    [string]$EvidencePath = '',

    [ValidateRange(1, 1000000000)]
    [int]$CoreClockHz = 150000000
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$oracleScript = Join-Path $projectRoot '08_model\python\mlkem_uart_oracle.py'

if (-not (Test-Path -LiteralPath $oracleScript)) {
    throw "Khong tim thay oracle: $oracleScript"
}

$providedVectorCount = @($SeedD, $SeedZ, $Message).Where({
    -not [string]::IsNullOrWhiteSpace($_)
}).Count
if (($providedVectorCount -ne 0) -and ($providedVectorCount -ne 3)) {
    throw 'Phai cung cap dong thoi SeedD, SeedZ va Message, hoac bo trong ca ba'
}

$oracleArguments = @($oracleScript, '--mode', $Mode)
if ($providedVectorCount -eq 3) {
    $oracleArguments += @('--d', $SeedD, '--z', $SeedZ, '--m', $Message)
    Write-Host "Chay lai vector da cung cap cho ML-KEM-$Mode ..."
} else {
    Write-Host "Tao vector ngau nhien va chay oracle ML-KEM-$Mode ..."
}
$oracleText = (& $PythonExe @oracleArguments 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "Oracle that bai: $oracleText"
}
$oracle = $oracleText | ConvertFrom-Json

$port = [System.IO.Ports.SerialPort]::new(
    $ComPort,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$port.Handshake = [System.IO.Ports.Handshake]::None
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.ReadTimeout = 500
$port.WriteTimeout = 3000
$port.NewLine = "`n"

$lines = [System.Collections.Generic.List[string]]::new()
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

try {
    $port.Open()
    $port.DiscardInBuffer()
    $port.DiscardOutBuffer()
    Write-Host "Gui 96 byte d || z || m qua $ComPort ..."
    $port.Write([string]$oracle.frame)

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $line = $port.ReadLine().Trim()
            if ($line.Length -gt 0) {
                $lines.Add($line)
                Write-Host $line
                if ($line -like 'FINAL:*') {
                    break
                }
            }
        }
        catch [System.TimeoutException] {
            # Tiep tuc doi vi ML-KEM-1024 can nhieu chu ky hon.
        }
    }
}
finally {
    if ($port.IsOpen) {
        $port.Close()
    }
    $port.Dispose()
}

if (($lines.Count -eq 0) -or ($lines[$lines.Count - 1] -ne 'FINAL: PASS')) {
    throw "Khong nhan duoc FINAL: PASS trong $TimeoutSeconds giay"
}

$result = @{}
foreach ($line in $lines) {
    $separator = $line.IndexOf(':')
    if ($separator -gt 0) {
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $result[$key] = $value
    }
}

$checks = @(
    @('EK_CRC32', [string]$oracle.ek_crc32),
    @('DK_CRC32', [string]$oracle.dk_crc32),
    @('CT_CRC32', [string]$oracle.ct_crc32),
    @('SS_ENCAPS', [string]$oracle.ss_encaps),
    @('SS_DECAPS', [string]$oracle.ss_decaps),
    @('ERROR_CODE', '00')
)

$mismatches = [System.Collections.Generic.List[string]]::new()
foreach ($check in $checks) {
    $name = $check[0]
    $expected = $check[1].ToUpperInvariant()
    $actual = if ($result.ContainsKey($name)) {
        ([string]$result[$name]).ToUpperInvariant()
    } else {
        '<MISSING>'
    }
    if ($actual -ne $expected) {
        $mismatches.Add("$name actual=$actual expected=$expected")
    }
}

if ($mismatches.Count -ne 0) {
    $mismatches | ForEach-Object { Write-Error $_ }
    throw 'FPGA khong trung oracle'
}

Write-Host ''
Write-Host 'HOST_ORACLE_CHECK: PASS' -ForegroundColor Green
Write-Host "ML-KEM-${Mode}: ek=$($oracle.ek_bytes) dk=$($oracle.dk_bytes) ct=$($oracle.ct_bytes) byte"
foreach ($name in @('KEYGEN_CYCLES_HEX', 'ENCAPS_CYCLES_HEX',
                     'DECAPS_VALID_CYCLES_HEX', 'REJECT_CYCLES_HEX',
                     'TOTAL_CYCLES_HEX')) {
    if ($result.ContainsKey($name)) {
        $cycles = [Convert]::ToUInt32([string]$result[$name], 16)
        $milliseconds = ($cycles * 1000.0) / $CoreClockHz
        Write-Host ('{0,-26} {1,10} cycles = {2:N3} ms' -f
                    $name, $cycles, $milliseconds)
    }
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
    $EvidencePath = Join-Path $projectRoot (
        "09_reports\channel\uart\uart_live_${Mode}_$timestamp.json"
    )
}

$evidenceDirectory = Split-Path -Parent $EvidencePath
if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
    New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
}

$evidence = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    result = 'PASS'
    com_port = $ComPort
    uart = '115200-8N1-no-flow-control'
    configured_core_clock_hz = $CoreClockHz
    mode = $Mode
    oracle = $oracle
    fpga_lines = @($lines)
    fpga_fields = $result
}
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Write-Host "Bang chung JSON: $EvidencePath"
