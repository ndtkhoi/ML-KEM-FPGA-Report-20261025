# RTL riêng cho từng kiến trúc

## Danh mục hoạt động sau ngày 25/10/2026

| Project trong 05_quartus | Bộ nguồn riêng trong 01_rtl/architectures | Mã lịch sử |
|---|---|---|
| iterative_baseline | iterative_baseline/rtl | A0 |
| channel | streaming_pingpong/rtl | A1 |
| continuous_banked | continuous_banked/rtl | A2 |
| continuous_banked_cycle_opt | continuous_banked_cycle_opt/rtl | A4, giữ Opt V2 |
| streaming_balanced_4bu | streaming_balanced_4bu/rtl | A5 |
| streaming_balanced_2bu | streaming_balanced_2bu/rtl | SB2 |
| streaming_balanced_8bu | streaming_balanced_8bu/rtl | SB8 |
| streaming_balanced_4bu_keydemo | streaming_balanced_4bu_keydemo/rtl | Demo riêng |

`continuous_banked_cycle_opt` hiện là **A4 cũ Opt V2 đã đạt timing**, được đổi
tên project, RTL và testbench cùng nhau. Opt V1 (A3) và hai biến thể TRNG A2
ver2/ver3 được lưu trữ dưới `backups/a2_a4_consolidate_20261025_0550/`.
Giữ mã A4 trong Excel để tránh trộn số liệu với A3 cũ. Report và SOF lịch sử
giữ tên gốc; một thao tác đổi tên không được xem là lần fit mới.

## Quy tắc sử dụng

- Mỗi QSF liệt kê đúng nguồn riêng, không glob toàn bộ cây architectures.
- SDC đặt trong `constraints/` cạnh `rtl/`, không sửa để che lỗi timing.
- A2: `run_continuous_banked_a2_regression.ps1`.
- A4/A5: `run_architecture_comparison_regression.ps1 -Architecture A4` hoặc A5.
- SB2/SB8: `run_streaming_lane_regression.ps1 -Lanes 2` hoặc 8.
- Runner tách work/vector theo run và lưu `inputs.json` SHA256. Kết quả chỉ
  áp dụng cho đúng hash nguồn, macro và SDC đã kiểm chứng.
- Không chạy lại các script `prepare_*` lịch sử vào cây đã hợp nhất.
- Nguồn chung ngoài architectures và luồng ASIC vẫn giữ riêng.

Bản README tách nguồn lịch sử ngày 23–24/10 nằm trong backup hợp nhất.
