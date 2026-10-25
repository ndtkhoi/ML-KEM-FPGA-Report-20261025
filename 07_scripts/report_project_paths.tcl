# Read an existing post-fit database and report detailed timing paths.
# Usage:
#   quartus_sta -t report_project_paths.tcl <project-dir> <revision> <report-name>
package require ::quartus::project
package require ::quartus::sta

if {$argc != 3} {
    post_message -type error "usage: report_project_paths.tcl <project-dir> <revision> <report-name>"
    qexit -error
}

set root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file normalize [lindex $argv 0]]
set revision [lindex $argv 1]
set report_name [lindex $argv 2]
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set out [file join $root 09_reports $report_name timing_paths_$stamp]
file mkdir $out

cd $project_dir
project_open $revision -revision $revision
create_timing_netlist
read_sdc

foreach temperature {85 0} {
    set_operating_conditions -model slow -temperature $temperature -voltage 1100
    update_timing_netlist
    report_timing -setup -npaths 200 -nworst 1 -detail summary \
        -file [file join $out setup_${temperature}_summary.txt]
    report_timing -setup -npaths 40 -nworst 1 -detail full_path -show_routing \
        -file [file join $out setup_${temperature}_full.txt]
    foreach {label pattern} {
        kem {*u_service*u_core*}
        uart {*u_service*}
        record {*u_record*}
        rng {*u_rng*}
        ntt {*u_ntt*}
        multiply {*u_multiply*}
        sampler {*u_sampler*}
        codec {*u_byte_codec*}
        hash {*u_sponge*}
        aes {*u_aes*}
        ghash {*u_ghash*}
    } {
        report_timing -setup -to [get_registers $pattern] -npaths 5 -nworst 1 \
            -detail full_path -show_routing \
            -file [file join $out ${label}_${temperature}_full.txt]
    }
    report_timing -recovery -npaths 10 -nworst 1 -detail full_path -show_routing \
        -file [file join $out recovery_${temperature}_full.txt]
    report_clock_fmax_summary -file [file join $out fmax_${temperature}.txt]
}

delete_timing_netlist
project_close
puts "PROJECT_TIMING_PATHS=$out"
