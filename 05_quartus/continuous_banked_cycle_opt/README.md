# A4 — Continuous Banked Cycle Optimized

Mở `mlkem_continuous_banked_cycle_opt_de10.qpf` tại thư mục này.
Đây là **A4 cũ Opt V2**, đổi tên ngày 25/10/2026. Opt V1 đã lưu trữ;
không gộp hoặc sửa RTL A4 khi đổi tên. Macro `CONTINUOUS_BANKED_V2_TIMING_FIX`
giữ nguyên vì đó là lựa chọn chức năng, không phải tên revision.

Top `mlkem_channel_top`, Cyclone V `5CSXFC6D6F31C6`, clock 160 MHz, seed 4.
34 nguồn riêng từ `../../01_rtl/architectures/continuous_banked_cycle_opt/rtl/`.
SDC riêng đặt cạnh `rtl/`. NTT/INTT vẫn một BU, hai bank.

## Kết quả fit trước đổi tên

Revision gốc `mlkem_continuous_banked_cycle_opt_v2_de10`:

| Chỉ tiêu | Kết quả |
|---|---:|
| ALM | 28.952 |
| Registers | 38.307 |
| M10K | 45 |
| DSP | 28 |
| Setup WNS thấp nhất | +0,006 ns |
| Hold WNS thấp nhất | +0,127 ns |

STA đạt cả bốn corner theo SDC, biên setup nhỏ. Report/SOF gốc giữ tên cũ
để bảo toàn nguồn gốc. Bản chụp bất biến:
`../../09_reports/architecture_tracking/A4_20261025_latest_before_consolidation/`.
Đổi tên QPF không phải lần fit mới. Full Compilation tiếp theo tạo report
và SOF tên `mlkem_continuous_banked_cycle_opt_de10`.

Regression: `07_scripts/run_architecture_comparison_regression.ps1 -Architecture A4`.
Runner đọc QSF mới, tách work/vector và ghi SHA256. Bạn tự chạy
Processing > Start Compilation khi cần tạo database dưới tên revision mới.
