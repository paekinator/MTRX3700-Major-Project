# Requires CLOCK_50 and PCLK in the same set_clock_groups group so Quartus
# 18.1 Standard does not silently discard the Gray maximum-skew constraints.
# They remain asynchronous hardware domains. Every actual path between them
# is either physically bounded below or one of five single-bit first stages.
foreach spec {
 {writeGray 9}
 {readGray 9}
 {timeGray 32}
} {
 set stem [lindex $spec 0]
 set count [lindex $spec 1]
 set fromRegs [get_registers [format {*cameraBridge*|%s[*]} $stem]]
 set toRegs [get_registers [format {*cameraBridge*|%sMeta[*]} $stem]]
 if {[get_collection_size $fromRegs] != $count || [get_collection_size $toRegs] != $count} {
  error "Expected $count launch/first-stage Gray registers for $stem"
 }
 set_max_skew -from $fromRegs -to $toRegs 20.000
 set_max_delay -from $fromRegs -to $toRegs 20.000
 # Only the first metastability-catching stages see an unrelated clock.
 # Zero min-delay includes unrelated clock insertion skew in Quartus 18.1.
 # Its hold-only false path ALSO disables max-skew analysis (verified in the
 # installed tool), so use the vendor DCFIFO -100 ns min-delay convention.
 # This is NOT a functional hold margin: coherence is proved by the 20 ns
 # physical net/skew bounds, with two-stage synchronisers. Retain the stricter
 # 20 ns max-delay as well. Meta->Sync keeps ordinary setup and hold checks.
 # See Altera FIFO IP User Guide, SDC Commands, table 14 (683522/25.1.1).
 set_net_delay -max -from $fromRegs -to $toRegs 20.000
 set_min_delay -from $fromRegs -to $toRegs -100.000
}

# Bundled payload is held until the destination acknowledges it. Bound its
# propagation below one destination clock, before the synchronised request can
# cause capture; do not mark the entire data bus as an unbounded false path.
# There is no same-edge hold relationship between these asynchronous clocks.
# heldBusCdc keeps heldData unchanged until the capture acknowledgement has
# crossed back through two source-clock stages. Only the payload's artificial
# inter-clock hold check is excluded. Its 20 ns setup bound remains active;
# synchroniser stage-to-stage setup/hold and the Gray constraints above remain
# unchanged. A zero set_min_delay would still include unrelated clock insertion
# delays and made the router add large, unnecessary payload delay chains.
foreach instance {resultToCamera *cameraBridge*|requestCdc} {
 set payloadFrom [get_registers "${instance}|heldData\[*\]"]
 set payloadTo [get_registers "${instance}|destinationData\[*\]"]
 if {[get_collection_size $payloadFrom] == 0 || [get_collection_size $payloadTo] == 0} {
  error "Missing bundled payload for $instance"
 }
 set_max_delay -from $payloadFrom -to $payloadTo 20.000
 # The physical data net bound is independent of either clock's insertion
 # delay. It is retained even though same-edge asynchronous hold is excluded.
 set_net_delay -max -from $payloadFrom -to $payloadTo 20.000
 set_false_path -hold -from $payloadFrom -to $payloadTo
 set_false_path -from [get_registers "${instance}|requestToggle"] -to [get_registers "${instance}|requestSync\[0\]"]
 set_false_path -from [get_registers "${instance}|acknowledgeToggle"] -to [get_registers "${instance}|acknowledgeSync\[0\]"]
}
# VGA is in the existing asynchronous PLL clock group, so ordinary setup/hold
# checks are intentionally cut. The held mailbox still needs a physical data
# propagation bound before its two-stage request can enable destination capture.
# Quartus18.1 report_net_delay honours this independent net constraint even on
# clock-group-cut paths (verified against the retained fitted5633257e netlist).
# 20ns is stricter than one40ns destination cycle; no clock-group exception or
# existing Gray / camera mailbox setup / hold constraint is changed here.
set displayPayloadFrom [get_registers {resultToDisplay|heldData[*]}]
set displayPayloadTo [get_registers {resultToDisplay|destinationData[*]}]
if {[get_collection_size $displayPayloadFrom] == 0 || [get_collection_size $displayPayloadTo] == 0} {
 error "Missing bundled payload for resultToDisplay"
}
set_net_delay -max -from $displayPayloadFrom -to $displayPayloadTo 20.000
set_false_path -from [get_registers {*cameraBridge*|sourceFault}] -to [get_registers {*cameraBridge*|faultSync[0]}]

# Only Intel's three serial TAP boundary ports are excluded from user I/O STA.
if {[get_collection_size [get_ports -nowarn {altera_reserved_tdi altera_reserved_tms}]] > 0} {
 set_false_path -from [get_ports {altera_reserved_tdi altera_reserved_tms}]
}
if {[get_collection_size [get_ports -nowarn {altera_reserved_tdo}]] > 0} {
 set_false_path -to [get_ports {altera_reserved_tdo}]
}
