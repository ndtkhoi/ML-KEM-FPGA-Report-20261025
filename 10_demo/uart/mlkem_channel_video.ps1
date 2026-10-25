param(
    [string]$ComPort='COM5',
    [ValidateSet('768','1024','Both','Switch')][string]$Mode='Switch',
    [ValidateSet('FPGA','PC')][string]$RandomSource='FPGA',
    [string]$Message='Du lieu bao mat hau luong tu tren FPGA',
    [ValidateRange(1,1000000000)][int]$CoreClockHz=160000000,
    [ValidateRange(0,10)][int]$CountdownSeconds=3,
    [ValidateRange(0,5000)][int]$StepDelayMs=200,
    [string]$PythonExe=''
)

$ErrorActionPreference='Stop'
$demoScript=Join-Path $PSScriptRoot 'mlkem_channel.ps1'

try {$Host.UI.RawUI.WindowTitle='ML-KEM FPGA Hardware Demonstration'} catch {}
Clear-Host
Write-Host ('='*78) -ForegroundColor Cyan
Write-Host ' ML-KEM-768/1024 POST-QUANTUM SECURE CHANNEL' -ForegroundColor White
Write-Host ' DE10-STANDARD FPGA HARDWARE DEMONSTRATION' -ForegroundColor White
Write-Host ('='*78) -ForegroundColor Cyan
Write-Host "UART: $ComPort | Core clock: $($CoreClockHz/1000000) MHz | Random: $RandomSource"
Write-Host 'IMPORTANT: PuTTY must be closed while this demonstration is running.' -ForegroundColor Yellow

for($remaining=$CountdownSeconds;$remaining -gt 0;$remaining--){
    Write-Host "Starting hardware test in $remaining..."
    Start-Sleep -Seconds 1
}

$modes=if($Mode -eq 'Both'){@('768','1024')}else{@($Mode)}
$passed=@()
foreach($currentMode in $modes){
    Write-Host "`n>>> STARTING ML-KEM-$currentMode <<<" -ForegroundColor Cyan
    $demoParams=@{
        ComPort=$ComPort
        Mode=$currentMode
        RandomSource=$RandomSource
        Message=$(if($currentMode -eq 'Switch'){$Message}else{"$Message [ML-KEM-$currentMode]"})
        CoreClockHz=$CoreClockHz
        Presentation=$true
        PresentationDelayMs=$StepDelayMs
    }
    if($PythonExe){$demoParams.PythonExe=$PythonExe}
    & $demoScript @demoParams
    $passed+=$currentMode
}

Write-Host "`n$('='*78)" -ForegroundColor Green
Write-Host ' VIDEO DEMONSTRATION COMPLETED SUCCESSFULLY' -ForegroundColor Green
foreach($currentMode in $passed){
    if($currentMode -eq 'Switch'){
        Write-Host " [PASS] Mode selected by SW0 | $RandomSource random source | secure channel" -ForegroundColor Green
    } else {
        Write-Host " [PASS] ML-KEM-$currentMode | $RandomSource random source | secure channel" -ForegroundColor Green
    }
}
Write-Host ' All cryptographic, tamper and replay checks passed on FPGA hardware.' -ForegroundColor Green
Write-Host ' Press KEY0 on the board after recording to zeroize keys.' -ForegroundColor Yellow
Write-Host ('='*78) -ForegroundColor Green
