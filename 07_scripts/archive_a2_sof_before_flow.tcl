# Quartus 18.1 PRE_FLOW_SCRIPT_FILE hook. Never deletes a programming file.
# Only the original A2 compile flow is allowed to move its old SOF.
set root [file normalize [file join [file dirname [info script]] ..]]
set expected_dir [file normalize [file join $root 05_quartus continuous_banked]]
set expected_revision mlkem_continuous_banked_de10
if {[llength $quartus(args)] != 3} {
    error "SOF_ARCHIVE: expected flow, project, revision"
}
set flow [lindex $quartus(args) 0]
set project [lindex $quartus(args) 1]
set revision [lindex $quartus(args) 2]
if {$flow ni {compile asm}} {
    puts "SOF_ARCHIVE: skip flow=$flow"
    return
}
if {![string equal -nocase [file normalize [pwd]] $expected_dir] ||
    $revision ne $expected_revision || [file tail $project] ne $expected_revision} {
    error "SOF_ARCHIVE: refusing unexpected project/directory/revision"
}
set sof [file normalize [file join $expected_dir output_files ${revision}.sof]]
set base [file normalize [file join $root backups a2_sof_history]]
file mkdir $base
if {[file exists $sof]} {
    if {![file isfile $sof]} {error "SOF_ARCHIVE: target is not a regular file"}
    set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
    set run_dir [file join $base ${stamp}_[pid]_[clock clicks]]
    file mkdir $run_dir
    set saved [file join $run_dir ${revision}.sof]
    # Rename on the same volume; stop with a clear error if a lock prevents it.
    file rename $sof $saved
    set log [open [file join $run_dir source.txt] {WRONLY CREAT EXCL}]
    puts $log "source=$sof\narchived=$saved\nsize=[file size $saved]\nflow=$flow\nrevision=$revision"
    close $log
    puts "SOF_ARCHIVE: saved=$saved"
} else {
    puts "SOF_ARCHIVE: no previous SOF"
}
# Check creation and writing at the actual destination, then remove ONLY
# this one-byte probe created exclusively by this script.
set probe [open $sof {WRONLY CREAT EXCL}]
fconfigure $probe -translation binary
puts -nonewline $probe "0"
close $probe
if {[file size $sof] != 1} {error "SOF_ARCHIVE: unexpected probe size; leaving file for inspection"}
file delete $sof
puts "SOF_ARCHIVE: destination ready"
