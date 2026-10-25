# ML-KEM-768 và ML-KEM-1024 trên FPGA

Mã nguồn RTL, kiểm thử và kết quả phục vụ báo cáo của hệ ML-KEM trên DE10-Standard, FPGA Cyclone V `5CSXFC6D6F31C6`. Bộ nguồn gồm bảy kiến trúc so sánh và một project demo nút nhấn KEY1. Clock lõi mục tiêu là 160 MHz; UART dùng 115200 baud, 8-N-1.

[Kết quả và minh chứng](docs/EVIDENCE.md) · [Excel tổng hợp](docs/ML_KEM_Theo_doi_kien_truc.xlsx) · [Hướng dẫn tái lập](docs/REPRODUCE.md)

## Các project

| Kiến trúc | Thư mục trong `05_quartus` | Nguồn riêng trong `01_rtl/architectures` |
|---|---|---|
| Iterative in-place | `iterative_baseline` | `iterative_baseline` |
| Streaming ping-pong | `channel` | `streaming_pingpong` |
| Continuous banked | `continuous_banked` | `continuous_banked` |
| Banked cycle-opt | `continuous_banked_cycle_opt` | `continuous_banked_cycle_opt` |
| Streaming-Balanced 2BU / 4 bank | `streaming_balanced_2bu` | `streaming_balanced_2bu` |
| Streaming-Balanced 4BU / 8 bank | `streaming_balanced_4bu` | `streaming_balanced_4bu` |
| Streaming-Balanced 8BU / 16 bank | `streaming_balanced_8bu` | `streaming_balanced_8bu` |
| Demo KEY1 dùng lõi 4BU | `streaming_balanced_4bu_keydemo` | `streaming_balanced_4bu_keydemo` |

`continuous_banked_cycle_opt` là bản Opt V2/A4 đã hợp nhất tên. Một số kết quả gốc vẫn mang tên `continuous_banked_cycle_opt_v2` để giữ đúng nguồn gốc phép đo; đổi tên project không tạo ra một lần fit mới.

## Công cụ và chạy nhanh

Cần Windows PowerShell, Python 3, Intel Quartus Prime có hỗ trợ Cyclone V và ModelSim Intel FPGA Edition có các thư viện primitive vendor. Các project dùng Quartus 18.1. Thư viện Python `cryptography` phục vụ AES-GCM và kiểm thử phía PC.

Chạy các lệnh sau tại thư mục gốc repo:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\08_model\python\requirements.txt
.\.venv\Scripts\python.exe .\08_model\python\channel_demo.py --selftest
```

Chạy regression của bản 4BU, thay đường ModelSim theo máy thực tế:

```powershell
$mlkemPython = (Resolve-Path '.\.venv\Scripts\python.exe').Path
$mlkemModelSim = 'D:\QUARTUS\modelsim_ase\win32aloem'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\07_scripts\run_architecture_comparison_regression.ps1 -Architecture A5 -ModelsimBin $mlkemModelSim -PythonExe $mlkemPython
```

Mặc định `-ModelsimBin` trong các runner là `D:\QUARTUS\modelsim_ase\win32aloem`; có thể ghi đè bằng tham số. `-PythonExe` chọn Python có thư viện đã cài; nếu bỏ trống, runner tìm `python` trong PATH. Các runner tạo work riêng dưới `04_sim` và lưu kết quả mới dưới `09_reports`.

Để biên dịch FPGA, mở QPF trong đúng thư mục project và chọn **Processing → Start Compilation**. Hướng dẫn lệnh cho từng kiến trúc, kiểm tra STA và demo UART nằm trong [REPRODUCE.md](docs/REPRODUCE.md).

## Phạm vi mã nguồn và kết quả

`01_rtl` chứa nguồn được các QSF đang hoạt động tham chiếu và SDC riêng. `02_tb`, `03_vectors`, `07_scripts`, `08_model` và `10_demo` cung cấp testbench, vector cố định, runner, mô hình tham chiếu và chương trình UART. Không kèm database Quartus, bitstream SOF, thư viện mô phỏng đã biên dịch, công cụ bên thứ ba hoặc PDK.

Khi chuẩn bị repo, nguồn RTL của cả tám project đã compile thành công bằng ModelSim ở nhánh mô phỏng; host selftest và kiểm thử host bằng mô phỏng phần mềm cũng PASS. Đây không phải một lần chạy lại toàn bộ regression, fit, STA hoặc kiểm thử kit. Các Fitter/STA và log trong [chỉ mục minh chứng](docs/EVIDENCE.md) giữ kết quả của những lần đo gốc được nêu ở đó. Các bản còn setup âm được ghi rõ trạng thái.

Vector cố định dùng để tái lập kiểm thử. Khi chạy kit với random mới, chu kỳ KEM có thể thay đổi nhẹ do dữ liệu đầu vào và rejection sampling; thời gian core không bao gồm truyền UART. Kiểm tra ACVP bằng Python xác nhận mô hình tham chiếu, không phải chứng nhận ACVP cho RTL.
