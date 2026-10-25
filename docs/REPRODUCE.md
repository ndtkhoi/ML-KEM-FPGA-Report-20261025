# Tái lập kiểm thử và demo FPGA

Thực hiện các lệnh từ thư mục gốc repo. Các đường dẫn ModelSim và Python dưới đây là tham số của máy đang chạy. SDC nằm trong `constraints` cạnh `rtl` của từng kiến trúc; QSF chọn đúng cây nguồn riêng của nó.

## Chuẩn bị Python và ModelSim

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\08_model\python\requirements.txt
$mlkemPython = (Resolve-Path '.\.venv\Scripts\python.exe').Path
$mlkemModelSim = 'D:\QUARTUS\modelsim_ase\win32aloem'
```

`$mlkemModelSim` phải chứa `vlib.exe`, `vlog.exe`, `vsim.exe`. ModelSim cần các thư viện `altera_lnsim_ver`, `altera_mf_ver` và `cyclonev_ver` cho bài kiểm tra PLL vendor. Các runner truyền đường work riêng, tự tạo vector/model snapshot và giữ log theo từng lượt.

Kiểm tra phía phần mềm, không cần kết nối kit:

```powershell
& $mlkemPython .\08_model\python\channel_demo.py --selftest
& $mlkemPython .\02_tb\host\test_channel_host.py
& $mlkemPython .\08_model\python\validate_mlkem_acvp.py
```

Hai kiểm tra host trên dùng phần mềm hoặc emulator. Bài ACVP kiểm tra mô hình Python với vector được lưu trong `03_vectors/acvp`.

## Regression RTL

Chạy một cấu hình trong mỗi lệnh. A4 là Banked cycle-opt đã hợp nhất từ Opt V2, A5 là bản so sánh 4BU.

```powershell
# Iterative in-place
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_iterative_baseline_regression.ps1 -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython

# Streaming ping-pong
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_streaming_pingpong_regression.ps1 -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython

# Continuous banked
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_continuous_banked_a2_regression.ps1 -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython

# Banked cycle-opt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_architecture_comparison_regression.ps1 -Architecture A4 -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython

# Streaming-Balanced 4BU
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_architecture_comparison_regression.ps1 -Architecture A5 -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython

# Streaming-Balanced 2BU hoặc 8BU
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_streaming_lane_regression.ps1 -Lanes 2 -Mode full -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_streaming_lane_regression.ps1 -Lanes 8 -Mode full -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython

# Demo KEY1: kiểm thử chế độ nút nhấn và đường điều khiển host
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_keydemo_regression.ps1 -ModelsimBin $mlkemModelSim
```

Các runner đọc nguồn và macro từ QSF. Khi mô phỏng chức năng, macro `SYNTHESIS` được bỏ để dùng mô hình clock/entropy; nhánh PLL vendor được kiểm tra riêng trong những runner có bài kiểm tra này. Một số runner yêu cầu assertion bắt thao tác sampler bị cấm; thông báo Fatal dự kiến trong riêng bài kiểm tra âm không được xem là phép vận hành hợp lệ của phần cứng.

NTT/INTT và MultiplyNTTs dùng vector trong `03_vectors/ntt`; service core và UART dùng `03_vectors/service`, `03_vectors/full` và `03_vectors/channel`. Bộ vector đã được đưa vào repo cùng các chương trình tạo lại. Số chu kỳ nằm trong log `tb_ntt_intt`, `tb_multiply_ntts` và `tb_mlkem_service_core`; xem [chỉ mục kết quả](EVIDENCE.md#ntt-intt).

## Full Compilation và kiểm tra timing

Mở QPF của kiến trúc cần chạy, không chọn nguồn từ kiến trúc khác. Ví dụ bản 4BU:

```text
05_quartus/streaming_balanced_4bu/mlkem_streaming_balanced_4bu_de10.qpf
```

Trong Quartus chọn **Processing → Start Compilation**. Có thể dùng shell Quartus nếu `quartus_sh` nằm trong PATH:

```powershell
Push-Location .\05_quartus\streaming_balanced_4bu
quartus_sh --flow compile mlkem_streaming_balanced_4bu_de10
Pop-Location
```

File SOF và các report mới được tạo trong `output_files` của project. Đọc Fitter để lấy tài nguyên; đọc STA ở đủ bốn corner cho setup, hold và các ràng buộc liên quan. `Flow Successful` riêng lẻ chưa xác nhận đạt 160 MHz. Báo cáo gốc và tình trạng timing của từng kiến trúc nằm ở [EVIDENCE.md](EVIDENCE.md#architecture-results).

Tên nguồn hiện tại `continuous_banked_cycle_opt` giữ bản Opt V2/A4. Tên `continuous_banked_cycle_opt_v2` trong log và report lịch sử phản ánh revision lúc đo. Chưa chạy lại fit chỉ vì hợp nhất tên.

## Demo UART trên DE10-Standard

Nạp SOF của đúng project sau Full Compilation và kiểm tra timing. Bản so sánh `streaming_balanced_4bu` nhận mode qua khung lệnh UART; dùng `-Mode 768` hoặc `-Mode 1024`. Bản `streaming_balanced_4bu_keydemo` hỗ trợ nút KEY1 và chọn mode bằng SW0; chỉ dùng `-Mode Switch` khi bitstream đang nạp có chức năng chọn mode này.

Kết nối CP210x UART mức 3,3 V: RXD của adapter tới JP1 chân 1 (FPGA TX), TXD tới JP1 chân 2 (FPGA RX), GND tới JP1 chân 12 hoặc 30. USB-Blaster dùng để nạp cấu hình; UART dùng để gửi yêu cầu và nhận kết quả.

Đóng PuTTY trước khi chạy chương trình host trên cùng COM. Thay `COM5` bằng cổng thực tế:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\10_demo\uart\mlkem_channel_video.ps1 -ComPort COM5 -Mode 768 -RandomSource FPGA -CoreClockHz 160000000 -PythonExe $mlkemPython
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\10_demo\uart\mlkem_channel_video.ps1 -ComPort COM5 -Mode 1024 -RandomSource FPGA -CoreClockHz 160000000 -PythonExe $mlkemPython
```

Chương trình kiểm tra KEM giữa PC và FPGA theo hai hướng vai trò, kênh AES-256-GCM hai chiều, từ chối tag bị sửa và chống phát lại. Kết quả được lưu trong `09_reports/channel` theo từng lượt.

Với project KEY1, mở PuTTY ở 115200 baud, 8-N-1, flow control None; SW0 OFF chọn 768, ON chọn 1024, KEY0 reset và KEY1 bắt đầu. Đây là tự kiểm tra KEM trên FPGA; chuỗi KEY1 không thay thế bài kiểm tra trao đổi PC–FPGA và AES-GCM. Terminal hiện đầy đủ SHA3-256 của shared secret; HEX5…HEX0 hiện sáu ký tự đầu. Nhấn KEY0 để reset và xóa trạng thái sau demo.

Thời gian core ở 160 MHz: `ms = số chu kỳ / 160000`. Khi lấy kết quả mới, ghi lại cấu hình project, SHA256 SOF, clock thực tế và log của chính lượt đó để liên kết đúng phần cứng với phép đo.

## Kiểm tra đã thực hiện khi đóng gói

Đã kiểm tra đường dẫn QSF/SDC/include, parse các script PowerShell, host selftest, host emulator flow và compile nguồn RTL của tám project bằng ModelSim. Không tái chạy toàn bộ regression, Quartus synthesis/fitter/STA hoặc thử kit trong bước đóng gói. Kết quả lịch sử được giữ riêng theo nguồn đo trong [EVIDENCE.md](EVIDENCE.md).
