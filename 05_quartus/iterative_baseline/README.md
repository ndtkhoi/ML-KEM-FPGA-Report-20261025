# A0 — ML-KEM-768/1024 Iterative In-Place Baseline

## Phạm vi kiến trúc

Baseline dùng để so sánh quá trình phát triển lên kiến trúc streaming/4BU,
không phải tuyên bố một vi kiến trúc bắt buộc của FIPS 203.

- NTT/INTT: một butterfly được phát tại một thời điểm, một RAM hai cổng
  256 × 12 bit in-place và một bộ nhân modular dùng chung.
- Butterfly tiếp theo chỉ được phát sau khi butterfly trước đã ghi kết quả.
  Bộ nhân có pipeline, nhưng lịch NTT không khai thác initiation interval = 1.
- INTT thực hiện một lượt chuẩn hóa tuần tự sau cùng.
- MultiplyNTTs: xử lý từng cặp hệ số; bên trong vẫn có năm instance
  `mod_mul_pipe` và ba RAM. Không gọi toàn bộ ML-KEM là “chỉ một bộ nhân”.
- Giữ đầy đủ KeyGen/Encaps/Decaps cho hai chế độ, UART, RNG và AES-GCM.
- Top `mlkem_channel_top`; FPGA `5CSXFC6D6F31C6`; clock mục tiêu 160 MHz.
- QSF chọn 33 file trong `01_rtl/architectures/iterative_baseline/rtl`.
  Constraints riêng nằm trong `01_rtl/architectures/iterative_baseline/constraints`.
- Macro QSF: `SYNTHESIS`, `ITERATIVE_BASELINE_TIMING_FIX`.
  Mô phỏng bỏ `SYNTHESIS` để dùng mô hình clock/entropy, giữ macro timing fix.

ALM/register/RAM/DSP của project này tính cho TOÀN HỆ THỐNG, không chỉ NTT.
So sánh với kiến trúc khác phải giữ cùng phạm vi, thiết bị, bộ vector và điều
kiện compile. Không quy mọi cải thiện cho 4BU nếu Keccak/MultiplyNTTs/control
cũng thay đổi. Báo cáo chu kỳ và thời gian riêng; thời gian = chu kỳ / clock
đã được timing xác nhận. Không tính thời gian UART là latency thuần của core.

## Chạy kiểm thử chức năng

Từ PowerShell, có thể chạy ở bất kỳ thư mục nào:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:/ML_KEM_768_1024/07_scripts/run_iterative_baseline_regression.ps1
```

Script KHÔNG chạy Quartus Compilation, KHÔNG nạp kit và KHÔNG sửa RTL.

- Đọc danh sách RTL từ QSF; từ chối nguồn ngoài thư mục baseline, file thiếu,
  macro không đúng hoặc danh sách không còn 33 file độc lập.
- ModelSim work, model Python và vector riêng của từng lần chạy:
  `04_sim/iterative_baseline/run_<timestamp>`.
- Log, summary, bản sao QSF/SDC và SHA-256 đầu vào:
  `09_reports/iterative_baseline/run_<timestamp>`.
- File `summary.txt` ở thư mục cha là kết quả lịch sử, KHÔNG phải lần chạy mới.
- `inputs.json` ghi nguồn, testbench, vector, macro và phạm vi kiểm thử.
  Chỉ PASS cuối cùng nếu đầu vào không đổi trong lúc chạy.
- Test clear riêng: `02_tb/architectures/iterative_baseline/tb_keccak_sponge_clear.sv`.
  Test chung của các kiến trúc khác không bị sửa. Kiểm tra đủ 15 trạng thái,
  hai pha permutation, nhiều block, ưu tiên clear và digest sau khởi động lại.
- Scratch RAM của sponge được vô hiệu hóa đầu ra khi clear, KHÔNG được scrub
  toàn bộ nội dung vật lý. Không mô tả bài kiểm thử này là bằng chứng xóa mọi RAM.

`validate_mlkem_acvp.py` đối chiếu mô hình Python với các vector ACVP có sẵn.
RTL service core được kiểm tra với vector mô hình, cả hai chế độ, implicit
rejection, đầu vào không hợp lệ và vòng đời khóa. Đây KHÔNG phải tuyên bố RTL
đã trực tiếp chạy toàn bộ ACVP, hay sản phẩm được NIST chứng nhận.

## Full Compilation — người dùng tự chạy

1. Đợi regression có dòng `ITERATIVE_BASELINE_REGRESSION: PASS`.
2. Mở `D:/ML_KEM_768_1024/05_quartus/iterative_baseline/mlkem_iterative_baseline_de10.qpf`.
3. Xác nhận revision `mlkem_iterative_baseline_de10`, top `mlkem_channel_top`.
4. Chọn **Processing → Start Compilation** và đợi cả Timing Analyzer hoàn tất.
5. Gửi thư mục `output_files`, đặc biệt `.fit.summary`, `.sta.summary`,
   `.sta.rpt`, `.flow.rpt` để đối chiếu với bộ nguồn đã kiểm thử.

Không chỉ dựa vào chữ “Successful” của Fitter: phải kiểm tra setup/hold ở mọi
corner, minimum pulse width và các đường chưa được ràng buộc. Không thêm false
path chỉ để loại bỏ vi phạm. Constraints hiện tại chưa được coi là signoff
chỉ vì đã chạy mô phỏng. Bản SOF cũ không đại diện cho lần kiểm thử nguồn mới.

## Kết quả lịch sử — không thay thế lần compile mới

Các log cũ ghi NTT 9.984 chu kỳ, INTT 12.800 chu kỳ, MultiplyNTTs 2.433 chu kỳ.
Đây là số đo theo định nghĩa bộ đếm trong testbench, không gồm truyền UART.

Báo cáo Fitter ngày 10/09/2026 đang lưu: 24.216 ALM, 35.294 register,
238.768 block-memory bit, 43 RAM block, 28 DSP. Setup slack thấp nhất
**−0,006 ns**, hold slack thấp nhất **+0,120 ns**: chưa đóng setup 160 MHz.
Con số +0,183 ns / 23.720 ALM trong README trước thuộc lần compile cũ hơn,
không được dùng thay cho báo cáo mới hơn.

Regression lịch sử `20260910_123443_378` dừng ở lỗi tham chiếu tín hiệu nội bộ
của `tb_keccak_sponge_clear`. Đã tách test tương ứng baseline; trạng thái mới
phải đọc tại thư mục `run_<timestamp>`, không suy từ các bài PASS riêng lẻ.

## Lần kiểm thử đã hoàn tất ngày 23/10/2026

Run `20261023_233228_764`: **14/14 testbench PASS, INPUTS_UNCHANGED**.
Keccak clear PASS 72 tình huống. Python ACVP PASS 50 KeyGen, 50 Encaps,
20 Decaps (phạm vi mô hình Python như đã nêu trên).

| Chế độ | KeyGen (chu kỳ) | Encaps (chu kỳ) | Decaps hợp lệ (chu kỳ) |
|---|---:|---:|---:|
| ML-KEM-768 | 207.580 | 263.538 | 362.654 |
| ML-KEM-1024 | 319.198 | 386.366 | 512.312 |

Số liệu ứng với vector cố định của regression, không phải trung bình nhiều
lần demo ngẫu nhiên. RTL tổng hợp và constraints không thay đổi trong đợt sửa
testbench này. **Chưa chạy lại Quartus; chưa xác nhận đóng timing 160 MHz.**

Log: `09_reports/iterative_baseline/run_20261023_233228_764/summary.txt`.
Nguồn và SHA-256: `09_reports/iterative_baseline/run_20261023_233228_764/inputs.json`.
