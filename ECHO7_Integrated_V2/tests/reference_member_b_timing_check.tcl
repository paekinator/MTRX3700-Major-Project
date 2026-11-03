# Post-fit timing gate, checked against local Quartus 18.1 Tcl help.
load_package sta
load_package report
if {[llength $argv] < 2 || [llength $argv] > 3 || ([llength $argv] == 3 && [lindex $argv 2] ne "--post-map-audit")} {
    error "usage: timing_check.tcl project output.json ?--post-map-audit?"
}
set project [lindex $argv 0]
set output [lindex $argv 1]
set postMap [expr {[llength $argv] == 3}]
project_open $project
if {$postMap} {create_timing_netlist -post_map} else {create_timing_netlist}
read_sdc
update_timing_netlist
set fail 0
set records {}
set skewRecords {}
set grayRecords {}
set payloadRecords {}
set netRecords {}
set clockNames {}
foreach_in_collection clock [get_clocks *] { lappend clockNames [get_clock_info $clock -name] }
foreach required {CLOCK_50 PCLK} {
    if {$required ni $clockNames} { set fail 1; post_message -type error "required clock absent: $required" }
}
# Evaluate every available analysis corner, not only the last fitter report.
foreach_in_collection corner [get_available_operating_conditions] {
    set_operating_conditions $corner
    update_timing_netlist
    set cornerName [get_operating_conditions_info $corner -model]
    if {$project eq "PartBDebug"} {
        foreach spec {{writeGray 9} {readGray 9} {timeGray 32}} {
            lassign $spec stem expected
            set fromRegs [get_registers [format {*cameraBridge*|%s[*]} $stem]]
            set toRegs [get_registers [format {*cameraBridge*|%sMeta[*]} $stem]]
            set sourceCount [get_collection_size $fromRegs]
            set destinationCount [get_collection_size $toRegs]
            set timedCount [get_collection_size [get_timing_paths -setup -from $fromRegs -to $toRegs -npaths 100]]
            set falseCount [get_collection_size [get_timing_paths -setup -false_path -from $fromRegs -to $toRegs -npaths 100]]
            set firstStageHold [get_collection_size [get_timing_paths -hold -from $fromRegs -to $toRegs -npaths 100]]
            set syncRegs [get_registers [format {*cameraBridge*|%sSync[*]} $stem]]
            set syncSetup [get_collection_size [get_timing_paths -setup -from $toRegs -to $syncRegs -npaths 100]]
            set syncHold [get_collection_size [get_timing_paths -hold -from $toRegs -to $syncRegs -npaths 100]]
            if {$sourceCount != $expected || $destinationCount != $expected || $timedCount != $expected || $falseCount != 0 || $firstStageHold != $expected || $syncSetup != $expected || $syncHold != $expected} {
                set fail 1
                post_message -type error "Gray CDC mapping mismatch $stem: expected=$expected source=$sourceCount destination=$destinationCount timed=$timedCount cutSetup=$falseCount asyncHold=$firstStageHold syncSetup=$syncSetup syncHold=$syncHold"
            }
            lappend grayRecords "{\"corner\":\"$corner\",\"name\":\"$stem\",\"expected\":$expected,\"sourceCount\":$sourceCount,\"destinationCount\":$destinationCount,\"timedPathCount\":$timedCount,\"falsePathCount\":$falseCount,\"relaxedAsyncHoldCount\":$firstStageHold,\"synchroniserSetupCount\":$syncSetup,\"synchroniserHoldCount\":$syncHold}"
        }
    }
    if {$project eq "PartBDebug"} {
        # A held asynchronous mailbox has no same-edge hold relationship.
        # Prove that excluding that relationship did not cut its setup bound.
        foreach instance {resultToCamera *cameraBridge*|requestCdc} {
            set fromRegs [get_registers "${instance}|heldData\[*\]"]
            set toRegs [get_registers "${instance}|destinationData\[*\]"]
            set expected [get_collection_size $toRegs]
            # Schema6 has5120 payload bits before constant pruning. The query
            # cap must exceed that width or a valid mapping can look truncated.
            set timed [get_collection_size [get_timing_paths -setup -from $fromRegs -to $toRegs -npaths 8192]]
            set cutSetup [get_collection_size [get_timing_paths -setup -false_path -from $fromRegs -to $toRegs -npaths 8192]]
            set hold [get_collection_size [get_timing_paths -hold -from $fromRegs -to $toRegs -npaths 8192]]
            if {$expected == 0 || $timed != $expected || $cutSetup != 0 || $hold != 0} {
                set fail 1
                post_message -type error "Payload CDC coverage failed $instance: expected=$expected setup=$timed cutSetup=$cutSetup hold=$hold"
            }
            lappend payloadRecords "{\"corner\":\"$corner\",\"instance\":\"$instance\",\"destinationCount\":$expected,\"setupPathCount\":$timed,\"cutSetupCount\":$cutSetup,\"sameEdgeHoldCount\":$hold}"
        }
        # The display mailbox is intentionally in the PLL asynchronous clock
        # group. Prove its actual mapped endpoints are cut from ordinary setup,
        # then require every endpoint in the independent physical net report.
        # Do not compare the nominal5120 bits: synthesis prunes unused/constant
        # fields and may duplicate launching registers for fanout.
        set displayFrom [get_registers {resultToDisplay|heldData[*]}]
        set displayTo [get_registers {resultToDisplay|destinationData[*]}]
        set displayExpected [get_collection_size $displayTo]
        set displayTimed [get_collection_size [get_timing_paths -setup -from $displayFrom -to $displayTo -npaths 8192]]
        set displayCutPaths [get_timing_paths -setup -false_path -from $displayFrom -to $displayTo -npaths 8192]
        set displayCut [get_collection_size $displayCutPaths]
        set displayExpectedNames {}
        foreach_in_collection node $displayTo {lappend displayExpectedNames [get_node_info $node -name]}
        set displayExpectedNames [lsort -unique $displayExpectedNames]
        set displayCutNames {}
        foreach_in_collection path $displayCutPaths {lappend displayCutNames [get_node_info [get_path_info $path -to] -name]}
        set displayCutNames [lsort -unique $displayCutNames]
        if {$displayExpected == 0 || $displayExpected >= 8192 || $displayTimed != 0 ||
            $displayCut != $displayExpected || $displayCutNames ne $displayExpectedNames} {
            set fail 1
            post_message -type error "Display CDC mapping mismatch: expected=$displayExpected setup=$displayTimed cutSetup=$displayCut"
        }
        set netFile [file join [file dirname $output] "net_delay_$corner.txt"]
        report_net_delay -nworst 8192 -file $netFile
        # Standard Edition writes a table but does not return the path/slack
        # pair returned by report_max_skew. Check all three Gray and three
        # bundled-payload physical delay bounds independently of clock phase.
        set netHandle [open $netFile r]
        set netText [read $netHandle]
        close $netHandle
        set netCount 0
        set netSlack 1e9
        set activeNetGroup ""
        set netGroups [dict create writeGray 0 readGray 0 timeGray 0 resultToCamera 0 requestCdc 0 resultToDisplay 0]
        set displayNetNames {}
        foreach line [split $netText "\n"] {
            set fields [split $line ";"]
            if {[llength $fields] != 9} {continue}
            set rowName [string trim [lindex $fields 1]]
            if {$rowName ne "set_net_delay" && $rowName ne "--"} {continue}
            set slack [string trim [lindex $fields 2]]
            set required [string trim [lindex $fields 3]]
            set actual [string trim [lindex $fields 4]]
            set fromName [string trim [lindex $fields 5]]
            set toName [string trim [lindex $fields 6]]
            if {![string is double -strict $slack] || ![string is double -strict $required] ||
                ![string is double -strict $actual]} {error "Non-numeric net-delay result: $line"}
            if {$required != 20.0 || $slack < 0 || $actual > 20.0 || [string trim [lindex $fields 7]] ne "max"} {set fail 1}
            if {$rowName eq "set_net_delay"} {
                incr netCount
                set activeNetGroup ""
                foreach spec {{writeGray {|writeGray[*]}} {readGray {|readGray[*]}} {timeGray {|timeGray[*]}}
                              {resultToCamera {resultToCamera|heldData[*]}} {requestCdc {requestCdc|heldData[*]}}
                              {resultToDisplay {resultToDisplay|heldData[*]}}} {
                    if {[string first [lindex $spec 1] $fromName] >= 0} {set activeNetGroup [lindex $spec 0]}
                }
                if {$activeNetGroup eq ""} {error "Unexpected net-delay constraint: $line"}
                dict incr netGroups $activeNetGroup
                if {$slack < $netSlack} {set netSlack $slack}
            } elseif {$activeNetGroup eq "resultToDisplay"} {
                lappend displayNetNames $toName
            }
        }
        if {$netCount != 6} {error "Expected three Gray and three payload net bound summaries; found $netCount"}
        dict for {group count} $netGroups {
            if {$count != 1} {error "Expected exactly one net-delay constraint for $group; found $count"}
        }
        set displayNetNames [lsort -unique $displayNetNames]
        set displayNetCount [llength $displayNetNames]
        if {$displayNetNames ne $displayExpectedNames} {
            set fail 1
            post_message -type error "Display net constraint missed/misidentified endpoints: expected=$displayExpected reported=$displayNetCount"
        }
        lappend payloadRecords "{\"corner\":\"$corner\",\"instance\":\"resultToDisplay\",\"destinationCount\":$displayExpected,\"setupPathCount\":$displayTimed,\"cutSetupCount\":$displayCut,\"physicalNetEndpointCount\":$displayNetCount,\"physicalNetCoverageComplete\":[expr {$displayNetNames eq $displayExpectedNames ? "true" : "false"}]}"
        lappend netRecords "{\"corner\":\"$corner\",\"pathCount\":$netCount,\"worstSlackNs\":$netSlack}"
    }
    foreach check {setup hold recovery removal} {
        set worst null
        foreach_in_collection path [get_timing_paths -$check -npaths 1] {
            set slack [get_path_info $path -slack]
            set worst $slack
            if {$slack < 0} { set fail 1 }
        }
        lappend records "{\"corner\":\"$corner\",\"model\":\"$cornerName\",\"check\":\"$check\",\"worstSlackNs\":$worst}"
    }
    # Quartus 18.1 returns {number-of-paths worst-slack}; get_timing_paths
    # does not expose maximum-skew paths. Keep each real corner's full report.
    # Preserve actual chain identity; numerical MTBF is not this timing gate.
    set syncFile [file join [file dirname $output] "synchronisers_$corner.txt"]
    report_metastability -nchains 5000 -file $syncFile
    set skewFile [file join [file dirname $output] "max_skew_$corner.txt"]
    set skewResult [report_max_skew -file $skewFile -npaths 1 -detail full_path]
    set skewCount [lindex $skewResult 0]
    set skewSlack [lindex $skewResult 1]
    if {$skewCount > 0} {
        if {![string is double -strict $skewSlack]} { error "max-skew result is not numeric: $skewResult" }
        if {$skewSlack < 0} { set fail 1 }
    } else {
        set skewSlack null
        if {$project eq "PartBDebug"} { set fail 1; post_message -type error "B Gray CDC max-skew paths were not analysed" }
    }
    if {$project eq "PartBDebug" && $skewCount != 6} {
        set fail 1
        post_message -type error "Expected six earliest/latest reports for three Gray maximum-skew constraints; found $skewCount"
    }
    lappend skewRecords "{\"corner\":\"$corner\",\"pathCount\":$skewCount,\"worstSlackNs\":$skewSlack}"
}
set ucpFile [file join [file dirname $output] unconstrained.txt]
report_ucp -file $ucpFile
# The Python gate separately rejects nonzero unconstrained path counts.
set clocksJson {}
foreach name $clockNames { lappend clocksJson "\"[string map {\\ \\\\ \" \\\"} $name]\"" }
set f [open $output w]
puts $f "{\"schema\":\"echo7-timing-v2\",\"analysisStage\":\"[expr {$postMap ? "POST_MAP_CONSTRAINT_AUDIT" : "POST_FIT"}]\",\"status\":\"[expr {$fail ? "FAIL" : "PASS"}]\",\"clocks\":\[[join $clocksJson ,]\],\"checks\":\[[join $records ,]\],\"maxSkew\":\[[join $skewRecords ,]\],\"grayMappings\":\[[join $grayRecords ,]\],\"payloadMappings\":\[[join $payloadRecords ,]\],\"netDelay\":\[[join $netRecords ,]\]}"
close $f
delete_timing_netlist
project_close
if {$fail} { exit 1 }
