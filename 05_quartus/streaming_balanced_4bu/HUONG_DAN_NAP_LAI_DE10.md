# Nạp lại DE10-Standard — Streaming-Balanced 4BU

Đối chiếu project, RTL, báo cáo Quartus và script demo ngày 20/10/2026.
Lượt làm việc này chỉ đọc, kiểm tra phần mềm PC và chuẩn bị quy trình; chưa nạp kit.

## 1. Đúng project và bitstream

| Mục | Giá trị |
|---|---|
| Board | DE10-Standard |
| FPGA | Cyclone V `5CSXFC6D6F31C6` |
| Quartus | Prime Lite 18.1.0 Build 625 |
| Project | `D:\ML_KEM_768_1024\05_quartus\streaming_balanced_4bu\mlkem_streaming_balanced_4bu_de10.qpf` |
| Top | `mlkem_channel_top` |
| File nạp | `D:\ML_KEM_768_1024\05_quartus\streaming_balanced_4bu\output_files\mlkem_streaming_balanced_4bu_de10.sof` |
| Clock | Đầu vào 50 MHz; PLL tạo clock core 160 MHz |
| UART | 115200 baud, 8-N-1, không flow control |
| Macro chọn kiến trúc | `MLKEM_STREAMING_BALANCED_4BU` |

QSF lấy cấu hình từ `continuous_banked_cycle_opt_v2`, sau đó thêm macro và
hai file RTL `ntt_core_stream4.sv`, `poly_bank_32_sdp.sv`. Vì vậy cần giữ
nguyên cấu trúc thư mục khi biên dịch.

Trong service core, macro chọn `ntt_core_stream4` và điều chỉnh đọc kết quả
theo độ trễ của bank mux có thanh ghi. NTT/INTT có 4 butterfly/clock,
8 bank 32×12, mỗi hệ số được lưu một lần. Báo cáo synthesis hiện tại xác nhận
đã dùng `ntt_core_stream4`, 4 nhánh arithmetic và các bank tương ứng.

### Trạng thái bản biên dịch đang có

- Flow, Fitter và Assembler: Successful, ngày 20/10/2026.
- Tài nguyên: 27.399 ALM (65%), 38.281 register, 55 RAM block, 40 DSP (36%).
- Setup/hold slack, đơn vị ns:

| Corner | Setup | Hold |
|---|---:|---:|
| Slow 1100 mV, 85°C | +0,045 | +0,263 |
| Slow 1100 mV, 0°C | +0,226 | +0,169 |
| Fast 1100 mV, 85°C | +2,038 | +0,126 |
| Fast 1100 mV, 0°C | +2,543 | +0,116 |

- Các TNS trong summary đều bằng 0; setup chậm nhất có biên nhỏ, +0,045 ns.
- Không thiếu file trong 39 file QSF/RTL/SDC đã đối chiếu; không file nào
  có thời gian sửa mới hơn SOF. Đây là kiểm tra đường dẫn và thời gian sửa,
  không phải bằng chứng tái biên dịch từ source.
- SHA-256 của SOF tại thời điểm kiểm tra:

```text
4B7D41E19643F6B5D7613A50AB75E09193F181D4CA02F62A1F9B75E741268379
```

Có thể dùng SOF này cho lượt nạp lại. Chỉ cần Full Compilation khi muốn
tạo lại bitstream hoặc đã sửa RTL/QSF/SDC. Lượt compile trong báo cáo mất
khoảng 32 phút; thời gian thực tế phụ thuộc máy.

## 2. Kết nối khi bắt đầu làm với kit

1. Cấp nguồn và bật DE10-Standard.
2. Cắm cáp vào cổng USB-Blaster II của board để nạp FPGA qua JTAG.
3. Kết nối USB–UART mức logic 3,3 V vào JP1 theo bảng dưới.
4. Đóng PuTTY hoặc ứng dụng khác đang giữ cổng COM trước khi chạy script.

| Chân DE10 | Nối với USB–UART |
|---|---|
| JP1-1, FPGA TX, `PIN_W15` | RXD |
| JP1-2, FPGA RX, `PIN_AK2` | TXD |
| JP1-12 hoặc JP1-30 | GND |

Không nối dây nguồn 3V3/5V của adapter vào kit. Xác định pin 1 theo ký hiệu
trên board. Pin TX/RX được đối chiếu với QSF; vị trí JP1 theo tài liệu UART
trong repository.

Kiểm tra thiết bị trong PowerShell:

```powershell
& 'D:\QUARTUS\quartus\bin64\jtagconfig.exe'
[System.IO.Ports.SerialPort]::GetPortNames()
```

Ghi lại tên cable và COM thực tế; `COM5` và `DE-SoC [USB-1]` bên dưới là
giá trị ví dụ từ script cũ. Khi kiểm tra ngày 20/10, máy báo
`No JTAG hardware available` và chưa có cổng COM.

## 3. Nạp bằng giao diện Quartus

1. Mở đúng QPF ở mục 1.
2. Vào **Tools → Programmer**, chọn **Mode: JTAG**.
3. Trong **Hardware Setup**, chọn cable của DE10 đang kết nối.
4. Dùng **Auto Detect**, nhận diện HPS và FPGA trong JTAG chain.
5. Gán SOF ở mục 1 vào dòng FPGA thuộc `5CSXFC6`; không gán vào HPS.
6. Chọn **Program/Configure** ở dòng FPGA, bấm **Start**.
7. Chờ **100% (Successful)**.

SOF cấu hình FPGA tạm thời; sau khi tắt nguồn cần nạp lại.

### Lệnh tương đương, khi đã xác nhận JTAG chain

Script hiện có dùng HPS tại vị trí 1 và FPGA tại vị trí 2.
Chỉ dùng lệnh dưới khi kết quả nhận diện xác nhận đúng thứ tự đó.

```powershell
$Cable = 'DE-SoC [USB-1]' # Thay bằng tên cable thực tế.
$Sof = 'D:\ML_KEM_768_1024\05_quartus\streaming_balanced_4bu\output_files\mlkem_streaming_balanced_4bu_de10.sof'
& 'D:\QUARTUS\quartus\bin64\quartus_pgm.exe' `
  -c $Cable -m JTAG -o 's;SOCVHPS@1' -o "p;$Sof@2"
if ($LASTEXITCODE -ne 0) { throw 'Nap FPGA chua thanh cong.' }
```

## 4. Chạy demo ML-KEM-768

1. Đặt `SW0=OFF`; đặt `SW1..SW9=OFF`.
2. Nhấn rồi thả `KEY0` để reset. Khi rảnh và chưa có kết quả, HEX hiện `768`.
3. Thay `COM5` bằng cổng USB–UART thực tế và chạy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File 'D:\ML_KEM_768_1024\10_demo\uart\mlkem_channel_video.ps1' `
  -ComPort COM5 -Mode Switch -RandomSource FPGA -CoreClockHz 160000000
```

Script này chỉ chạy demo, không nạp lại SOF. Lệnh đầu của demo tự xóa
khóa/session cũ và đọc mode do SW0 chọn.

Demo kiểm tra hai vai trò:

- FPGA KeyGen → PC Encaps → FPGA Decaps.
- PC KeyGen → FPGA Encaps → PC Decaps.

Sau mỗi vai trò, demo tạo session AES-256-GCM, kiểm tra dữ liệu hai chiều,
sửa tag để thử từ chối (`A1`), gửi lại gói để thử chặn replay (`A2`), rồi
gửi gói hợp lệ để kết thúc. `A1`/`A2` ở các bước thử này là kết quả mong đợi.

### Dấu hiệu hoàn tất

- Terminal có `FINAL RESULT: ML-KEM-768 HARDWARE DEMONSTRATION PASS`.
- Các mục KEM, AES-GCM, tamper, replay và FPGA random source đều PASS.
- `FINAL BOARD CODE` trùng sáu ký tự trên `HEX5..HEX0`.
- LEDR7 báo PASS; LEDR8/9 sáng sau khi đã phát hiện tag giả/replay.
- Script in đường dẫn `Evidence: ...\evidence.json`; file phải có
  `status: "PASS"`, `mode: 768`, `configured_core_clock_hz: 160000000`.

Mã trên HEX là 6 ký tự đầu của SHA3-256(shared secret), không phải toàn bộ khóa.
Với random từ FPGA, mã có thể thay đổi giữa các lượt.

## 5. Chạy ML-KEM-1024

1. Chờ lượt 768 kết thúc.
2. Đặt `SW0=ON`, giữ `SW1..SW9=OFF`.
3. Có thể nhấn/thả `KEY0` để bắt đầu sạch; HEX khi rảnh hiện `1024`.
4. Chạy lại đúng lệnh ở mục 4.
5. Kiểm tra dòng PASS cho ML-KEM-1024 và evidence có `mode: 1024`.

Không cần đổi SOF khi đổi mode. Giữ SW0 ổn định trong suốt một lượt demo.
Không dùng `-Mode Both` để tự chuyển mode trên bitstream này: lựa chọn mode
đang do công tắc vật lý quyết định.

## 6. Nút, công tắc và LED của đúng bản hiện tại

| Điều khiển | Chức năng |
|---|---|
| KEY0 | Reset hệ thống và xóa khóa/session |
| KEY1..KEY3 | Không có chức năng khởi chạy demo trong top hiện tại |
| SW0 | OFF=768, ON=1024 |
| SW1 | Bộ đếm RX/TX |
| SW2 | Bộ đếm AUTH_FAIL/REPLAY |
| SW3 | Bộ đếm lỗi RCT/APT |
| SW4 | Trang mã trạng thái; không dùng riêng trang này để kết luận PASS |
| SW5 | Hiện mã xác minh shared secret |
| SW6 | Operation và độ dài record |
| SW7 | Số chu kỳ KEM, hiển thị hex |
| SW8 | RNG CRC, hiển thị hex |
| SW9 | Lamp test: toàn bộ LED và HEX sáng |

Nếu bật nhiều SW1..SW9, công tắc số lớn hơn có ưu tiên hiển thị.

LEDR0=mode; LEDR1=đã ra reset; LEDR2=RNG ready; LEDR3=RNG health;
LEDR4=busy; LEDR5=key ready; LEDR6=session active; LEDR7=PASS;
LEDR8=đã phát hiện tag giả; LEDR9=đã chặn replay.

## 7. Những hướng dẫn cũ dễ gây nhầm

- `run_mlkem_video.ps1` mặc định nạp SOF của `continuous_banked`, và phần
  kiểm tra source của nó cũng gắn với project cũ. Dùng quy trình nạp tách
  riêng ở trên để chọn đúng 4BU.
- `mlkem_channel.ps1` và Python host mặc định quy đổi thời gian theo
  150 MHz; luôn truyền `-CoreClockHz 160000000` khi gọi script này trực tiếp.
  `mlkem_channel_video.ps1` đã mặc định 160 MHz, lệnh ở trên vẫn ghi rõ.
- `MLKEM_UART_PROTOCOL.md` còn mô tả KEY1 và các lệnh ký tự đơn từ phiên bản
  trước. Top hiện tại nhận khung KEM bắt đầu `!` và record bắt đầu `$`;
  dùng script channel tương ứng để tạo khung.
- README 4BU và báo cáo verification tháng 9 còn nội dung “experimental”,
  “fit pending” hoặc số timing của lần fit đầu. Timing của SOF đang chuẩn bị
  nạp được đối chiếu từ `output_files` ngày 20/10/2026.
- Dòng “Streaming-Balanced 4BU” trên terminal được viết cố định trong host;
  bản thân dòng đó không xác nhận FPGA đang mang đúng SOF. Cần chọn đúng
  bitstream khi nạp và lưu dấu nhận diện của nó cùng kết quả.

## 8. Bằng chứng và kiểm tra đã thực hiện

Host self-test đã PASS: HKDF đối chiếu thư viện, AEAD nhiều độ dài/sửa tag,
CRC. Đây là kiểm tra phần mềm PC, không phải lượt kiểm tra kit mới.

Hai evidence PASS trước đây đã đọc:

- 768: `D:\ML_KEM_768_1024\09_reports\channel\20260914_114326_450048\evidence.json`.
- 1024: `D:\ML_KEM_768_1024\09_reports\channel\20260914_114426_699420\evidence.json`.

Cả hai ghi mode chọn bằng switch, random FPGA và clock cấu hình 160 MHz.
Evidence cũ không lưu hash SOF, nên không dùng chúng để chứng minh bản
biên dịch ngày 20/10 đã được kiểm thử trên kit.

Mỗi lượt mới sẽ tạo thư mục riêng dưới `D:\ML_KEM_768_1024\09_reports\channel`.
Khi làm lại, lưu log nạp thành công, hash SOF, evidence của cả hai mode và ảnh
HEX khớp mã terminal. Chụp mã trước khi nhấn KEY0 hoặc tắt nguồn.
