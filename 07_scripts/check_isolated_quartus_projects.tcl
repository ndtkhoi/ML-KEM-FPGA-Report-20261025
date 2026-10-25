load_package project
set root [file normalize [file join [file dirname [info script]] ..]]
foreach qsf [glob -directory [file join $root 05_quartus] */*.qsf] {
    cd [file dirname $qsf]
    set revision [file rootname [file tail $qsf]]
    project_open -revision $revision $revision
    set rtl [get_all_global_assignments -name SYSTEMVERILOG_FILE]
    set sdc [get_all_global_assignments -name SDC_FILE]
    set count 0
    foreach_in_collection row $rtl {
        incr count
        set path [lindex $row 2]
        if {![file exists $path]} {error "RTL missing: $path"}
        if {![string match */architectures/*/rtl/* $path]} {error "Non-isolated RTL: $path"}
    }
    foreach_in_collection row $sdc {
        set path [lindex $row 2]
        if {![file exists $path]} {error "SDC missing: $path"}
        if {![string match */architectures/*/constraints/* $path]} {error "Non-isolated SDC: $path"}
    }
    puts "ISOLATION_PROJECT_OPEN_OK $revision RTL_ASSIGNMENTS=$count"
    project_close -dont_export_assignments
}
puts "ALL_ISOLATED_PROJECTS_OPEN_OK"
