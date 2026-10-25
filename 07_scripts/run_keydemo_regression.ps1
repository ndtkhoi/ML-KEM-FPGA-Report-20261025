param([string]$ModelsimBin='D:\QUARTUS\modelsim_ase\win32aloem')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runId=Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$run=Join-Path $root "04_sim\streaming_balanced_4bu_keydemo\run_$runId"
$work=Join-Path $run 'work'
New-Item -ItemType Directory -Force -Path $run | Out-Null
$qdir=Join-Path $root '05_quartus\streaming_balanced_4bu_keydemo'
$sources=@(Get-Content (Join-Path $qdir 'mlkem_streaming_balanced_4bu_keydemo.qsf') | ForEach-Object {
    if($_ -match 'SYSTEMVERILOG_FILE\s+(\S+)'){[IO.Path]::GetFullPath((Join-Path $qdir $Matches[1]))}
})
$sources=@($sources | Select-Object -Unique)
$sources+=Join-Path $root '02_tb/full/tb_channel_keydemo.sv'
# Run the existing serial KEM + AES-GCM regression against the new top as well.
$legacy=Get-Content (Join-Path $root '02_tb/full/tb_channel_top.sv') -Raw
$legacy=$legacy.Replace('module tb_channel_top;','module tb_channel_keydemo_host;').Replace('mlkem_channel_top #(','mlkem_channel_keydemo_top #(.KEY_DEBOUNCE_CYCLES(8),')
$legacy=$legacy.Replace('endmodule',@'
    // A debounced button pressed during a host operation is ignored, not queued.
    initial begin
        wait(dut.reset_sync_n);wait(dut.u_service.core_busy);
        @(negedge dut.clk_sys);KEY[1]=0;
        repeat(40)@(negedge dut.clk_sys);KEY[1]=1;
    end
    always @(posedge dut.clk_sys)
        if(dut.reset_sync_n && dut.board_start) $fatal(1,"KEY1 interrupted host operation");
endmodule
'@)
$hostTb=Join-Path $run 'tb_channel_keydemo_host.sv'
$legacy | Set-Content -LiteralPath $hostTb
$sources+=$hostTb
$defines=@(Get-Content (Join-Path $qdir 'mlkem_streaming_balanced_4bu_keydemo.qsf') | ForEach-Object {
    if($_ -match 'VERILOG_MACRO\s+(\S+)' -and $Matches[1] -ne 'SYNTHESIS'){"+define+$($Matches[1])"}
})
Push-Location $root
try {
    & (Join-Path $ModelsimBin 'vlib.exe') $work
    if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    $compile=& (Join-Path $ModelsimBin 'vlog.exe') -sv @defines -work $work @sources 2>&1
    $compile | Set-Content (Join-Path $run 'compile.log')
    if($LASTEXITCODE -ne 0 -or $compile -match '\*\* Error'){throw "Compile failed: $run\compile.log"}
    foreach($test in @('tb_channel_keydemo','tb_channel_keydemo_host')) {
        $result=& (Join-Path $ModelsimBin 'vsim.exe') -c -onfinish exit -lib $work -voptargs=+acc `
            -wlf (Join-Path $run "$test.wlf") -l (Join-Path $run "$test.log") $test -do 'run -all; quit -f' 2>&1
        $result | Where-Object {$_ -match 'PASS|Fatal|Error|KEYDEMO mode|CHANNEL_TOP op'} | ForEach-Object {Write-Host $_}
        if($LASTEXITCODE -ne 0 -or $result -match '\*\* (Fatal|Error)' -or -not($result -match 'ALL TESTS PASS')) {
            throw "Test failed: $test; see $run"
        }
    }
    "KEYDEMO_REGRESSION: PASS $run" | Tee-Object -FilePath (Join-Path $run 'summary.txt')
} finally {Pop-Location}
