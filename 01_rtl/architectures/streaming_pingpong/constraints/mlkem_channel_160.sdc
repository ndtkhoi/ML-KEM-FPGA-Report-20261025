# Physical input remains 50 MHz; the actual 160 MHz system clock is derived
# from the instantiated PLL (6.250 ns nominal period).
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_pll_clocks
derive_clock_uncertainty

# Ngo vao bat dong bo da qua synchronizer. Khong false-path logic xu ly.
set_false_path -from [get_ports {KEY[*]}]
set_false_path -from [get_ports {SW[*]}]
set_false_path -from [get_ports {UART_RX}]
# Chi FF dau lay mau RO la bat dong bo; FF sau van phai dat timing.
set_false_path -to [get_registers {*u_trng*entropy_meta*}]
set_false_path -to [get_ports {LEDR[*]}]
set_false_path -to [get_ports {HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
set_false_path -to [get_ports {UART_TX}]
