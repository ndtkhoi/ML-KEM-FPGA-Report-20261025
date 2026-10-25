# All compiled RTL and SV testbenches belong to the selected private tree.
param(
    [ValidateSet(2,8)][int]$Lanes=2,
    [ValidateSet('quick','full')][string]$Mode='full',
    [string]$ModelsimBin='D:\QUARTUS\modelsim_ase\win32aloem',
    [string]$PythonExe=''
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(!$PythonExe){$PythonExe=(Get-Command python -ErrorAction Stop).Source}
$variant="streaming_balanced_${Lanes}bu"
$run=Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$sim=Join-Path $root "04_sim/$variant/run_$run"
$reports=Join-Path $root "09_reports/$variant/run_$run"
$work=Join-Path $sim 'work'
$summary=Join-Path $reports 'summary.txt'
New-Item -ItemType Directory -Force -Path $sim,$reports | Out-Null
"STREAMING_${Lanes}BU_${Mode}: RUNNING run=$run" | Set-Content -LiteralPath $summary
Write-Host "STREAMING_${Lanes}BU_REPORTS: $reports"
Copy-Item -LiteralPath (Join-Path $root '03_vectors') -Destination $sim -Recurse
New-Item -ItemType Directory -Force -Path (Join-Path $sim '08_model/python'),(Join-Path $sim '02_tb/host') | Out-Null
Get-ChildItem (Join-Path $root '08_model/python') -File -Filter '*.py' | Copy-Item -Destination (Join-Path $sim '08_model/python')
Copy-Item -LiteralPath (Join-Path $root '02_tb/host/test_channel_host.py') -Destination (Join-Path $sim '02_tb/host')
$qdir=Join-Path $root "05_quartus/$variant"
$qsf=Join-Path $qdir "mlkem_${variant}_de10.qsf"
$sdc=Join-Path $root "01_rtl/architectures/$variant/constraints/mlkem_channel_160.sdc"
$rtlRoot=[IO.Path]::GetFullPath((Join-Path $root "01_rtl/architectures/$variant/rtl"))+[IO.Path]::DirectorySeparatorChar
$tbRoot=Join-Path $root "02_tb/architectures/$variant"
$cases=[ordered]@{
    tb_mod_mul_pipeline='MOD_MUL_PIPELINE: ALL TESTS PASS';tb_compress_seq='COMPRESS_SEQ: ALL TESTS PASS'
    tb_codec_sampler='CODEC_SAMPLER_REGRESSION: PASS';tb_clock_uart_100='CLOCK_UART: ALL TESTS PASS ref=50MHz core=160MHz'
    tb_ntt_intt='NTT_INTT_ROUND_TRIP: PASS';tb_ntt_banked_guards='NTT_BANKED_GUARDS: ALL TESTS PASS'
    tb_multiply_ntts='MULTIPLY_NTTS_FIPS203_ALG11: PASS';tb_keccak_sponge='KECCAK_SPONGE_REGRESSION: PASS'
    tb_keccak_sponge_clear='KECCAK_SPONGE_CLEAR: ALL TESTS PASS';tb_keccak_kat='KECCAK_SHA3_SHAKE_KAT: PASS'
    tb_random_subsystem='TRNG_HEALTH_SHAKE256_DRBG: PASS';tb_mlkem_service_core='MLKEM_SERVICE_CORE: ALL TESTS PASS'
    tb_channel_crypto='CHANNEL_CRYPTO: ALL TESTS PASS';tb_opt100_memory_guards='OPT100_MEMORY_GUARDS: ALL TESTS PASS'
    tb_channel_pipeline_guards='CHANNEL_PIPELINE_GUARDS: ALL TESTS PASS';tb_channel_record='CHANNEL_RECORD: ALL TESTS PASS'
    tb_channel_top='CHANNEL_TOP: ALL TESTS PASS'
}
if($Mode -eq 'quick'){$cases=[ordered]@{tb_ntt_intt='NTT_INTT_ROUND_TRIP: PASS';tb_ntt_banked_guards='NTT_BANKED_GUARDS: ALL TESTS PASS';tb_multiply_ntts='MULTIPLY_NTTS_FIPS203_ALG11: PASS'}}
Push-Location $sim
try {
    foreach($generator in @('generate_full_vectors.py','generate_service_vectors.py','generate_channel_vectors.py','validate_mlkem_acvp.py')){
        $output=& $PythonExe "08_model/python/$generator" 2>&1;$exitCode=$LASTEXITCODE
        $output | Set-Content -LiteralPath (Join-Path $reports "$generator.log")
        if($exitCode -ne 0){throw "Reference generator failed: $generator"}
    }
    $rtl=@(Get-Content -LiteralPath $qsf | ForEach-Object {if($_ -match 'SYSTEMVERILOG_FILE\s+(\S+)'){[IO.Path]::GetFullPath((Join-Path $qdir $Matches[1]))}})
    if($rtl.Count -ne 36 -or @($rtl|Select-Object -Unique).Count -ne 36){throw 'Expected 36 distinct configured RTL files'}
    foreach($f in $rtl){if(!$f.StartsWith($rtlRoot,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $f -PathType Leaf)){throw "Non-isolated or missing RTL: $f"}}
    $macros=@(Get-Content -LiteralPath $qsf | ForEach-Object {if($_ -match 'VERILOG_MACRO\s+(\S+)'){$Matches[1]}})
    $expected=@('SYNTHESIS','CONTINUOUS_BANKED_FAST_FRONTEND','CONTINUOUS_BANKED_CYCLE_OPT','CONTINUOUS_BANKED_BYTE_STREAM_OPT','CONTINUOUS_BANKED_V2_TIMING_FIX',"MLKEM_STREAMING_BALANCED_${Lanes}BU")
    if(($macros -join ',') -ne ($expected -join ',')){throw "Unexpected architecture defines: $macros"}
    $defines=@($macros|Where-Object {$_ -ne 'SYNTHESIS'}|ForEach-Object {"+define+$_"})
    $sources=$rtl+@($cases.Keys|ForEach-Object {Join-Path $tbRoot "$_.sv"})+@(Join-Path $tbRoot 'tb_sampler_busy_contract.sv')
    $tracked=@($sources)+@($qsf,$sdc,$PSCommandPath,(Join-Path $sim '02_tb/host/test_channel_host.py'))+
        @(Get-ChildItem (Join-Path $sim '03_vectors') -File -Recurse|ForEach-Object FullName)+
        @(Get-ChildItem (Join-Path $sim '08_model/python') -Filter '*.py' -File|ForEach-Object FullName)
    $hashes=@($tracked|ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}})
    [ordered]@{run=$run;architecture=$variant;lanes=$Lanes;banks=2*$Lanes;mode=$Mode;project=$qsf;rtl_count=36;tests=@($cases.Keys);simulation_defines=$defines;files=$hashes;scope='Functional RTL, private vectors; no synthesis/fitter/STA. Python ACVP validates the reference model, not RTL certification.'} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $reports 'inputs.json') -Encoding UTF8
    Copy-Item -LiteralPath $qsf,$sdc -Destination $reports
    & (Join-Path $ModelsimBin 'vlib.exe') $work
    if($LASTEXITCODE -ne 0){throw 'Work creation failed'}
    foreach($source in $sources){
        $output=& (Join-Path $ModelsimBin 'vlog.exe') -sv @defines -work $work $source 2>&1
        $output | Add-Content -LiteralPath (Join-Path $reports 'compile.log')
        if($LASTEXITCODE -ne 0 -or $output -match '\*\* Error'){throw "SV compilation failed: $source"}
    }
    $pllCount=0;$hostCount=0;$negativeCount=0
    if($Mode -eq 'full'){
        $pllWork=Join-Path $sim 'pll_work'; & (Join-Path $ModelsimBin 'vlib.exe') $pllWork
        if($LASTEXITCODE -ne 0){throw 'PLL work creation failed'}
        $pllSources=@((Join-Path $rtlRoot 'top/clock_100.sv'),(Join-Path $rtlRoot 'uart/uart_tx.sv'),(Join-Path $rtlRoot 'uart/uart_rx.sv'),(Join-Path $tbRoot 'tb_clock_uart_100.sv'))
        $output=& (Join-Path $ModelsimBin 'vlog.exe') -sv -work $pllWork '+define+SYNTHESIS' @pllSources 2>&1
        $output | Set-Content -LiteralPath (Join-Path $reports 'pll_compile.log')
        if($LASTEXITCODE -ne 0 -or $output -match '\*\* Error'){throw 'Vendor PLL compilation failed'}
        foreach($mhz in @(100,110,150,160)){
            $output=& (Join-Path $ModelsimBin 'vsim.exe') -c -onfinish exit -lib $pllWork -L altera_lnsim_ver -L altera_mf_ver -L cyclonev_ver -wlf (Join-Path $sim "pll_$mhz.wlf") -l (Join-Path $reports "pll_vendor_$mhz.transcript.log") tb_clock_uart_100 "-gCLOCK_MHZ=$mhz" -do 'run -all; quit -f' 2>&1
            $output | Set-Content -LiteralPath (Join-Path $reports "pll_vendor_$mhz.log")
            if($LASTEXITCODE -ne 0 -or $output -match '\*\* (Fatal|Error)' -or -not ($output -match "CLOCK_UART: ALL TESTS PASS ref=50MHz core=${mhz}MHz")){throw "PLL test failed: $mhz MHz"}
            $pllCount++
        }
    }
    foreach($test in $cases.Keys){
        $output=& (Join-Path $ModelsimBin 'vsim.exe') -c -onfinish exit -lib $work -wlf (Join-Path $sim "$test.wlf") -l (Join-Path $reports "$test.transcript.log") $test -do 'run -all; quit -f' 2>&1
        $output | Set-Content -LiteralPath (Join-Path $reports "$test.log")
        $output | Where-Object {$_ -match 'PASS|Fatal|Error|cycles='}|ForEach-Object {Write-Host $_}
        if($LASTEXITCODE -ne 0 -or $output -match '\*\* (Fatal|Error)' -or -not ($output -match [regex]::Escape($cases[$test]))){throw "RTL test failed: $test"}
    }
    if($Mode -eq 'full'){
        foreach($test in @(@{script='08_model/python/channel_demo.py';arguments=@('--selftest');marker='CHANNEL_HOST_SELFTEST: PASS'},@{script='02_tb/host/test_channel_host.py';arguments=@();marker='CHANNEL_HOST_FLOW: PASS'})){
            $hostArgs=$test.arguments;$output=& $PythonExe $test.script @hostArgs 2>&1;$exitCode=$LASTEXITCODE
            $output | Set-Content -LiteralPath (Join-Path $reports ((Split-Path $test.script -Leaf)+'.log'))
            if($exitCode -ne 0 -or -not ($output -match $test.marker)){throw 'Host test failed'}
            $hostCount++
        }
        $output=& (Join-Path $ModelsimBin 'vsim.exe') -c -onfinish exit -lib $work -wlf (Join-Path $sim 'sampler_busy_contract.wlf') -l (Join-Path $reports 'sampler_busy_contract.transcript.log') tb_sampler_busy_contract -do 'run -all; quit -f' 2>&1
        $output | Set-Content -LiteralPath (Join-Path $reports 'sampler_busy_contract.log')
        if(-not ($output -match '\*\* Fatal: Sampler byte load attempted while busy') -or $output -match 'MISSING_EXPECTED_BUSY_ASSERTION|CONTRACT_TEST_DID_NOT_START|\*\* Error'){throw 'Negative contract test failed'}
        $negativeCount=1
    }
    foreach($entry in $hashes){if((Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash -ne $entry.sha256){throw "Input changed during regression: $($entry.path)"}}
    "STREAMING_${Lanes}BU_${Mode}: PASS run=$run tests=$($cases.Count) vendor_pll=$pllCount host=$hostCount negative_contract=$negativeCount INPUTS_UNCHANGED" | Tee-Object -FilePath $summary
}catch{
    "STREAMING_${Lanes}BU_${Mode}: FAILED run=$run : $($_.Exception.Message)" | Set-Content -LiteralPath $summary
    throw
}finally{Pop-Location}
