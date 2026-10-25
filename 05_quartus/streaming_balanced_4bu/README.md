# A5 — streaming_balanced_4bu, revision so sánh ngày 24/10/2026

## Mở và compile

Mở mlkem_streaming_balanced_4bu_de10.qpf trong thư mục này, chọn đúng revision cùng tên.
Top mlkem_channel_top; Cyclone V 5CSXFC6D6F31C6; clock lõi mục tiêu 160 MHz,
CLOCK_50 đầu vào 50 MHz; seed 4.
Chọn Processing > Start Compilation (Full Compilation).
Đợt chuẩn bị này KHÔNG chạy Quartus synthesis/fitter/STA.

## Kiến trúc

Kế thừa lịch service A4, chọn ntt_core_stream4: bốn butterfly radix-2 mỗi chu kỳ, tám bank 32 × 12 bit, một bản sao đa thức. Bank(i) = {XOR(i[7:2]), i[1:0]}, row(i) = i[7:3]. Phát 224 nhóm bốn butterfly qua bảy tầng, không drain giữa các tầng. Đọc ngoài có hai nhịp; service đã có prefetch tương ứng. Macro 4BU còn chọn các nhánh reset/pipeline của sponge, DRBG và record UART; không mô tả là chỉ thay riêng NTT.

NTT và INTT đo bằng testbench hiện tại: 235 chu kỳ. MultiplyNTTs: 143 chu kỳ.
Các chu kỳ mô phỏng không phải Fmax hay kết quả timing sau fit.

## Cấu hình và cách ly nguồn

- 36 file SYSTEMVERILOG_FILE đều nằm trong
  01_rtl/architectures/streaming_balanced_4bu/rtl; không đọc RTL của kiến trúc khác.
- SDC riêng: 01_rtl/architectures/streaming_balanced_4bu/constraints/mlkem_channel_160.sdc.
  Giữ nguyên ràng buộc, không thêm false path để che lỗi timing.
- Tắt CONTINUOUS_BANKED_BOARD_DEMO: revision so sánh dùng lệnh UART chọn mode,
  không dùng SW0 chọn mode demo tự chạy. KHÔNG nạp nhầm bản này để quay demo cũ.
- Giữ nguyên các macro kiến trúc còn lại, chân I/O, seed, tùy chọn tối ưu.
  Chỉ bỏ khai báo QSF lặp nguyên dòng và macro BOARD_DEMO.
- Giữ REMOVE_REDUNDANT_LOGIC_CELLS=OFF theo cấu hình RO có sẵn.
  Cần kiểm tra RO/u_trng và synchronizer sau fit, rồi thử nguồn entropy trên kit.
  Mô phỏng không chứng minh entropy hay chứng nhận TRNG.
- RTL và SDC không bị sửa trong lần chuẩn bị này.
- Project keydemo, ASIC, A0/A1/A2 và các revision ver2/ver3 không bị đổi cấu hình.
- Seed A3=2, A4/A5=4: không gọi đây là phép thử cùng seed.
  A0/A1 dùng REMOVE_REDUNDANT_LOGIC_CELLS=ON, A2–A5 dùng OFF.
  Khi viết báo cáo phải nêu khác biệt; nếu cần so sánh thuần thuật toán,
  dùng số chu kỳ cùng fixture hoặc bổ sung thí nghiệm kiểm soát seed/tùy chọn.

## Kiểm thử

Chạy từ thư mục gốc:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File 07_scripts/run_architecture_comparison_regression.ps1 -Architecture A5
```

Runner đọc file list/macro từ QSF; chỉ bỏ SYNTHESIS cho mô phỏng chức năng.
Nhánh PLL SYNTHESIS được kiểm tra riêng với model vendor tại 100/110/150/160 MHz.
Work/vector/model/log riêng theo run; inputs.json ghi SHA-256 đầu vào.
17 testbench RTL + 4 PLL vendor + 2 kiểm thử host phần mềm + 1 test âm sampler.
Test âm yêu cầu assertion bắt đúng thao tác ghi sampler khi busy; không coi đây
là chế độ hoạt động hợp lệ hoặc khả năng chặn ghi của phần cứng tổng hợp.

Guard NTT: 104 transforms đối chiếu toán độc lập, 12 multiply, 8 tích chập
schoolbook, 12 lần reset-abort; kiểm tra truy cập bank, đủ hệ số mỗi tầng,
thứ tự commit và không đọc phiên bản dữ liệu cũ qua ranh giới tầng.
Python ACVP 50 KeyGen / 50 Encaps / 20 Decaps kiểm tra mô hình tham chiếu,
KHÔNG phải chứng nhận ACVP cho RTL.

Run chuẩn bị: 09_reports/streaming_balanced_4bu/run_20261024_012050_666.
Kết quả run trên: PASS 17/17 testbench RTL, 4 PLL vendor, 2 host,
1 negative-contract test; INPUTS_UNCHANGED. Xem summary.txt và từng log.
Quartus Shell đã mở và xác minh đúng project, nguồn, SDC, top/device/seed;
0 errors, 0 warnings trong kiểm tra mở project, KHÔNG phải Full Compilation.
inputs.json cùng thư mục định danh chính xác bộ nguồn đã mô phỏng.

## Sao lưu và kết quả cần lấy sau compile

Bản trước sửa: backups/a3_a4_a5_prepare_20261024_011912/streaming_balanced_4bu.
Gồm QSF/QPF/README có sẵn và report/SOF cũ. Không xóa database hay SOF cũ,
nhưng chúng KHÔNG phải bằng chứng của cấu hình mới cho đến khi compile lại.

Sau Full Compilation cần đọc flow/map/fit/sta reports: ALM, registers,
block-memory bits và số M10K, DSP, PLL, thời gian compile, warning đáng chú ý;
setup/hold/TNS/minimum-pulse-width ở đủ bốn corner và các đường chưa ràng buộc.
Chỉ kết luận timing đạt khi kiểm tra đầy đủ; tên V2_TIMING_FIX không bảo đảm WNS dương.
Số liệu PPA/STA của lần compile mới hiện còn chờ, không lấy số cũ thay vào.

## Chu kỳ service đo ở run chuẩn bị

| Mode | KeyGen | Encaps | Decaps hợp lệ |
|---|---:|---:|---:|
| ML-KEM-768 | 70885 | 94364 | 130510 |
| ML-KEM-1024 | 112617 | 141525 | 187731 |

Dùng cùng vector cố định và mô hình tham chiếu với các bản so sánh; A3/A4/A5
đã đối chiếu hash vector giống nhau. Đây là chu kỳ RTL của service core,
không gồm UART và không phải latency đo trên kit với seed ngẫu nhiên.
Không dùng các con số này để tuyên bố đã đạt timing 160 MHz sau fit.

