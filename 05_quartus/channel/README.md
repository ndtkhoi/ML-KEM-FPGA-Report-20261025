# A1 — ML-KEM-768/1024 Streaming Ping-Pong

## Cập nhật 06:36 ngày 24/10 — Fitter xong, Assembler lỗi file

Fit RTL đã sửa: 24.882 ALM (+140), 36.341 registers (+99), 44 M10K / 28 DSP không đổi.
Assembler lỗi 210006: không mở/ghi được SOF. File `.sta.rpt` 00:44 trong
output_files là báo cáo cũ. Đã sao lưu và chuyển SOF cũ ra khỏi output_files,
kiểm tra thư mục ghi được. Không sửa thêm RTL cho lỗi truy cập file này.
Mở project, chạy lại Assembler rồi Timing Analysis, hoặc Start Compilation.
Đọc lại database fit mới: setup min +0,075 ns, hold min +0,110 ns qua 4 corners;
min pulse +1,562 ns. Đây là STA riêng, chưa có SOF mới sau lỗi Assembler.
Xem `../../09_reports/architecture_tracking/A1_ASSEMBLER_REPAIR_20261024.md`.

Phần dưới là lịch sử sửa RTL và kết quả trước lần fit 06:35.

## Bản sửa timing ngày 24/10/2026 — CHỜ FULL COMPILATION

Mốc trước sửa: fit 24/10/2026 00:41:23, 24.742 ALM, 36.242 register,
241.840 bit bộ nhớ, 44 RAM block, 28 DSP, 1 PLL. Setup thấp nhất -0,430 ns
(slow 85°C), -0,089 ns (slow 0°C); hold thấp nhất +0,128 ns.
Các report hiện có trong output_files vẫn là kết quả TRƯỚC sửa.

Đọc database post-fit xác nhận đường -0,430 ns:
clear_kdf_q -> logic dùng chung reset/clear (fanout 853) -> datapath_clear_q.
89% data delay của đường này là interconnect. Các nhánh clear tới Keccak
round_mid và material cũng âm; một đường codec ghi M10K âm -0,041 ns.
Report chi tiết: 09_reports/streaming_pingpong/timing_before_20261024.

Sửa giới hạn ở bốn file RTL riêng của A1:

- channel_session: giữ token clear/reset có sẵn, giảm maxfan clear_kdf_q 32→16.
- channel_kdf: thêm parameter RESET_VIA_ZEROIZE, mặc định 0 cho người dùng
  độc lập; session chọn 1 vì clear_kdf_q đã chứa reset. Bỏ phép ghép reset
  toàn cục với clear ở KDF/sponge trong cấu hình này. Không thêm một tầng
  clear hoạt động; kem_clear vẫn vô hiệu session ở cạnh 2, xóa KDF ở cạnh 3,
  xóa sponge/permutation ở cạnh 4. Reset phần cứng đi qua token riêng:
  session vô hiệu ở cạnh 1, KDF xóa ở cạnh 2, sponge xóa ở cạnh 3.
- keccak_sponge: maxfan datapath_clear_q 64→32, thêm dont_merge để giữ
  ranh giới clear cục bộ; không bỏ chức năng xóa trạng thái nhạy cảm.
- byte_codec_core: nhánh d=12 dùng bit mượn của phép trừ 13 bit để chọn
  raw hoặc raw−3329, bỏ chuỗi mask/comparator/subtractor nối tiếp.
  Các độ rộng còn lại giữ nguyên; không thêm thanh ghi hay trạng thái codec.

Không sửa QSF, SDC, seed=2, clock=160 MHz, NTT ping-pong, số BU, RAM, DSP
hay lịch FSM ML-KEM. Không bật macro A0/banked/4BU; không thêm false path.
Fanout replication có thể tăng một lượng nhỏ FF/ALM và ảnh hưởng placement;
chỉ fit mới xác nhận được mức tăng, không cam kết tài nguyên giữ nguyên.
Ưu tiên giữ RAM/DSP không đổi và so sánh ALM/FF với đúng mốc trên.

Đã sao lưu toàn bộ nguồn A1, constraints, QSF/QPF, report/SOF và runner trước
sửa tại backups/a1_timing_fix_20261024_014320. Các kiến trúc khác không sửa.
Manifest tách nguồn ban đầu giữ làm lịch sử; hash hiện hành nằm trong inputs.json
của mỗi regression. Runner hiện có 18 testbench (thêm codec exhaustive 24.576
trường hợp), 4 PLL vendor và 2 host; guard channel bổ sung reset một chu kỳ
giữa KDF/AES, kiểm tra xóa dữ liệu và khởi động lại.

Chưa được kết luận timing đạt chỉ từ mô phỏng. Cần Full Compilation rồi đọc
setup/hold/TNS/pulse width đủ bốn corner và tài nguyên mới. Không thay số
liệu cũ trong bảng báo cáo bằng số ước đoán.

## Định nghĩa mốc so sánh

- Project: `mlkem_channel_de10.qpf`; revision `mlkem_channel_de10`.
- Top: `mlkem_channel_top`; Cyclone V `5CSXFC6D6F31C6`; mục tiêu 160 MHz.
- QSF chọn 33 file riêng trong `01_rtl/architectures/streaming_pingpong/rtl`.
- SDC riêng: `01_rtl/architectures/streaming_pingpong/constraints/mlkem_channel_160.sdc`.
- QSF chỉ bật macro `SYNTHESIS`; không bật macro A0 timing fix, banked hay 4BU.

NTT/INTT dùng một BU có pipeline và hai RAM 256 × 12 bit ping-pong. Trong mỗi
tầng, phát một butterfly mỗi chu kỳ (II=1); đọc hai hệ số từ RAM nguồn và ghi
hai kết quả vào RAM đích. Chỉ đổi vai trò hai RAM sau khi đủ 128 butterfly
đã ghi xong. Vẫn có thời gian chờ pipeline ở ranh giới các tầng; không gọi đây
là kiến trúc chồng lấp liên tục giữa các tầng.

INTT chia modular cho 2 tại mỗi tầng, tương đương hệ số chuẩn hóa 1/128 sau
bảy tầng. MultiplyNTTs phát một cặp hệ số mỗi chu kỳ, với năm bộ nhân modular
pipeline dùng cho tích thành phần/gamma và RAM kết quả riêng.

So với A0, thay đổi không chỉ ở RAM NTT: còn gồm lịch phát/ghi pipeline,
chuẩn hóa INTT và pipeline MultiplyNTTs. Không quy toàn bộ mức tăng tốc cho
riêng ping-pong. Các chỉ tiêu tài nguyên của project tính cả ML-KEM, RNG,
UART, AES-GCM và giao diện kit, không chỉ một lõi NTT.

Đối chiếu 33 file của hai snapshot ngày 23/10/2026: chỉ `ntt/ntt_core.sv`
và `ntt/multiply_ntts_core.sv` khác nội dung giữa A0 và A1. Tuy nhiên A0 bật
thêm `ITERATIVE_BASELINE_TIMING_FIX` trong QSF, nên không gọi hai cấu hình
tổng hợp là giống hoàn toàn ngoài hai file này. Macro đó điều chỉnh register
`hash_output_q` trong service core; phải ghi nhận trong điều kiện so sánh.

## Kiểm thử trước khi compile

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:/ML_KEM_768_1024/07_scripts/run_streaming_pingpong_regression.ps1
```

Hai tên script cũ `run_channel_160_regression.ps1` và `run_channel_regression.ps1`
chuyển sang cùng runner đầy đủ. Không chạy đồng thời cả ba vì chúng làm cùng việc.

Runner không chạy Quartus, không nạp kit và không sửa RTL. Mỗi run có vector,
model Python và work riêng; không ghi đè vector/log của A0 hoặc các demo khác.
Log/summary nằm trong `09_reports/streaming_pingpong/run_<timestamp>`.
`inputs.json` ghi SHA-256 nguồn, constraints, testbench và vector. PASS cuối
cùng yêu cầu các đầu vào được theo dõi không thay đổi trong khi kiểm thử.

Phạm vi kiểm tra:

- 17 testbench RTL: số học, codec/sampler, clock/UART, NTT/INTT, MultiplyNTTs,
  Keccak/SHA3/SHAKE, RNG, ML-KEM hai chế độ, AES-GCM và hệ thống channel.
- `tb_ntt_stream`: oracle toán độc lập, tích chập negacyclic, thứ tự tag,
  II=1 trong tầng, đủ 256 hệ số mỗi tầng, không ghi RAM nguồn, reset giữa chừng.
- Test clear Keccak riêng cho A1, giữ đủ 15 trạng thái và 72 tình huống.
  Scratch RAM sponge bị vô hiệu hóa đầu ra chứ không scrub vật lý toàn bộ.
- `tb_opt100_memory_guards`, `tb_channel_pipeline_guards`: đầu ra chưa xác
  thực, ưu tiên clear, xóa trạng thái nhạy cảm và chống kết quả cũ xuất hiện lại.
  Test pipeline riêng cho A1 kiểm tra xung `kem_clear` dài một chu kỳ: tính từ
  cạnh lấy mẫu đầu tiên, phiên/đầu ra vô hiệu ở cạnh 2, KDF/AES xóa ở cạnh 3,
  sponge/permutation xóa ở cạnh 4; RAM GCM được kiểm tra sau lượt scrub tuần tự.
  Đây là clear đồng bộ có độ trễ xác định, KHÔNG phải chặn đầu ra tức thời
  theo cạnh bất đồng bộ của `kem_clear`. Test chung cũ giả định một cạnh clock
  không phù hợp với các thanh ghi clear của snapshot này; không sửa test chung.
- Mô hình PLL vendor tại 100/110/150/160 MHz lấy RTL clock/UART từ A1, không
  lấy nguồn dùng chung. Kiểm tra mô hình PLL không thay thế STA sau fit.
- Hai bài host bằng phần mềm; không phải kiểm chứng trên kit.
- Đối chiếu Python với vector ACVP; không tuyên bố RTL được NIST chứng nhận
  hoặc trực tiếp đã chạy toàn bộ vector ACVP.

## Người dùng tự Full Compilation

1. Đợi regression đầy đủ PASS; nếu A0 còn compile thì đợi A0 xong trước để
   tránh hai Fitter tranh CPU/RAM.
2. Mở `D:/ML_KEM_768_1024/05_quartus/channel/mlkem_channel_de10.qpf`.
3. Xác nhận revision `mlkem_channel_de10`, chọn **Processing → Start Compilation**.
4. Đợi Timing Analyzer hoàn tất; gửi `output_files`, đặc biệt `.fit.summary`,
   `.sta.summary`, `.sta.rpt`, `.flow.rpt`.

Chỉ chốt hiệu năng sau kiểm tra setup/hold mọi corner, pulse width và các
đường chưa ràng buộc. Không thêm false path để che vi phạm. Chu kỳ mô phỏng
phải đo bằng cùng vector và cùng ranh giới đếm như A0; không trộn thời gian UART.

## Báo cáo lịch sử đang lưu

Fitter ngày 07/09/2026: 24.114 ALM, 35.202 register, 241.840 block-memory bit,
44 RAM block, 28 DSP. Setup slack thấp nhất +0,054 ns, hold thấp nhất +0,143 ns.
Đây là dữ liệu lịch sử, không thay cho lần compile mới của bộ nguồn đã chốt.
Đợt sửa regression không thay đổi RTL, QSF hoặc SDC; chưa chạy lại Quartus.

## Kết quả kiểm thử A1 ngày 23/10/2026

Run `20261023_235246_460`: **17/17 testbench RTL PASS**, bốn cấu hình PLL
vendor PASS, hai bài host phần mềm PASS, `INPUTS_UNCHANGED`.
Log: `09_reports/streaming_pingpong/run_20261023_235246_460/summary.txt`;
nguồn/vector/macro và SHA-256: `inputs.json` trong cùng thư mục.

| Phép toán | Chu kỳ |
|---|---:|
| NTT | 981 |
| INTT | 981 |
| MultiplyNTTs | 145 |
| ML-KEM-768 KeyGen | 132.970 |
| ML-KEM-768 Encaps | 161.797 |
| ML-KEM-768 Decaps hợp lệ | 215.221 |
| ML-KEM-1024 KeyGen | 210.566 |
| ML-KEM-1024 Encaps | 245.499 |
| ML-KEM-1024 Decaps hợp lệ | 314.462 |

Đây là kết quả với vector cố định, không gồm truyền UART và không phải số
trung bình qua nhiều lần demo ngẫu nhiên. NTT stream PASS 104 transforms,
12 multiply runs, 8 tích chập schoolbook, 12 reset-aborts và 738 tầng hoàn tất.
Keccak clear PASS 72 tình huống. Không suy ra chứng nhận bảo mật hoặc timing
sau fit từ mô phỏng chức năng. Người dùng vẫn cần Full Compilation mới.

Run trước `20261023_234544_148` được giữ nguyên trạng thái FAILED để truy vết
lỗi test clear phiên cũ. `guard_recheck.log` chỉ là kiểm tra cục bộ sau sửa,
không thay thế run đầy đủ PASS nêu trên.
