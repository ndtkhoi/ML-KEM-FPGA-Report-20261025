# Phân tích lựa chọn kiến trúc 4BU / 8 bank

## Số liệu từ các bản compile hiện tại

Các cấu hình dùng cùng thiết bị Cyclone V `5CSXFC6D6F31C6`, cùng mục tiêu
160 MHz, seed 4 và SDC. Tài nguyên tính cho toàn hệ thống UART/RNG/KEM/AES-GCM.
34 file RTL chung tương đương sau chuẩn hóa tên; phần khác là NTT/bank nhớ.

| Chỉ tiêu | 2BU / 4 bank | 4BU / 8 bank | 8BU / 16 bank |
|---|---:|---:|---:|
| ALM | 27.017 | 27.176 | 28.480 |
| Registers | 37.370 | 37.911 | 38.283 |
| DSP | 32 | 40 | 56 |
| M10K | 49 | 55 | 66 |
| Setup WNS nhỏ nhất (ns) | −0,194 | +0,091 | −0,512 |
| Hold WNS nhỏ nhất (ns) | +0,063 | +0,116 | +0,102 |
| Fmax báo cáo ở Slow 85°C (MHz) | 155,18 | 162,36 | 147,89 |
| NTT/INTT (chu kỳ) | 459 | 235 | 127 |
| Kết luận STA ở 160 MHz | Chưa đạt setup | Đạt 4 corner | Chưa đạt setup |

Chu kỳ KEM từ cùng fixture RTL, không gồm thời gian UART hoặc chờ RNG bên ngoài
service core. Đây là số chu kỳ, không phải phép đo độ trễ end-to-end trên kit.

| Mode / phép toán | 2BU | 4BU | 8BU |
|---|---:|---:|---:|
| ML-KEM-768 KeyGen | 72.229 | 70.885 | 70.237 |
| ML-KEM-768 Encaps | 95.932 | 94.364 | 93.608 |
| ML-KEM-768 Decaps | 132.974 | 130.510 | 129.322 |
| ML-KEM-1024 KeyGen | 114.409 | 112.617 | 111.753 |
| ML-KEM-1024 Encaps | 143.541 | 141.525 | 140.553 |
| ML-KEM-1024 Decaps | 190.867 | 187.731 | 186.219 |

## Đoạn phân tích có thể đưa vào báo cáo

Trong ba cấu hình đã khảo sát, kiến trúc **Streaming-Balanced 4BU với tám bank
nhớ là lựa chọn cân bằng tối ưu cho mục tiêu 160 MHz**. So với 2BU, cấu hình
4BU chỉ tăng khoảng 0,6% ALM, đồng thời giảm 48,8% số chu kỳ NTT/INTT. Chi phí
đánh đổi là DSP tăng từ 32 lên 40 và M10K tăng từ 49 lên 55. Cấu hình 8BU tiếp
tục giảm số chu kỳ NTT/INTT, nhưng lợi ích ở cấp KEM chỉ còn khoảng 0,7–0,9%
so với 4BU, trong khi cần thêm 40% DSP, 20% M10K và 4,8% ALM. Ngoài ra, 4BU
là cấu hình duy nhất trong ba bản compile hiện tại đáp ứng timing ở 160 MHz,
với setup slack nhỏ nhất +0,091 ns. Vì vậy, thiết kế lựa chọn 4BU/8 bank để
cân bằng tốc độ xử lý, mức sử dụng tài nguyên và khả năng đáp ứng timing.

Kết luận trên áp dụng cho các bản triển khai FPGA và điều kiện thử hiện tại.
Mỗi cấu hình mới được fit với một seed; chưa có phép đo power và không dùng
kết quả này để khẳng định tối ưu toàn cục hoặc tối ưu PPA của ASIC. Hai bản
2BU/8BU đã qua kiểm thử chức năng nhưng chưa đạt setup; latency quy đổi ở
160 MHz của hai bản này chỉ là giá trị mục tiêu.

## Nguồn và khả năng kiểm tra lại

- Run 2BU: `SB2_20261025_063232`.
- Run 4BU: `A5_20261024_063318`.
- Run 8BU: `SB8_20261025_063630`.
- Snapshot report/SOF/QSF theo Run ID trong `09_reports/architecture_tracking/`.
- Số liệu và audit nguồn: `BU_COMPILE_RESULTS_20261025.json`.
- Workbook hiện hành: tab `So_sanh_BU`, `Tong_hop`, `Compile`, `Timing`,
  `Mo_phong`, `Ghi_chu`.

Các kết luận về tỷ lệ được tính bằng công thức trong workbook. Lịch sử các
lần compile trước vẫn giữ nguyên; không đổi số liệu 2BU/8BU để làm đẹp so sánh.
