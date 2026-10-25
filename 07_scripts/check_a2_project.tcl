load_package project
set root [file normalize [file join [file dirname [info script]] ..]]
cd [file join $root 05_quartus continuous_banked]
project_open -revision mlkem_continuous_banked_de10 mlkem_continuous_banked_de10
set expected [file normalize [file join $root 01_rtl architectures continuous_banked rtl]]
set count 0
foreach_in_collection row [get_all_global_assignments -name SYSTEMVERILOG_FILE] {
    set p [file normalize [lindex $row 2]]
    if {![file exists $p] || [string first "$expected/" $p] != 0} {error "Non-A2 or missing RTL: $p"}
    incr count
}
if {$count != 34} {error "Expected 34 A2 RTL sources, got $count"}
foreach_in_collection row [get_all_global_assignments -name SDC_FILE] {
    set p [file normalize [lindex $row 2]]
    if {$p ne [file normalize [file join $root 01_rtl architectures continuous_banked constraints mlkem_channel_160.sdc]]} {error "Unexpected SDC: $p"}
    if {![file exists $p]} {error "Missing SDC"}
}
puts "A2_PROJECT_OPEN_OK RTL=$count TOP=[get_global_assignment -name TOP_LEVEL_ENTITY] DEVICE=[get_global_assignment -name DEVICE] SEED=[get_global_assignment -name SEED]"
project_close -dont_export_assignments
