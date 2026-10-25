# A2 — Continuous Banked, một BU / hai bank

Mở `mlkem_continuous_banked_de10.qpf`, chọn Processing > Start Compilation.
Top `mlkem_channel_top`, Cyclone V `5CSXFC6D6F31C6`, mục tiêu 160 MHz, seed 2.
34 nguồn riêng ở `01_rtl/architectures/continuous_banked/rtl/`; SDC đặt cạnh rtl.

## Sau lần fit 08:43 ngày 25/10/2026

Lần Full Compilation mới nhất vẫn âm: setup **−0,501 ns**, TNS Slow85
**−14,112 ns**, hold nhỏ nhất bốn corner **+0,080 ns**. Tài nguyên:
27.378 ALM, 37.675 registers, 45 M10K, 28 DSP. Đã lưu run
`A2_20261025_084624` trước khi sửa tiếp.

Đã sửa cấu trúc các đường được TimeQuest chỉ ra: thanh ghi điều khiển pha
Keccak theo lane, bộ đếm đọc lane nhìn trước, selector byte hash one-hot,
tách kiểm tra canonical khỏi bộ đếm, dự đoán terminal khóa và pipeline
ghi RAM riêng trong KDF. Không thêm chu kỳ KEM; giữ 160 MHz, seed 2 và SDC.

Đọc chi tiết và giới hạn tại
`09_reports/architecture_tracking/A2_STRUCTURAL_TIMING_0843_20261025.md`.
Chỉ có kiểm thử chức năng và Analysis & Elaboration của RTL mới; **cần chạy
Full Compilation lại** để biết timing/tài nguyên. Không dùng slack trước sửa
để kết luận RTL mới đã đạt. Các mục bên dưới là lịch sử.

## Lịch sử sửa sau 07:04 ngày 25/10/2026

### Cập nhật sau lần fit 07:58

Setup giảm xuống −0,479 ns, TNS −25,510 ns; hold +0,123 ns. Tài nguyên
27.560 ALM, 37.708 registers, 45 M10K, 28 DSP. Đã lưu riêng run
`A2_20261025_080219` trước sửa lại.

Đã bỏ thử nghiệm nhân bản reset toàn cục (132 bản sao), đăng ký bit chọn
hướng trước mux khóa GCM và tách điều khiển đồng bộ từ UART vào core.
Các cổng công khai vẫn giữ mask reset; trạng thái parser được reset ngay
cạnh đầu để ngăn lệnh cũ khi nhả reset một chu kỳ.

Nguồn sau sửa: run `20261025_080618_406`. Chi tiết:
`09_reports/architecture_tracking/A2_AFTER_0758_FIX_20261025.md`.
Seed vẫn **2**, không đổi SDC. Cần **Full Compilation** mới để xác nhận
timing/tài nguyên. Các số bên dưới là lịch sử trước lần sửa này.

26.699 ALM, 37.781 registers, 45 M10K, 28 DSP. Setup WNS −0,081 ns,
TNS −0,322 ns; hold WNS nhỏ nhất +0,110 ns. Run `A2_20261025_070821` đã
lưu trong Excel và `09_reports/architecture_tracking/` trước sửa tiếp.

Đường âm còn lại bắt đầu từ reset_sync_n (4.731 tải). RTL đã giới hạn
fanout tại FF reset nguồn và tách cổng đọc RAM GCM nội bộ đã xác thực cho
KDF; cổng công khai vẫn giữ che đầu ra ngay khi reset/start/zeroize. Không
thêm chu kỳ xử lý. Seed 2, macro, SDC, NTT và RNG giữ nguyên.

Regression: `09_reports/continuous_banked/run_20261025_072151_908/`.
Chi tiết: `09_reports/architecture_tracking/A2_AFTER_0704_FIX_20261025.md`.
Analysis & Elaboration: 0 errors / 3 warnings kế thừa. Cần **Full Compilation**
mới để xác nhận setup/hold và tài nguyên sau sửa; không coi regression là STA.

## Lịch sử trước đó: fit 05:42 ngày 25/10/2026

26.760 ALM, 37.818 registers, 45 M10K, 28 DSP. Setup min −0,059 ns, TNS
−0,282 ns (Slow 1100mV 85C); hold min +0,130 ns. Flow thành công, setup chưa đạt.
Bản chụp: `09_reports/architecture_tracking/A2_20261025_latest_before_consolidation/`.

## RTL vừa sửa, cần Full Compilation lại

- Keccak: đăng ký trọn điều kiện clear của ba thanh ghi transient 64 bit.
  Dự đoán FINISH cùng cạnh FSM, giữ lịch xóa cũ.
- Cổng đọc RAM hash nội bộ: đăng ký visibility để cắt đường reset toàn cục
  vào hash_output_q. Cổng công khai vẫn che kết quả ngay khi clear.
- Record UART: tính ranh giới tag tại VALIDATE, đăng ký phân loại payload/tag
  trong LOAD_REQ và dùng tại LOAD_CAP. Không thay giao thức hay lịch xử lý.

Chỉ ba file A2 thay đổi. NTT, multiplier, RNG, macro, seed và SDC giữ nguyên.
Chưa có Fitter/STA của RTL sau sửa; không dùng slack trước sửa để kết luận bản mới.
Regression: `07_scripts/run_continuous_banked_a2_regression.ps1`.
Log: `09_reports/continuous_banked/run_20261025_060103_737/`.

## SOF và phiên bản cũ

Giữ hook `07_scripts/archive_a2_sof_before_flow.tcl` chuyển SOF cũ vào backup
trước compile. Ver2/ver3 và database cũ đã lưu ở
`backups/a2_a4_consolidate_20261025_0550/`; không còn QPF ver2/ver3 hoạt động.
