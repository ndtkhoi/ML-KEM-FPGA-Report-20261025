# Functional regression for the iterative in-place architectural baseline.
# Performance-only streaming/pipeline guard tests are intentionally excluded:
# they describe the optimized architecture, not this correctness baseline.
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
$runRoot = Join-Path $root "04_sim\iterative_baseline\run_$runId"
$work = Join-Path $runRoot 'work'
$reports = Join-Path $root "09_reports\iterative_baseline\run_$runId"
$summary = Join-Path $reports 'summary.txt'
New-Item -ItemType Directory -Force -Path $runRoot, $reports | Out-Null

"ITERATIVE_BASELINE_REGRESSION: RUNNING run=$runId" | Set-Content -LiteralPath $summary

# Run in a private vector/model snapshot: generators must not overwrite the
# shared vectors while another architecture is being tested.
Copy-Item -LiteralPath (Join-Path $root '03_vectors') -Destination $runRoot -Recurse
New-Item -ItemType Directory -Path (Join-Path $runRoot '08_model/python') -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $root '08_model/python') -Filter '*.py' -File |
    Copy-Item -Destination (Join-Path $runRoot '08_model/python')
Write-Host "BASELINE_REPORTS: $reports"
Push-Location $runRoot
try {
    foreach ($generator in @('generate_full_vectors.py', 'generate_service_vectors.py', 'validate_mlkem_acvp.py')) {
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

    $qdir = Join-Path $root '05_quartus\iterative_baseline'
    $qsf = Join-Path $qdir 'mlkem_iterative_baseline_de10.qsf'
    $sources = @(Get-Content -LiteralPath $qsf | ForEach-Object {
        if ($_ -match 'SYSTEMVERILOG_FILE\s+(\S+)') {
            [IO.Path]::GetFullPath((Join-Path $qdir $Matches[1]))
        }
    })
    $rtlRoot = [IO.Path]::GetFullPath((Join-Path $root '01_rtl/architectures/iterative_baseline/rtl')) + [IO.Path]::DirectorySeparatorChar
    if ($sources.Count -ne 33 -or @($sources | Select-Object -Unique).Count -ne 33) {
        throw 'Expected 33 distinct baseline RTL sources; review QSF before changing this guard.'
    }
    foreach ($source in $sources) {
        if (-not $source.StartsWith($rtlRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Missing or non-baseline RTL source: $source"
        }
    }
    $macros = @(Get-Content -LiteralPath $qsf | ForEach-Object {
        if ($_ -match 'VERILOG_MACRO\s+(\S+)') { $Matches[1] }
    })
    if (($macros -join ',') -ne 'SYNTHESIS,ITERATIVE_BASELINE_TIMING_FIX') {
        throw "Unexpected baseline macros: $macros"
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
        tb_multiply_ntts     = 'MULTIPLY_NTTS_FIPS203_ALG11: PASS'
        tb_keccak_sponge     = 'KECCAK_SPONGE_REGRESSION: PASS'
        tb_keccak_sponge_clear = 'KECCAK_SPONGE_CLEAR: ALL TESTS PASS'
        tb_keccak_kat        = 'KECCAK_SHA3_SHAKE_KAT: PASS'
        tb_random_subsystem  = 'TRNG_HEALTH_SHAKE256_DRBG: PASS'
        tb_mlkem_service_core = 'MLKEM_SERVICE_CORE: ALL TESTS PASS'
        tb_channel_crypto    = 'CHANNEL_CRYPTO: ALL TESTS PASS'
        tb_channel_record    = 'CHANNEL_RECORD: ALL TESTS PASS'
        tb_channel_top       = 'CHANNEL_TOP: ALL TESTS PASS'
    }

    foreach ($test in $cases.Keys) {
        $folder = if ($test -in @('tb_ntt_intt', 'tb_multiply_ntts', 'tb_keccak_kat')) {
            'unit'
        } else {
            'full'
        }
        if ($test -eq 'tb_keccak_sponge_clear') {
            $sources += Join-Path $root "02_tb/architectures/iterative_baseline/$test.sv"
        } else {
            $sources += Join-Path $root "02_tb/$folder/$test.sv"
        }
    }

    $sdc = Join-Path $root '01_rtl/architectures/iterative_baseline/constraints/mlkem_channel_160.sdc'
    $trackedFiles = @($sources) + @($qsf, $sdc, $PSCommandPath) +
        @(Get-ChildItem -LiteralPath (Join-Path $runRoot '03_vectors') -Recurse -File | ForEach-Object FullName) +
        @(Get-ChildItem -LiteralPath (Join-Path $runRoot '08_model/python') -Filter '*.py' -File | ForEach-Object FullName)
    $inputHashes = @($trackedFiles | ForEach-Object {
        [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
    })
    [ordered]@{
        run = $runId; project = $qsf; rtl_count = 33; top = 'mlkem_channel_top';
        simulation_defines = $simDefines; modelsim_bin = $ModelsimBin;
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

    foreach ($entry in $inputHashes) {
        if ((Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Input changed during regression: $($entry.path)"
        }
    }
    "ITERATIVE_BASELINE_REGRESSION: PASS run=$runId tests=$($cases.Count) INPUTS_UNCHANGED" | Tee-Object -FilePath $summary
} catch {
    "ITERATIVE_BASELINE_REGRESSION: FAILED run=$runId : $($_.Exception.Message)" |
        Set-Content -LiteralPath $summary
    throw
} finally {
    Pop-Location
}
