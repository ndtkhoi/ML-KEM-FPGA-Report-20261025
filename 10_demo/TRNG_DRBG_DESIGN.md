# Thiet ke TRNG/health test/SHAKE256 cho demo ML-KEM

## 1. Duong du lieu

```text
16 ring oscillator Cyclone V
        |
        v
XOR + 2 FF dong bo + lay mau /16
        |
        +--> RCT: phat hien chuoi 0/1 lap qua dai
        +--> APT: dem bit 1 trong cua so 512 mau
        |
        v
pool 512 bit entropy moi
        |
        v
SHAKE256(entropy || previous_state || counter || "MLKR")
        |
        +--> d[255:0]
        +--> z[255:0]
        +--> m[255:0]
        +--> next_state[255:0]
        |
        v
ML-KEM KeyGen -> Encaps -> Decaps -> implicit rejection
```

Moi yeu cau TRNG chi duoc chap nhan khi health test da qua cua so khoi
dong va pool co du 512 bit moi. Pool cu duoc xoa ngay sau khi khoi SHAKE
nhan du lieu. Sau khi UART phat xong bao cao, top xoa cac vector dau vao,
shared secret va quet xoa RAM byte/da thuc nhu phien ban truoc.

## 2. Cac file RTL

| File | Vai tro |
|---|---|
| `01_rtl/random/fpga_ro_entropy.sv` | 16 RO vat ly, dong bo va lay mau bit tho |
| `01_rtl/random/entropy_health.sv` | RCT, APT, startup gate va alarm latched |
| `01_rtl/random/shake256_drbg.sv` | dieu hoa/sinh 96 byte va cap nhat state |
| `01_rtl/random/mlkem_random_manager.sv` | thu pool, dieu khien generate/reseed/zeroize |
| `01_rtl/top/mlkem_channel_top.sv` | chon fixed/TRNG, LED/HEX va ghep ML-KEM/UART/channel |

`fpga_ro_entropy.sv` co hai nhanh. Quartus dinh nghia macro `SYNTHESIS`
va tao cac primitive `cyclonev_lcell_comb`. ModelSim khong mo phong duoc
jitter vat ly nen dung LFSR de kiem tra giao tiep/FSM; log mo phong khong
duoc dung de ket luan chat luong entropy tren kit.

## 3. Tham so prototype

| Tham so | Gia tri |
|---|---:|
| So ring oscillator | 16 |
| So LUT dao moi ring | 3 |
| He so chia lay mau | 48 chu ky clock he thong 150 MHz (320 ns/mau) |
| RCT limit | 32 bit giong nhau lien tiep |
| APT window | 512 bit |
| APT PASS | 176..336 bit 1 |
| Entropy moi cho moi generate | 512 bit |
| Dau ra moi generate | 768 bit = 96 byte `d || z || m` |

UART bao `RNG_APT_ONES_HEX`, tong mau, so lan reseed, chu ky generate va
`RNG_VECTOR_CRC32`. Script demo yeu cau nhieu lan co CRC va shared secret
khac nhau. Cac chi so nay la bang chung truc quan ve luong du lieu va
health test; CRC khong phai phep do min-entropy.

## 4. Canh bao Quartus du kien

Timing Analyzer co the bao `Found combinational loop` cho 16 vong trong
`u_trng|g_ro[...]`. Day la cau truc vat ly co chu y cua ring oscillator.
Khong duoc bo qua neu ten node nam ngoai `u_trng`; vong to hop trong core
ML-KEM van la loi thiet ke.

QSF tat `REMOVE_REDUNDANT_LOGIC_CELLS` va RTL gan thuoc tinh `keep` de
giu cac LUT. Sau build, can mo hierarchy/resource report va xac nhan
`fpga_ro_entropy:u_trng` van su dung logic. SDC chi false-path den FF
`entropy_meta` dau tien; FF thu hai va tat ca logic health/DRBG/ML-KEM van
duoc phan tich timing voi CLOCK_50.

## 5. Duong sang ASIC layout/GDS

Ba khoi health test, SHAKE256 generator va random manager la RTL dong bo,
khong phu thuoc FPGA. Khoi duy nhat phu thuoc Cyclone V la
`fpga_ro_entropy.sv`. Khi lam ASIC, thay khoi nay bang entropy macro cua
cong nghe thu vien, giu nguyen giao dien `raw_bit/raw_valid`. Ring
oscillator ASIC can `dont_touch`, floorplan, kiem tra DRC/LVS va do entropy
tren silicon; RTL FPGA khong the tu dong bien thanh TRNG da duoc chung
nhan trong file GDS.

## 6. Pham vi tuyen bo

Day la prototype RBG cho do an: co nguon nhieu vat ly tren FPGA, health
test online, dieu hoa SHAKE256, reseed moi yeu cau, zeroization va telemetry
UART. Chua tuyen bo chung nhan NIST SP 800-90B/90A; de tien toi muc do do
can thu chuoi bit tho tren nhieu kit, nhiet do/dien ap khac nhau, uoc luong
min-entropy va chon lai nguong theo mo hinh nguon.
