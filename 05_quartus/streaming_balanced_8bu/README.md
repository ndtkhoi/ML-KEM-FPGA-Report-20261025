# Streaming-Balanced 8BU / 16 bank

Open `mlkem_streaming_balanced_8bu_de10.qpf`, revision of the same name. Top mlkem_channel_top;
Cyclone V 5CSXFC6D6F31C6; target 160 MHz; seed 4; same pins/options as 4BU.

All 36 RTL files are private under `01_rtl/architectures/streaming_balanced_8bu/rtl` and SDC under
its own constraints directory. No RTL, QSF or test file of 4BU was modified.
Only NTT width, bank mapping and required stage scheduling differ logically;
all inherited feature branches use the architecture-specific MLKEM_STREAMING_BALANCED_8BU name.

16 banks x 16 rows x 12 bits; one copy of 256 coefficients.
Arithmetic pipeline is unchanged. Regression-verified NTT/INTT cycles: 127.
8BU needs four idle issue clocks at one stage
boundary in each direction; no full pipeline drain between all stages.

Use Processing > Start Compilation. No full compilation or fit was run during
preparation. Resource and STA results remain unmeasured until your compile.
The existing 4BU uses hand-specialized routes; these variants emit equivalent
bank-local constant candidate muxes rather than a general dynamic crossbar.
This is a complete channel project, not an NTT-only area measurement.

Active NTT instance: `ntt_core_stream8` (macro MLKEM_STREAMING_BALANCED_8BU).
The base file list retains `ntt_core.sv` / `poly_bank_128_sdp.sv` as fallback
definitions; this revision does not instantiate that one-BU fallback.
Measured unit NTT and INTT: 127 clocks; MultiplyNTTs remains 143 clocks.
See `09_reports/architecture_tracking/STREAMING_LANE_VARIANTS_20261025.md`
from the workspace root for source provenance and validation.

Full regression PASS: `09_reports/streaming_balanced_8bu/run_20261025_051014_919`.
17 RTL tests, 4 vendor PLL models, 2 host tests, 1 negative-contract test.
Quartus Analysis & Elaboration: 0 errors; fit/STA remain for your compilation.
