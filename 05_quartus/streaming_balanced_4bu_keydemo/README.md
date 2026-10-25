# DE10-Standard: nhấn KEY1, xem kết quả trên PuTTY

Project riêng cho demo tự chạy ML-KEM-768/1024 trên FPGA. Giữ nguyên source
và SOF của bản `streaming_balanced_4bu` đã chạy với PowerShell.

## Chức năng

- KEY0: reset hệ thống và xóa trạng thái khóa/session.
- KEY1: một lần nhấn chạy KeyGen → Encaps → Decaps, dùng random từ FPGA.
- SW0: OFF=768, ON=1024; mode được chốt khi nhận nút nhấn.
- FPGA so sánh trực tiếp hai shared secret 256 bit; không xuất khóa thô.
- UART in số chu kỳ hex và thập phân của từng bước, SHA3-256 đầy đủ sau
  Encaps/Decaps và `SELFTEST: PASS` hoặc `SELFTEST: FAIL`.
- HEX giữ 6 ký tự đầu của SHA3-256(shared secret). Các trang SW1..SW9 và
  ý nghĩa LED giữ như bản board demo; SW7 xem chu kỳ KEM gần nhất dạng hex.
- Nút được đồng bộ và chống dội 20 ms ở clock 160 MHz. Giữ nút không lặp;
  cần thả nút rồi nhấn lại. Nhấn trong lúc đang bận sẽ bị bỏ qua.
- Khung lệnh UART của chương trình PowerShell vẫn được hỗ trợ khi rảnh.

Đây là bài tự kiểm tra KEM hoàn toàn trên FPGA. `SELFTEST: PASS` không có
nghĩa là đã chạy bài đối chiếu FPGA–PC, AES-GCM, tamper hoặc replay của script
PowerShell. Chạy script riêng nếu cần các bằng chứng đó.

## Nạp và thao tác

1. Mở `D:\ML_KEM_768_1024\05_quartus\streaming_balanced_4bu_keydemo\mlkem_streaming_balanced_4bu_keydemo.qpf`.
2. Dùng SOF của chính project này sau khi biên dịch thành công và timing đạt:
   `D:\ML_KEM_768_1024\05_quartus\streaming_balanced_4bu_keydemo\output_files\mlkem_streaming_balanced_4bu_keydemo.sof`.
3. Trong Quartus Programmer, chọn cable DE10, JTAG, Auto Detect; gán SOF
   vào FPGA Cyclone V, chọn Program/Configure rồi Start.
4. Giữ CP210x kết nối UART mức 3,3 V: RXD ← JP1-1 (FPGA TX),
   TXD → JP1-2 (FPGA RX), GND ↔ JP1-12 hoặc JP1-30. Không nối nguồn adapter vào kit.
5. Mở PuTTY, chọn cổng COM của CP210x, Serial 115200, 8 data bit,
   1 stop bit, parity None, flow control None. Không chạy script đang giữ cùng COM.
6. Đặt SW1..SW9 OFF. Chọn SW0, nhấn/thả KEY0, sau đó nhấn/thả KEY1.
7. Chờ ba khối `OP: K`, `OP: E`, `OP: D`. Khối cuối phải có
   `STATUS: OK`, `ERROR: 00`, `SELFTEST: PASS`; SHA3 của E và D phải giống nhau.
8. Đối chiếu 6 ký tự đầu của `SS_SHA3` trong khối D với HEX trên kit.
9. Đổi SW0 khi đã chạy xong, thả rồi nhấn KEY1 để chạy mode còn lại.

Không cần gõ hoặc dán bất kỳ lệnh nào trong PuTTY. Mở PuTTY trước khi nhấn
KEY1; nếu mở muộn thì nhấn lại để có lượt kết quả mới.

## Dạng báo cáo

Mỗi bước có OP, MODE, STATUS, ERROR, CYCLES_HEX, KEY_READY, RANDOM_SOURCE,
RNG_HEALTH, SS_SHA3, EK_HEX, CT_HEX, CYCLES_DEC, CORE_CLOCK_HZ, SELFTEST, END.

Trong chế độ nút nhấn, EK_HEX/CT_HEX được rút thành `-` để terminal gọn;
khóa công khai và ciphertext được giữ trong core để chuyển sang bước sau.
Ở KeyGen, SS_SHA3 là `-` vì chưa có shared secret. Sau Encaps và Decaps,
SS_SHA3 có đủ 64 ký tự hex. Các khung lệnh PC vẫn xuất EK/CT như trước.

- CYCLES_DEC: số chu kỳ thập phân, có thể có số 0 ở đầu.
- CYCLES_HEX: cùng số chu kỳ ở dạng hexadecimal.
- Thời gian core (ms) = CYCLES_DEC / 160000.
- Thời gian tạo random, chờ nút và gửi UART không nằm trong số đo core.
- SELFTEST của K/E là RUNNING; kết luận cuối nằm ở khối D hoặc khối lỗi.
- E1: nguồn random chưa sẵn sàng trong thời hạn hoặc báo lỗi health.
- E2: shared secret Encaps và Decaps không khớp.
- E3: core không trả kết quả thành công/hợp lệ dù không có mã lỗi chi tiết.

Khi tự kiểm tra gặp lỗi, khóa trong core được xóa trước khi xuất báo cáo lỗi.
Giá trị so sánh shared secret riêng của bộ điều khiển cũng được xóa sau lượt
chạy. KEY0 reset được dùng để hủy lượt đang chạy.

## Kiến trúc và kiểm tra

- `mlkem_channel_keydemo_top.sv` tách từ top đã chạy PASS, thêm bộ chống dội
  và giữ đường TX cho chuỗi tự chạy, không cần máy tính gửi ký tự mở khung.
- `channel_kem_uart_keydemo.sv` tách từ UART shell cũ, dùng cùng service core
  4BU. Không tạo thêm một core ML-KEM thứ hai.
- NTT/INTT, Keccak, sampler, codec, TRNG và AES-GCM dùng các RTL hiện có.
- Chuyển chu kỳ sang thập phân bằng double-dabble trong 32 clock ngoài
  khoảng đo core; không dùng bộ chia để in số.
- Project này dành cho clock core 160 MHz, đúng giá trị CORE_CLOCK_HZ in ra.

Chạy kiểm tra mô phỏng:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\ML_KEM_768_1024\07_scripts\run_keydemo_regression.ps1"
```

Regression kiểm tra cả hai mode với golden vector, UART qua chân serial,
decimal/hex, fingerprint/HEX, nút dội/giữ, chốt mode, lỗi so sánh, timeout
random, reset giữa lượt và giao thức host KEM/AES-GCM cũ. Nguồn random được
thay bằng vector xác định trong testbench; mô phỏng không chứng minh entropy
vật lý của kit.

Biên dịch Quartus từ thư mục project này:

```powershell
& 'D:\QUARTUS\quartus\bin64\quartus_sh.exe' --flow compile mlkem_streaming_balanced_4bu_keydemo
```

Kết quả kiểm tra/biên dịch thực tế được ghi riêng trong `VALIDATION.md` khi
hoàn tất. Việc tạo SOF không tự xác nhận đã thử nút KEY1 trên board vật lý.
