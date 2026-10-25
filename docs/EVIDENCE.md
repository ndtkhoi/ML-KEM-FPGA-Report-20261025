# Kết quả và minh chứng ML-KEM-768/1024

Bộ số liệu chốt cho báo cáo ngày 25/10/2026. Các kết quả tài nguyên tính cho toàn hệ demo trên Cyclone V 5CSXFC6D6F31C6. Số chu kỳ RTL dùng cùng bộ vector, không gồm thời gian truyền UART.

[Bảng Excel gốc](ML_KEM_Theo_doi_kien_truc.xlsx) · [Chỉ mục số liệu và nguồn](evidence_index.json) · [CSV tài nguyên và timing](../09_reports/summary/architecture_results.csv) · [CSV chu kỳ](../09_reports/summary/operation_cycles.csv) · [CSV bốn corner](../09_reports/summary/timing_corners.csv)

<a id="architecture-results"></a>
## Kết quả các kiến trúc

| Kiến trúc | ALM | Registers | DSP | M10K | Setup min (ns) | Hold min (ns) | 160 MHz | Nguồn gốc |
|---|---:|---:|---:|---:|---:|---:|---|---|
| Iterative in-place | 24.673 | 35.940 | 28 | 43 | +0.020 | +0.145 | Đạt 4 corner | [Fitter](../09_reports/architecture_tracking/A0_20261024_000741/mlkem_iterative_baseline_de10.fit.rpt), [STA](../09_reports/architecture_tracking/A0_20261024_000741/mlkem_iterative_baseline_de10.sta.rpt) |
| Streaming ping-pong | 24.882 | 36.341 | 28 | 44 | +0.075 | +0.110 | Đạt 4 corner | [Fitter](../09_reports/architecture_tracking/A1_20261024_075119/mlkem_channel_de10.fit.rpt), [STA](../09_reports/architecture_tracking/A1_20261024_075119/mlkem_channel_de10.sta.rpt) |
| Continuous banked | 27.857 | 38.228 | 28 | 45 | -0.051 | +0.121 | Chưa đạt setup | [Fitter](../09_reports/architecture_tracking/A2_20261025_094051/mlkem_continuous_banked_de10.fit.rpt), [STA](../09_reports/architecture_tracking/A2_20261025_094051/mlkem_continuous_banked_de10.sta.rpt) |
| Banked cycle-opt | 28.952 | 38.307 | 28 | 45 | +0.006 | +0.127 | Đạt 4 corner | [Fitter](../09_reports/architecture_tracking/A4_20261025_latest_before_consolidation/mlkem_continuous_banked_cycle_opt_v2_de10.fit.rpt), [STA](../09_reports/architecture_tracking/A4_20261025_latest_before_consolidation/mlkem_continuous_banked_cycle_opt_v2_de10.sta.rpt) |
| Streaming-Balanced 4BU | 27.176 | 37.911 | 40 | 55 | +0.091 | +0.116 | Đạt 4 corner | [Fitter](../09_reports/architecture_tracking/A5_20261024_063318/mlkem_streaming_balanced_4bu_de10.fit.rpt), [STA](../09_reports/architecture_tracking/A5_20261024_063318/mlkem_streaming_balanced_4bu_de10.sta.rpt) |
| Streaming-Balanced 2BU / 4 bank | 27.017 | 37.370 | 32 | 49 | -0.194 | +0.063 | Chưa đạt setup | [Fitter](../09_reports/architecture_tracking/SB2_20261025_063232/mlkem_streaming_balanced_2bu_de10.fit.rpt), [STA](../09_reports/architecture_tracking/SB2_20261025_063232/mlkem_streaming_balanced_2bu_de10.sta.rpt) |
| Streaming-Balanced 8BU / 16 bank | 28.480 | 38.283 | 56 | 66 | -0.512 | +0.102 | Chưa đạt setup | [Fitter](../09_reports/architecture_tracking/SB8_20261025_063630/mlkem_streaming_balanced_8bu_de10.fit.rpt), [STA](../09_reports/architecture_tracking/SB8_20261025_063630/mlkem_streaming_balanced_8bu_de10.sta.rpt) |

Continuous banked còn setup −0,051 ns tại Slow 0°C; 2BU và 8BU lần lượt còn −0,194 ns và −0,512 ns. Các bản này có regression chức năng PASS, nhưng chưa đạt đầy đủ timing 160 MHz. Full Compilation thành công riêng lẻ không thay thế kết luận STA.

<a id="ntt-intt"></a>
## Chu kỳ NTT INTT và MultiplyNTTs

Mỗi phép biến đổi xử lý đa thức 256 hệ số.

| Kiến trúc | NTT | INTT | MultiplyNTTs | Nhật ký |
|---|---:|---:|---:|---|
| Iterative in-place | 9.984 | 12.800 | 2.433 | [NTT/INTT](../09_reports/iterative_baseline/run_20261023_233228_764/tb_ntt_intt.log), [MultiplyNTTs](../09_reports/iterative_baseline/run_20261023_233228_764/tb_multiply_ntts.log) |
| Streaming ping-pong | 981 | 981 | 145 | [NTT/INTT](../09_reports/streaming_pingpong/run_20261024_014501_279/tb_ntt_intt.log), [MultiplyNTTs](../09_reports/streaming_pingpong/run_20261024_014501_279/tb_multiply_ntts.log) |
| Continuous banked | 905 | 905 | 143 | [NTT/INTT](../09_reports/continuous_banked/run_20261025_085959_024/tb_ntt_intt.log), [MultiplyNTTs](../09_reports/continuous_banked/run_20261025_085959_024/tb_multiply_ntts.log) |
| Banked cycle-opt | 906 | 906 | 143 | [NTT/INTT](../09_reports/continuous_banked_cycle_opt_v2/run_20261024_060413_427/tb_ntt_intt.log), [MultiplyNTTs](../09_reports/continuous_banked_cycle_opt_v2/run_20261024_060413_427/tb_multiply_ntts.log) |
| Streaming-Balanced 4BU | 235 | 235 | 143 | [NTT/INTT](../09_reports/streaming_balanced_4bu/run_20261024_012050_666/tb_ntt_intt.log), [MultiplyNTTs](../09_reports/streaming_balanced_4bu/run_20261024_012050_666/tb_multiply_ntts.log) |
| Streaming-Balanced 2BU / 4 bank | 459 | 459 | 143 | [NTT/INTT](../09_reports/streaming_balanced_2bu/run_20261025_051014_757/tb_ntt_intt.log), [MultiplyNTTs](../09_reports/streaming_balanced_2bu/run_20261025_051014_757/tb_multiply_ntts.log) |
| Streaming-Balanced 8BU / 16 bank | 127 | 127 | 143 | [NTT/INTT](../09_reports/streaming_balanced_8bu/run_20261025_051014_919/tb_ntt_intt.log), [MultiplyNTTs](../09_reports/streaming_balanced_8bu/run_20261025_051014_919/tb_multiply_ntts.log) |

<a id="kem-cycles"></a>
## Chu kỳ KeyGen Encaps và Decaps

Các số dưới đây là phép đo RTL với vector cố định. Thời gian danh nghĩa ở 160 MHz bằng số chu kỳ / 160 (µs); đối với bản chưa đạt setup, đây chỉ là phép quy đổi theo clock mục tiêu.

| Kiến trúc | KeyGen 768 | Encaps 768 | Decaps 768 | KeyGen 1024 | Encaps 1024 | Decaps 1024 | Nhật ký |
|---|---:|---:|---:|---:|---:|---:|---|
| Iterative in-place | 207.580 | 263.538 | 362.654 | 319.198 | 386.366 | 512.312 | [Service core](../09_reports/iterative_baseline/run_20261023_233228_764/tb_mlkem_service_core.log) |
| Streaming ping-pong | 132.970 | 161.797 | 215.221 | 210.566 | 245.499 | 314.462 | [Service core](../09_reports/streaming_pingpong/run_20261024_014501_279/tb_mlkem_service_core.log) |
| Continuous banked | 80.864 | 106.355 | 149.594 | 127.047 | 158.223 | 213.792 | [Service core](../09_reports/continuous_banked/run_20261025_085959_024/tb_mlkem_service_core.log) |
| Banked cycle-opt | 74.911 | 99.061 | 137.891 | 117.985 | 147.564 | 197.125 | [Service core](../09_reports/continuous_banked_cycle_opt_v2/run_20261024_060413_427/tb_mlkem_service_core.log) |
| Streaming-Balanced 4BU | 70.885 | 94.364 | 130.510 | 112.617 | 141.525 | 187.731 | [Service core](../09_reports/streaming_balanced_4bu/run_20261024_012050_666/tb_mlkem_service_core.log) |
| Streaming-Balanced 2BU / 4 bank | 72.229 | 95.932 | 132.974 | 114.409 | 143.541 | 190.867 | [Service core](../09_reports/streaming_balanced_2bu/run_20261025_051014_757/tb_mlkem_service_core.log) |
| Streaming-Balanced 8BU / 16 bank | 70.237 | 93.608 | 129.322 | 111.753 | 140.553 | 186.219 | [Service core](../09_reports/streaming_balanced_8bu/run_20261025_051014_919/tb_mlkem_service_core.log) |

Từ baseline lên 4BU, số chu kỳ NTT/INTT giảm mạnh; sáu thao tác KEM giảm khoảng 63,36–65,85% trên bộ vector này. Tăng tốc ở cấp KEM nhỏ hơn tăng tốc của riêng NTT vì còn Keccak, sampling, mã hóa dữ liệu và chuyển đa thức.

<a id="bu-comparison"></a>
## Khảo sát 2BU 4BU và 8BU

Ba cấu hình dùng cùng vector, SDC, các thiết lập QSF và seed placement 4.

| Chỉ tiêu | 2BU / 4 bank | 4BU / 8 bank | 8BU / 16 bank |
|---|---:|---:|---:|
| ALM | 27.017 | 27.176 | 28.480 |
| DSP | 32 | 40 | 56 |
| M10K | 49 | 55 | 66 |
| Setup min (ns) | -0.194 | 0.091 | -0.512 |

4BU đạt timing trong ba bản fit đã đo, gần giữ nguyên ALM so với 2BU và giảm gần một nửa chu kỳ NTT. Từ 4BU lên 8BU, DSP tăng 40%, M10K tăng 20%, trong khi sáu chu kỳ KEM chỉ giảm khoảng 0,69–0,91%; bản 8BU còn setup âm. Đây là kết luận trên ba bản fit FPGA hiện tại, chưa phải tối ưu toàn cục.

Nguồn: [metadata khảo sát BU](../09_reports/architecture_tracking/BU_COMPILE_RESULTS_20261025.json) và các Fitter/STA/log trong ba hàng tương ứng ở trên. Thuộc tính `latest_a2` trong metadata BU là bản trung gian; kết quả Continuous banked chốt được lấy từ [metadata A2 cuối](../09_reports/architecture_tracking/A2_FINAL_RESULTS_20261025.json).

<a id="fpga-demo"></a>
## Demo trên DE10-Standard

Hai bản ghi dưới đây khớp các mã đối chiếu và ảnh terminal trong báo cáo. Trường thời gian trong JSON giữ ngày đo thực tế; ngày chốt bộ số liệu báo cáo là 25/10/2026.

| Chế độ | Kết quả | Mã kit | KeyGen | Encaps | Decaps | Dữ liệu gốc |
|---|---|---|---:|---:|---:|---|
| ML-KEM-768 | PASS | `1E113F` | 70.801 | 94.400 | 130.426 | [evidence.json](../09_reports/channel/20261021_151314_964463/evidence.json) |
| ML-KEM-1024 | PASS | `812BD5` | 112.719 | 141.546 | 187.833 | [evidence.json](../09_reports/channel/20261021_152227_858743/evidence.json) |

Demo dùng FPGA TRNG + SHAKE256 DRBG, UART 115200 baud và thông điệp 38 byte. PC và FPGA hoán đổi vai trò KeyGen/Encaps/Decaps; AES-256-GCM được kiểm tra hai chiều, kèm từ chối tag sửa và gói phát lại. Chu kỳ có thể chênh nhẹ khi đổi dữ liệu ngẫu nhiên, trong đó có rejection sampling. Phản hồi FPGA báo số chu kỳ core; thời gian toàn lượt còn gồm truyền UART và phần PC.

Các bản ghi chưa lưu SHA256 của SOF được nạp nên không dùng chúng để khẳng định bitstream của demo giống hoàn toàn bản fit được chốt. Kiểm tra sức khỏe RNG PASS là kết quả của mạch kiểm tra trong demo, không thay thế phép đánh giá entropy.

## Phạm vi lưu trữ

Mỗi kiến trúc giữ một snapshot Fitter/STA được chọn, log regression cần đối chiếu và bảng tổng hợp. Các tệp raw giữ nguyên nội dung và có SHA256 trong chỉ mục; bản sao Excel giữ đầy đủ công thức và lịch sử chọn số liệu. Không đưa cache biên dịch, dữ liệu mô phỏng nhị phân, bitstream, PDK hay các bản thử không được chọn vào bộ minh chứng này.

Regression tham chiếu ACVP bằng Python không đồng nghĩa RTL đã được chứng nhận ACVP. Công suất và các chỉ tiêu ASIC hậu layout chưa được đo trong bộ số liệu FPGA này.
