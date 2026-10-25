# Nâng cấp: ML-KEM + khóa phiên + AES-256-GCM

## 1. Bản này làm được gì?

KeyGen, Encaps, Decaps vẫn được gọi riêng. Sau Encaps hoặc Decaps thành công,
khóa dùng chung đi trong FPGA sang khối HKDF để tạo hai khóa truyền dữ liệu.
AES-256-GCM mã hóa thông điệp và kiểm tra tag; bộ đếm số thứ tự từ chối gói phát lại.
Không xuất khóa bí mật, shared secret thô hay khóa AES qua UART.

Đây là **demo phần cứng với giao diện điều khiển UART tin cậy**, chưa phải TLS
hay một giao thức xác thực danh tính. Lệnh P đưa plaintext thử nghiệm từ PC vào
FPGA nên phần đầu vào P đó vẫn nhìn thấy trên dây UART. Lệnh U nhận ciphertext,
chỉ báo độ dài và SHA3 của plaintext sau khi tag đúng; không trả plaintext qua UART.
Không mô tả toàn bộ cổng UART này là một đường truyền đã được mã hóa từ đầu đến cuối.

Mỗi gói chứa 0–256 byte. Có thể chia dữ liệu dài thành nhiều gói, nhưng bản này
chưa triển khai truyền file, chia/gộp gói tự động hay xác thực bên giao tiếp.

## 2. Mở đúng project hiện tại

- **Project duy nhất: `D:\ML_KEM_768_1024\05_quartus\channel\mlkem_channel_de10.qpf`.**
- Top-level: `mlkem_channel_top`.

QSF đã khai báo toàn bộ file cần thiết; không thêm top-level khác vào project.
FPGA chỉ nạp một SOF tại một thời điểm.

Các file mới quan trọng:

| File | Công việc |
|---|---|
| [aes256_block.sv](D:/ML_KEM_768_1024/01_rtl/aead/aes256_block.sv) | AES-256, chia vòng xử lý thành các bước |
| [ghash_mul.sv](D:/ML_KEM_768_1024/01_rtl/aead/ghash_mul.sv) | Nhân GF(2^128) cho xác thực GCM |
| [aes_gcm_core.sv](D:/ML_KEM_768_1024/01_rtl/aead/aes_gcm_core.sv) | CTR, GHASH, tag 128 bit, chặn plaintext chưa xác thực |
| [channel_kdf.sv](D:/ML_KEM_768_1024/01_rtl/aead/channel_kdf.sv) | HKDF-HMAC-SHA3-256 và băm thông điệp nhận |
| [channel_session.sv](D:/ML_KEM_768_1024/01_rtl/aead/channel_session.sv) | Khóa hai chiều, epoch, số thứ tự và chống replay |
| [channel_kem_uart.sv](D:/ML_KEM_768_1024/01_rtl/uart/channel_kem_uart.sv) | K/E/D/Z như cũ, thêm đường khóa nội bộ sang session |
| [channel_record_uart.sv](D:/ML_KEM_768_1024/01_rtl/uart/channel_record_uart.sv) | Lệnh S/P/U và các số liệu minh chứng |
| [mlkem_channel_top.sv](D:/ML_KEM_768_1024/01_rtl/top/mlkem_channel_top.sv) | Ghép UART, ML-KEM, TRNG, AES-GCM, LED/HEX |

## 3. Build và nạp kit

### Cập nhật mục tiêu 150 MHz (05/09/2026)

**Nguồn hiện tại là kiến trúc streaming mới và đã Full Compilation thành công.**
NTT/INTT còn 981 chu kỳ, MultiplyNTTs còn 145; regression đầy đủ và
Quartus synthesis đã PASS. Chu kỳ KeyGen/Encaps/Decaps mới là
132970/161797/215221 (768) và 210566/245499/314462 (1024).
PLL vẫn 150 MHz, UART/pin không đổi. Full STA đạt cả bốn corner: setup thấp
nhất +0,234 ns, hold +0,124 ns, recovery +0,324 ns và removal +0,180 ns;
TNS bằng 0. SOF khớp nguồn mới tạo lúc **14:26:00 ngày 05/09/2026**.
Chưa nạp kit; giữ bước này cho quy trình demo/đo có ghi nhận rõ ràng.
Xem [bản nghiên cứu kiến trúc và số đo](D:/ML_KEM_768_1024/09_reports/channel/ARCHITECTURE_STREAMING_150MHZ.md).

Project `channel` hiện dùng CLOCK_50 (50 MHz) → PLL → `clk_sys` (**150 MHz**).
Tần số mặc định nằm ở `CORE_CLOCK_MHZ=150` trong `mlkem_channel_top.sv`.
Tên file/module `clock_100` được giữ để tương thích; tham số `OUTPUT_MHZ`
mới quyết định tần số thật. Wrapper hỗ trợ 100, 110 và 150 MHz.
Tất cả logic đồng bộ, kể cả UART, dùng `clk_sys`.
UART vẫn 115200-8N1, nay **1.302 clock/bit**, không đổi dây hoặc baud của PC.
Timeout nhận vẫn 2 giây, đợi RNG vẫn 3 giây. TRNG dùng SAMPLE_DIV=48,
tương ứng 320 ns/mẫu. Vẫn phải đánh giá entropy trên kit sau thay đổi
clock/bố trí; mô phỏng không xác nhận entropy vật lý.

Các thay đổi chính của lần này:
- Keccak: tách theta/rho/pi và chi/iota thành hai pha, 48 clock/permutation.
- Sponge: đệm lane 64 bit và dịch ra byte, thay mux 200 byte vào RAM.
- NTT và phép cộng/trừ đa thức: bắt dữ liệu RAM vào thanh ghi trước khi tính.
- ML-KEM: pipeline nạp/đọc hash; dịch byte cố định vào thanh ghi khóa/hash;
  chọn khóa decapsulation bằng quyết định đã đăng ký, cùng độ trễ cho bản mã
  đúng và sai.
- UART: pipeline metadata, vị trí byte và dữ liệu; tách cờ kết thúc dòng khỏi
  bộ định dạng. Khoảng GAP dài hơn để RAM và các tầng đệm ổn định.
- KDF/session: đệm byte trước khi nạp sponge và phân phối xóa khóa qua
  thanh ghi cục bộ; khóa đọc đầu ra ngay khi yêu cầu hủy phiên.
- Quartus: Standard Fit và router timing Maximum. Build có thể lâu hơn Auto Fit;
  không bảo đảm kết quả tốt hơn cho mọi placement.

**150 MHz lần 4 đã được xác nhận timing sau Fitter; chưa thử trên kit.**
Không dùng SOF/report của lần 3 hoặc bản 110 MHz làm minh chứng cho nguồn hiện tại.
Chi tiết: [OPTIMIZATION_150MHZ.md](../../09_reports/channel/OPTIMIZATION_150MHZ.md).

1. Quartus Prime 18.1 Lite → File → Open Project → chọn QPF **channel** ở trên.
2. Processing → Start Compilation.
3. Kiểm tra Flow Summary, Fitter Summary và Multicorner Timing Analysis Summary.
   Không dùng lại số ALM hoặc slack của bản trước. Slack âm cần được sửa trước khi
   kết luận bản mới đạt 150 MHz; không tăng giả chu kỳ SDC để che lỗi timing.
   Trong Timing Analyzer → Clocks phải có clock gốc 20 ns và clock xử lý PLL khoảng 6,667 ns.
   Fitter phải sử dụng PLL. QSF đã thêm `clock_100.sv`, `compress_seq.sv` và SDC mới
   `06_constraints/mlkem_channel_150.sdc` (clock thật được suy ra từ PLL);
   không cần tạo PLL thủ công trong GUI. Không sửa clock đầu vào 50 MHz thành 150 MHz.
4. Khi bản mới compile và timing đạt, nạp SOF:

```powershell
cd D:\ML_KEM_768_1024\05_quartus\channel
& "D:\QUARTUS\quartus\bin64\quartus_pgm.exe" `
  -c "DE-SoC [USB-1]" -m JTAG `
  -o "s;SOCVHPS@1" `
  -o "p;output_files\mlkem_channel_de10.sof@2"
```

Nếu compile thành công nhưng slack còn âm, chưa dùng SOF đó để kết luận đạt
150 MHz. Gửi Flow Summary và Multicorner Timing Analysis Summary. Có thể xuất
chi tiết đường chậm từ **netlist vừa build** bằng lệnh sau, không chạy lại Fitter:

```powershell
cd D:\ML_KEM_768_1024
& "D:\QUARTUS\quartus\bin64\quartus_sta.exe" -t .\07_scripts\report_channel_paths_detailed.tcl
```

Báo cáo nằm ở `09_reports/channel/timing_paths_YYYYMMDD_HHMMSS/`. Chỉ chạy lệnh này sau khi
Fitter mới đã hoàn tất; không đọc netlist cũ với cấu hình mới rồi coi
đó là timing của RTL mới.

Muốn chạy lại toàn bộ kiểm thử chức năng của đợt tối ưu (không build Quartus):

```powershell
cd D:\ML_KEM_768_1024
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_channel_150_regression.ps1
```

Chỉ chạy một bản script tại một thời điểm. Kết quả ở
`09_reports/channel/150mhz/summary.txt` cùng các log kiểm thử. Script cũng kiểm tra
model PLL 100/110/150 MHz để tránh cấu hình sai. Các bài tích hợp
ở `09_reports/channel/`. PASS mô phỏng không thay thế timing sau Fitter hoặc
kiểm tra TRNG và UART trên kit thật.

Chuỗi HPS@1/FPGA@2 là thứ tự đã dùng trên kit này; nếu Auto Detect cho thứ tự
khác thì theo chuỗi thực tế. ML-KEM và AES vẫn hoàn toàn chạy bằng RTL, không dùng HPS.

Giữ dây UART như bản trước: JP1 chân 1 TX → RXD adapter; JP1 chân 2 RX ← TXD;
GND chung JP1 chân 12 hoặc 30. Tín hiệu logic 3,3 V; không nối chân nguồn
3V3/+5V của adapter vào kit. Baud 115200, 8 data bits, no parity, 1 stop bit.

## 4. Chạy demo

Đóng PuTTY để giải phóng COM. Sau khi nạp, nhấn/thả KEY0 để reset, đưa SW về 0.
Thử PC-seeded trước để tách kiểm tra đường dữ liệu khỏi đánh giá TRNG vật lý:

```powershell
cd D:\ML_KEM_768_1024
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\10_demo\uart\mlkem_channel.ps1 `
  -ComPort COM5 -Mode 768 -RandomSource PC
```

Sau đó thử nguồn FPGA:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\10_demo\uart\mlkem_channel.ps1 `
  -ComPort COM5 -Mode 768 -RandomSource FPGA `
  -Message "Xin chao! Day la du lieu duoc FPGA xu ly."
```

Đổi `-Mode 768` thành `-Mode 1024` để thử bộ tham số còn lại. Đổi COM5 nếu Windows
cấp cổng khác. Thông điệp tối đa 256 byte UTF-8, không nhất thiết là 256 ký tự.

Script hiện đổi số chu kỳ sang ms theo **150 MHz** và ghi `configured_core_clock_hz`
vào evidence. Đây là tần số cấu hình, không phải phép đo clock trên dây UART.
Nếu vẫn dùng SOF 110 MHz, truyền `-CoreClockHz 110000000`; với SOF 100/50 MHz
dùng 100000000/50000000 tương ứng. Không dùng mặc định 150 MHz để báo thời gian
cho SOF cũ.

Lần tối ưu này tăng số chu kỳ vì thêm pipeline. Dựa trên chu kỳ kiểm thử
KeyGen/Encaps/Decaps ở hai chế độ, nếu đạt timing 150 MHz thì thời gian tính toán
dự kiến giảm khoảng 19–21% so với bản 110 MHz. Không phải tăng 36,36% hiệu năng
chỉ vì tăng clock. Baud UART giữ nguyên nên tổng thời gian demo không giảm
tương ứng; cần đo lại trên kit.

Script dùng Python và thư viện cryptography đã có trong bộ runtime của máy này;
không cần pyserial. Nếu chuyển sang máy khác, chuẩn bị Python có cryptography rồi
truyền `-PythonExe "C:\duong_dan\python.exe"`. Script không tự tải hay cài thêm gì.

Demo thay khóa/session đang giữ. Hai pha:

1. FPGA KeyGen → PC Encaps → FPGA Decaps. PC và FPGA dùng cùng khóa để truyền gói.
2. PC KeyGen → FPGA Encaps → PC Decaps. Đảo vai trò và kiểm tra hai chiều lần nữa.

Trong mỗi pha, script kiểm tra:

- Gói đúng được nhận, SHA3 của thông điệp giải mã trùng PC.
- Sửa một bit tag, tính lại CRC UART: FPGA trả A1, không xuất hash/plaintext.
  Việc tính lại CRC chứng tỏ GCM đã phát hiện sửa đổi, không chỉ bộ kiểm tra CRC.
- Gửi bản đúng của gói vừa thất bại vẫn được nhận: lỗi tag không làm tăng số thứ tự nhận.
- Gửi lại gói đã nhận: FPGA trả A2, bộ đếm replay tăng.
- FPGA mã hóa theo chiều ngược; PC giải mã bằng cryptography và đối chiếu thông điệp.
- Gửi thêm một gói đúng để kết thúc demo với trạng thái PASS trên kit.

Các dòng cần nhìn thấy, không phải kết quả kit đã được đo sẵn:

```text
PC_ENCRYPT_FPGA_VERIFY: PASS
TAMPER_TAG: REJECTED A1 (no plaintext released)
REPLAY: REJECTED A2
FPGA_ENCRYPT_PC_DECRYPT: PASS
MLKEM_CHANNEL_DEMO_768: PASS
```

Mỗi lần chạy lưu `evidence.json` trong thư mục mới dưới
`D:\ML_KEM_768_1024\09_reports\channel`. Có response, ciphertext, tag, fingerprint,
counter và chu kỳ; không lưu DK/K/khóa phiên hay seed thử nghiệm.

## 5. Kit hiển thị gì?

SW đều OFF: kết quả cuối hiển thị PASSxy hoặc FAILxx.

| Giá trị ở mode 768 | Ý nghĩa |
|---|---|
| PASS13 / PASS23 / PASS33 | KeyGen / Encaps / Decaps hoàn tất |
| PASS43 | Tạo khóa phiên hoàn tất |
| PASS53 | Mã hóa gói hoàn tất |
| PASS63 | Gói nhận đã qua kiểm tra tag và băm plaintext |
| FAILA1 | Tag sai, đã từ chối |
| FAILA2 | Sai số thứ tự/phát lại, đã từ chối |
| FAILA0 | Chưa có khóa/phù hợp session để chạy lệnh |

Mode 1024 đổi chữ số cuối từ 3 thành 4. LED 7 đoạn không thể biểu diễn mọi chữ
giống màn hình máy tính; xem thêm mã trên terminal để đọc chính xác.

| Chọn công tắc | HEX5..HEX3 | HEX2..HEX0 |
|---|---|---|
| SW0 ON | RX_COUNT, 12 bit thấp | TX_COUNT, 12 bit thấp |
| SW0 OFF, SW1 ON | AUTH_FAILS, 12 bit thấp | REPLAYS, 12 bit thấp |
| SW0/SW1 OFF, SW2 ON | Mã thao tác | Độ dài thông điệp, hex |

Các số trên HEX là **hexadecimal**. Sau reset rồi chạy đúng một demo đầy đủ:
SW0 dự kiến `006002` (6 gói nhận, 2 gói mã hóa); SW1 dự kiến `002002` (2 lỗi tag,
2 lần phát lại). Không reset giữa các lần demo thì counter cộng dồn. UART trả đủ 32 bit.

LEDR0=OK, 1=ERROR, 2=private key còn trong FPGA, 3=BUSY, 4=session hoạt động,
5=đã có gói nhận xác thực, 6=đã phát hiện replay, 7=RNG alarm, 8=health PASS,
9=RNG ready. LEDR5/6 là chỉ báo lịch sử từ reset, không tự tắt khi xóa session.

## 6. Giao thức và các giới hạn an toàn

K/E/D/Z giữ giao thức bắt đầu bằng `!`, nên script ba lệnh độc lập cũ vẫn dùng
được trên SOF channel. K/E/D/Z mới làm mất session cũ. Chỉ E/D thành công mới
cung cấp khóa cho S; KeyGen không tự tạo khóa dùng chung.

Record bắt đầu bằng `$`: `$<S/P/U><7/1>0<LLLL><payload_hex><CRC32>LF`.
LLLL là số byte payload, 4 chữ số hex. CRC32/ISO-HDLC trên ASCII từ opcode đến
hết payload, không tính `$`, CRC hoặc LF. Một request tại một thời điểm, chờ END
trước khi gửi tiếp. S tối đa một lần cho mỗi kết quả E/D.

- S: session_id 16 byte mới, do PC sinh bằng nguồn ngẫu nhiên hệ điều hành.
- P: plaintext 0–256 byte; trả SEQ, ciphertext và tag.
- U: seq_be64 || ciphertext || tag16; độ dài tổng 24–280 byte.
- A0: thiếu khóa/session hoặc mode không phù hợp; A1: tag sai; A2: số thứ tự sai;
  A3: quá độ dài; A6: đạt giới hạn counter, cần thiết lập khóa phiên mới.
- F0/F1/F2/F3: cú pháp / CRC / độ dài / timeout hoặc framing UART.

HKDF-HMAC-SHA3-256: salt=session_id; IKM=K của ML-KEM;
info=`MLKEM-UART-v1` || mode_byte || epoch_be64 (mode_byte=3/4).
72 byte đầu ra gồm K_E2D[32], K_D2E[32], prefix_E2D[4], prefix_D2E[4].
E/D trong tên chiều là bên thực hiện Encaps/Decaps, không cố định PC hay FPGA.

IV GCM=prefix_4_byte || seq_be64. AAD 32 byte gồm session_id[16], mode[1],
direction[1], length_be16[2], seq_be64[8], ASCII `MKG1`[4]. Tag đủ 128 bit.
Epoch tăng cho mỗi session và không bị Z/K/E/D đưa về 0; epoch không được vòng lại.
SEQ bắt đầu 0, chỉ tăng sau thành công, chặn từ 0xFFFFFFFF để yêu cầu rekey.
Receiver yêu cầu đúng số kế tiếp; đây là chống replay **theo thứ tự**, không có cửa sổ
cho phép đảo thứ tự như giao thức mạng.

**Sau reset/nạp lại/mất điện, PC bắt buộc sinh session_id mới.** Epoch không được
lưu qua mất điện. Không phát lại nguyên handshake đã ghi trước đó sau reset.
Không dùng seed cố định/session_id cố định cho ứng dụng thật. Kiểm thử có thể dùng
vector cố định, nhưng đó không phải chế độ cấp khóa vận hành.

Chưa có chữ ký/chứng chỉ/PSK xác thực danh tính; kẻ điều khiển toàn bộ cổng điều
khiển có thể thay handshake. Không tuyên bố chống MITM. Tag GCM xác thực gói theo
khóa đang có, không tự chứng minh người gửi là ai. CRC không phải MAC.

TRNG/DRBG vẫn là prototype trước đó, chưa có chứng nhận entropy. Chưa đánh giá
side-channel/masking; chưa chứng minh xóa vật lý mọi bản sao trong RAM phụ/debug.
Giới hạn bộ đệm SampleNTT của core ML-KEM trước đó vẫn còn. Các fingerprint là
chức năng quan sát cho demo, không phải chứng minh an toàn hay chứng nhận NIST.

## 7. Kiểm thử và ảnh cho báo cáo

```powershell
cd D:\ML_KEM_768_1024
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_channel_regression.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\10_demo\uart\mlkem_channel.ps1 -SelfTest
```

Regression: AES-256 KAT; GCM 10 vector (0–256 byte, AAD 0–32 byte), decrypt/tag sai;
HKDF hai mode; giao thức record hai mode và hai vai trò, gồm gói rỗng và 256 byte;
epoch/rekey/counter limit;
test top-level qua chân UART với KeyGen/Decaps ML-KEM-768, tamper/replay và LED/HEX.
Test top-level tăng baud mô phỏng để giảm thời gian; không phải đo UART/entropy trên kit.

Nên lưu: Flow Summary, Fitter Summary, timing đa corner của bản mới; transcript
regression; terminal demo cả hai mode; ảnh kit PASS63/PASS64; ảnh SW0/SW1 và
evidence.json. Phân biệt ảnh mô phỏng, ảnh tổng hợp và ảnh phần cứng thực tế.

Tài liệu thuật toán: [AES FIPS 197](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.197-upd1.pdf),
[GCM SP 800-38D](https://csrc.nist.gov/pubs/sp/800/38/d/final),
[HKDF RFC 5869](https://www.rfc-editor.org/rfc/rfc5869).
Giao thức UART và cách ghép các khối trong project là thiết kế thử nghiệm của đồ án,
không phải giao thức được chuẩn hóa trong ba tài liệu này.
