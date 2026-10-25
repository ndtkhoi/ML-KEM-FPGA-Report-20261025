# KEY1 demo validation — 2026-10-21

## Current status

Functional simulation: PASS. Physical board test: NOT YET PERFORMED.
The first 160 MHz build (seed 4) completed but FAILED setup timing.
A seed 5 build is in progress. Do not treat the existing SOF as timing-qualified
until this document records a passing final build.

## Simulation

ModelSim regression: `04_sim/streaming_balanced_4bu_keydemo/run_20261021_084322_106`.
Both testbenches finished with ALL TESTS PASS, 0 errors and 0 warnings.

- KEY1: both ML-KEM modes; golden EK, ciphertext and shared secret;
  UART serial output; decimal/hex cycle agreement; full fingerprint and HEX;
  switch mode latched at start; debounce, held button, reset during operation.
- Failure injection: altered saved shared secret returns E2 and wipes keys;
  random timeout/health alarm returns E1 and wipes keys.
- Arbitration: host frame cannot interrupt button demo; button cannot
  interrupt a host transaction.
- Host regression: KEM KeyGen/Decaps, session derivation, AES-GCM,
  tampered tag rejection, replay rejection, LED/HEX and zeroize.

| Mode | KeyGen cycles | Encaps cycles | Decaps cycles |
|---|---:|---:|---:|
| 768 | 70,885 | 94,451 | 130,510 |
| 1024 | 112,617 | 141,510 | 187,731 |

These are deterministic simulation-vector results, not new measurements
on hardware. The testbench substitutes the RNG boundary with fixed vectors;
it does not measure physical TRNG entropy.

## First compile: seed 4

Quartus Prime Lite 18.1, device 5CSXFC6D6F31C6, core clock 160 MHz.
Full compile completed at 09:11:44 (Asia/Bangkok), 0 errors, 220 warnings.
Worst setup slack: -0.229 ns at slow 1100mV 85C; minimum hold slack: +0.103 ns.
Setup and hold requirements reported fully constrained.
Resources: 27,689 ALMs, 38,492 registers, 55 RAM blocks, 40 DSP blocks, 1 PLL.
Reports archived in `09_reports/streaming_balanced_4bu_keydemo/seed4_build`.

Detailed timing identified reset to KDF input RAM, sequence to replay counter,
and Keccak permutation paths. Seed 5 retries placement/routing with the same
RTL, clock and timing constraints. No false-path or relaxed-clock workaround.

## Original hardware-PASS baseline

The original `streaming_balanced_4bu` SOF was not replaced.
Verified SHA-256:
`4B7D41E19643F6B5D7613A50AB75E09193F181D4CA02F62A1F9B75E741268379`.

## Required board check after timing passes

Follow README.md: program the new SOF, connect UART, open PuTTY before
pressing KEY1, run both SW0 modes. Confirm final SELFTEST PASS, matching
Encaps/Decaps SS_SHA3, and the first six hex characters on HEX5..HEX0.
The autonomous test covers local KEM; use the existing PowerShell demo
separately for FPGA–PC interoperability and authenticated-channel evidence.
