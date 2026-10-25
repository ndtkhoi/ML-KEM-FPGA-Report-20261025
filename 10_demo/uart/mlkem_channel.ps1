param(
    [string]$ComPort='COM5',
    [ValidateSet('768','1024','Switch')][string]$Mode='768',
    [ValidateSet('FPGA','PC')][string]$RandomSource='FPGA',
    [string]$Message='DE10 ML-KEM: truyen du lieu co xac thuc!',
    [string]$OutputDirectory='',
    [string]$PythonExe='',
    [ValidateRange(1,1000000000)][int]$CoreClockHz=150000000,
    [switch]$Presentation,
    [ValidateRange(0,5000)][int]$PresentationDelayMs=0,
    [switch]$SelfTest
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not $PythonExe){$PythonExe=(Get-Command python -ErrorAction Stop).Source}
if(-not(Test-Path -LiteralPath $PythonExe)){throw 'Can Python co cryptography. Truyen -PythonExe duong_dan_python.'}
$pythonMode=if($Mode -eq 'Switch'){'switch'}else{$Mode}
$scriptArgs=@((Join-Path $root '08_model/python/channel_demo.py'),'--port',$ComPort,'--mode',$pythonMode,'--random-source',$RandomSource,'--message',$Message)
$scriptArgs+=@('--core-clock-hz',[string]$CoreClockHz)
if($OutputDirectory){$scriptArgs+=@('--output',$OutputDirectory)}
if($Presentation){$scriptArgs+='--presentation'}
if($PresentationDelayMs -gt 0){$scriptArgs+=@('--presentation-delay-ms',[string]$PresentationDelayMs)}
if($SelfTest){$scriptArgs+='--selftest'}
& $PythonExe @scriptArgs
if($LASTEXITCODE -ne 0){throw 'Channel demo chua PASS. Doc loi phia tren va evidence.json.'}
