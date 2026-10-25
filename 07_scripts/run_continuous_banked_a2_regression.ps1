# A2 continuous parity-banked regression. All RTL comes from the isolated QSF.
# Includes pipeline guards, vendor PLL models and software-only host tests.
param(
    [string]$ModelsimBin = 'D:\QUARTUS\modelsim_ase\win32aloem',
    [string]$PythonExe = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $PythonExe) {
    $PythonExe = (Get-Command python -ErrorAction Stop).Source
}

$runId = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$runRoot = Join-Path $root "04_sim\continuous_banked\run_$runId"
$work = Join-Path $runRoot 'work'
$reports = Join-Path $root "09_reports\continuous_banked\run_$runId"
$summary = Join-Path $reports 'summary.txt'
New-Item -ItemType Directory -Force -Path $runRoot, $reports | Out-Null

"CONTINUOUS_BANKED_A2_REGRESSION: RUNNING run=$runId" | Set-Content -LiteralPath $summary

# Run in a private vector/model snapshot: generators must not overwrite the
# shared vectors while another architecture is being tested.
Copy-Item -LiteralPath (Join-Path $root '03_vectors') -Destination $runRoot -Recurse
New-Item -ItemType Directory -Path (Join-Path $runRoot '08_model/python') -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $root '08_model/python') -Filter '*.py' -File |
    Copy-Item -Destination (Join-Path $runRoot '08_model/python')
New-Item -ItemType Directory -Path (Join-Path $runRoot '02_tb/host') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root '02_tb/host/test_channel_host.py') -Destination (Join-Path $runRoot '02_tb/host')
Write-Host "A2_REPORTS: $reports"
Push-Location $runRoot
try {
    foreach ($generator in @('generate_full_vectors.py', 'generate_service_vectors.py', 'generate_channel_vectors.py', 'validate_mlkem_acvp.py')) {
        $generatorOutput = & $PythonExe "08_model/python/$generator" 2>&1
        $generatorExit = $LASTEXITCODE
        $generatorOutput | Tee-Object -FilePath (Join-Path $reports "$generator.log")
        if ($generatorExit -ne 0) {
            throw "Reference-vector generation failed: $generator"
        }
    }

    & (Join-Path $ModelsimBin 'vlib.exe') $work
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create ModelSim work library'
    }

    $qdir = Join-Path $root '05_quartus\continuous_banked'
    $qsf = Join-Path $qdir 'mlkem_continuous_banked_de10.qsf'
    $sources = @(Get-Content -LiteralPath $qsf | ForEach-Object {
        if ($_ -match 'SYSTEMVERILOG_FILE\s+(\S+)') {
            [IO.Path]::GetFullPath((Join-Path $qdir $Matches[1]))
        }
    })
    $rtlRoot = [IO.Path]::GetFullPath((Join-Path $root '01_rtl/architectures/continuous_banked/rtl')) + [IO.Path]::DirectorySeparatorChar
    if ($sources.Count -ne 34 -or @($sources | Select-Object -Unique).Count -ne 34) {
        throw 'Expected 34 distinct A2 RTL sources; review QSF before changing this guard.'
    }
    foreach ($source in $sources) {
        if (-not $source.StartsWith($rtlRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Missing or non-A2 RTL source: $source"
        }
    }
    $macros = @(Get-Content -LiteralPath $qsf | ForEach-Object {
        if ($_ -match 'VERILOG_MACRO\s+(\S+)') { $Matches[1] }
    })
    if (($macros -join ',') -ne 'SYNTHESIS,CONTINUOUS_BANKED_FAST_FRONTEND') {
        throw "Unexpected A2 macros: $macros"
    }
    # SYNTHESIS is intentionally excluded: functional simulation uses the PLL
    # and entropy simulation branches, not the vendor FPGA primitives.
    $simDefines = @($macros | Where-Object { $_ -ne 'SYNTHESIS' } | ForEach-Object { "+define+$_" })

    $cases = [ordered]@{
        tb_mod_mul_pipeline  = 'MOD_MUL_PIPELINE: ALL TESTS PASS'
        tb_compress_seq      = 'COMPRESS_SEQ: ALL TESTS PASS'
        tb_codec_sampler     = 'CODEC_SAMPLER_REGRESSION: PASS'
        tb_clock_uart_100    = 'CLOCK_UART: ALL TESTS PASS ref=50MHz core=160MHz'
        tb_ntt_intt          = 'NTT_INTT_ROUND_TRIP: PASS'
        tb_ntt_banked_guards        = 'NTT_BANKED_GUARDS: ALL TESTS PASS'
        tb_multiply_ntts     = 'MULTIPLY_NTTS_FIPS203_ALG11: PASS'
        tb_keccak_sponge     = 'KECCAK_SPONGE_REGRESSION: PASS'
        tb_keccak_sponge_clear = 'KECCAK_SPONGE_CLEAR: ALL TESTS PASS'
        tb_keccak_kat        = 'KECCAK_SHA3_SHAKE_KAT: PASS'
        tb_random_subsystem  = 'TRNG_HEALTH_SHAKE256_DRBG: PASS'
        tb_mlkem_service_core = 'MLKEM_SERVICE_CORE: ALL TESTS PASS'
        tb_channel_crypto    = 'CHANNEL_CRYPTO: ALL TESTS PASS'
        tb_opt100_memory_guards = 'OPT100_MEMORY_GUARDS: ALL TESTS PASS'
        tb_channel_pipeline_guards = 'CHANNEL_PIPELINE_GUARDS: ALL TESTS PASS'
        tb_channel_record    = 'CHANNEL_RECORD: ALL TESTS PASS'
        tb_channel_top       = 'CHANNEL_TOP: ALL TESTS PASS'
        tb_channel_kem_reset_timeout = 'CHANNEL_KEM_RESET_TIMEOUT: PASS'
    }

    foreach ($test in $cases.Keys) {
        $folder = if ($test -in @('tb_ntt_intt', 'tb_ntt_banked_guards', 'tb_multiply_ntts', 'tb_keccak_kat')) {
            'unit'
        } else {
            'full'
        }
        if ($test -in @('tb_ntt_banked_guards', 'tb_channel_pipeline_guards', 'tb_opt100_memory_guards')) {
            $sources += Join-Path $root "02_tb/architectures/continuous_banked/$test.sv"
        } else {
            $sources += Join-Path $root "02_tb/$folder/$test.sv"
        }
    }

    $sources += Join-Path $root '02_tb/architectures/continuous_banked/tb_sampler_busy_contract.sv'
    $sdc = Join-Path $root '01_rtl/architectures/continuous_banked/constraints/mlkem_channel_160.sdc'
    $trackedFiles = @($sources) + @($qsf, $sdc, $PSCommandPath, (Join-Path $runRoot '02_tb/host/test_channel_host.py')) +
        @(Get-ChildItem -LiteralPath (Join-Path $runRoot '03_vectors') -Recurse -File | ForEach-Object FullName) +
        @(Get-ChildItem -LiteralPath (Join-Path $runRoot '08_model/python') -Filter '*.py' -File | ForEach-Object FullName)
    $inputHashes = @($trackedFiles | ForEach-Object {
        [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
    })
    [ordered]@{
        run = $runId; project = $qsf; rtl_count = 34; top = 'mlkem_channel_top';
        simulation_defines = $simDefines; modelsim_bin = $ModelsimBin;
        vendor_pll_mhz = @(100,110,150,160); host_tests = @('CHANNEL_HOST_SELFTEST','CHANNEL_HOST_FLOW');
        python = $PythonExe; tests = @($cases.Keys); files = $inputHashes;
        scope = 'RTL functional regression. Python ACVP validation is not direct RTL ACVP certification. No Quartus compile or STA.'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $reports 'inputs.json') -Encoding UTF8
    Copy-Item -LiteralPath $qsf, $sdc -Destination $reports

    $compileLog = Join-Path $reports 'compile.log'
    $compileOutput = @()
    foreach ($source in $sources) {
        $part = & (Join-Path $ModelsimBin 'vlog.exe') -sv `
            @simDefines -work $work $source 2>&1
        $compileOutput += @($part)
        $compileOutput | Set-Content -LiteralPath $compileLog
        if ($LASTEXITCODE -ne 0 -or $part -match '\*\* Error') {
            throw "Compile failed: $source"
        }
    }

    # Check the SYNTHESIS PLL branch using vendor models, using A2 sources only.
    $pllWork = Join-Path $runRoot 'pll_work'
    & (Join-Path $ModelsimBin 'vlib.exe') $pllWork
    if ($LASTEXITCODE -ne 0) { throw 'PLL work creation failed' }
    $pllSources = @(
        (Join-Path $rtlRoot 'top/clock_100.sv'),
        (Join-Path $rtlRoot 'uart/uart_tx.sv'),
        (Join-Path $rtlRoot 'uart/uart_rx.sv'),
        (Join-Path $root '02_tb/full/tb_clock_uart_100.sv')
    )
    $pllCompile = & (Join-Path $ModelsimBin 'vlog.exe') -sv -work $pllWork '+define+SYNTHESIS' @pllSources 2>&1
    $pllExit = $LASTEXITCODE
    $pllCompile | Set-Content -LiteralPath (Join-Path $reports 'pll_compile.log')
    if ($pllExit -ne 0 -or $pllCompile -match '\*\* Error') { throw 'PLL model compile failed' }
    foreach ($mhz in @(100,110,150,160)) {
        $pllOutput = & (Join-Path $ModelsimBin 'vsim.exe') -c -onfinish exit -lib $pllWork `
            -L altera_lnsim_ver -L altera_mf_ver -L cyclonev_ver `
            -wlf (Join-Path $runRoot "pll_$mhz.wlf") -l (Join-Path $reports "pll_vendor_$mhz.transcript.log") `
            tb_clock_uart_100 "-gCLOCK_MHZ=$mhz" -do 'run -all; quit -f' 2>&1
        $pllExit = $LASTEXITCODE
        $pllOutput | Set-Content -LiteralPath (Join-Path $reports "pll_vendor_$mhz.log")
        $pllOutput | Where-Object { $_ -match 'PASS|Fatal|Error' } | ForEach-Object { Write-Host $_ }
        if ($pllExit -ne 0 -or $pllOutput -match '\*\* (Fatal|Error)' -or
            -not ($pllOutput -match "CLOCK_UART: ALL TESTS PASS ref=50MHz core=${mhz}MHz")) {
            throw "PLL vendor model failed: $mhz MHz"
        }
    }

    foreach ($test in $cases.Keys) {
        $output = & (Join-Path $ModelsimBin 'vsim.exe') -c -onfinish exit -lib $work `
            -wlf (Join-Path $runRoot "$test.wlf") `
            -l (Join-Path $reports "$test.transcript.log") `
            $test -do 'run -all; quit -f' 2>&1
        $output | Set-Content -LiteralPath (Join-Path $reports "$test.log")
        $output | Where-Object { $_ -match 'PASS|Fatal|Error|cycles=' } | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0 -or
            $output -match '\*\* (Fatal|Error)' -or
            -not ($output -match [regex]::Escape($cases[$test]))) {
            throw "Test failed: $test"
        }
    }

    foreach ($hostCase in @(
        @{ script = '08_model/python/channel_demo.py'; arguments = @('--selftest'); marker = 'CHANNEL_HOST_SELFTEST: PASS' },
        @{ script = '02_tb/host/test_channel_host.py'; arguments = @(); marker = 'CHANNEL_HOST_FLOW: PASS' }
    )) {
        $hostArgs = $hostCase.arguments
        $hostOutput = & $PythonExe $hostCase.script @hostArgs 2>&1
        $hostExit = $LASTEXITCODE
        $hostOutput | Tee-Object -FilePath (Join-Path $reports ((Split-Path $hostCase.script -Leaf) + '.log'))
        if ($hostExit -ne 0 -or -not ($hostOutput -match [regex]::Escape($hostCase.marker))) {
            throw "Software-only host test failed: $($hostCase.script)"
        }
    }

    $negative = & (Join-Path $ModelsimBin 'vsim.exe') -c -onfinish exit -lib $work `
        -wlf (Join-Path $runRoot 'sampler_busy_contract.wlf') `
        -l (Join-Path $reports 'sampler_busy_contract.transcript.log') `
        tb_sampler_busy_contract -do 'run -all; quit -f' 2>&1
    $negative | Set-Content -LiteralPath (Join-Path $reports 'sampler_busy_contract.log')
    if (-not ($negative -match '\*\* Fatal: Sampler byte load attempted while busy') -or
        $negative -match 'MISSING_EXPECTED_BUSY_ASSERTION|CONTRACT_TEST_DID_NOT_START|\*\* Error') {
        throw 'A2 sampler contract assertion did not reject the forbidden access as expected'
    }
    Write-Host 'SAMPLER_BUSY_CONTRACT: PASS expected assertion observed (not a legal operating mode)'
    foreach ($entry in $inputHashes) {
        if ((Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Input changed during regression: $($entry.path)"
        }
    }
    "CONTINUOUS_BANKED_A2_REGRESSION: PASS run=$runId tests=$($cases.Count) vendor_pll=4 host=2 negative_contract=1 INPUTS_UNCHANGED" | Tee-Object -FilePath $summary
} catch {
    "CONTINUOUS_BANKED_A2_REGRESSION: FAILED run=$runId : $($_.Exception.Message)" |
        Set-Content -LiteralPath $summary
    throw
} finally {
    Pop-Location
}


