# Read-only project/settings audit. No synthesis/fitting or assignment export.
package require ::quartus::project
set root [file normalize [file join [file dirname [info script]] ..]]
foreach lanes {2 8} {
    set variant streaming_balanced_${lanes}bu
    set dir [file join $root 05_quartus $variant]
    set rtlroot [file normalize [file join $root 01_rtl architectures $variant rtl]]
    cd $dir
    set rev mlkem_${variant}_de10
    project_open $rev -revision $rev
    if {[get_global_assignment -name TOP_LEVEL_ENTITY] ne "mlkem_channel_top" ||
        [get_global_assignment -name DEVICE] ne "5CSXFC6D6F31C6" ||
        [get_global_assignment -name SEED] ne "4"} {error "Wrong top/device/seed: $rev"}
    set count 0
    foreach_in_collection assignment [get_all_global_assignments -name SYSTEMVERILOG_FILE] {
        set f [file normalize [lindex $assignment 2]]
        if {![file isfile $f] || [string first "$rtlroot/" $f] != 0} {error "Non-isolated source: $f"}
        incr count
    }
    if {$count != 36} {error "Expected 36 sources, found $count"}
    set sdc [file normalize [get_global_assignment -name SDC_FILE]]
    set expected [file normalize [file join $root 01_rtl architectures $variant constraints mlkem_channel_160.sdc]]
    if {$sdc ne $expected || ![file isfile $sdc]} {error "Wrong SDC: $sdc"}
    puts "LANE_PROJECT_CHECK: PASS variant=$variant rtl=$count top=mlkem_channel_top device=5CSXFC6D6F31C6 seed=4"
    project_close
}
