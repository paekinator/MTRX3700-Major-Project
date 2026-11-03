`timescale 1ns/1ps
module memberBDebug_tb;
    logic clk=0;
    always #10 clk=~clk;
    logic reset=1;
    logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] debugWords;
    import perception_pkg::*;
    logic commandValid,commandReady=0;
    targetOperation_t commandOperation;
    markerType_t commandMarkerType;
    logic [3:0] commandDigit;
    queryResult_t queryResult='0;
    logic queryResultValid=0,queryResultReady,queryBusy=0;
    logic calibrateArm,speechArm,autoCycle;
    logic interactionArmReady=1;
    logic [1:0] orientationProfile;
    integer calPulses=0,speechPulses=0,commandTransfers=0,queryTransfers=0;
    logic hostToggle=0;
    memberBDebug #(.BUILD_ID(32'h12345678)) dut(.*);
    always @(posedge clk) if(!reset)begin
        if(calibrateArm)calPulses=calPulses+1;
        if(speechArm)speechPulses=speechPulses+1;
        if(commandValid && commandReady)commandTransfers=commandTransfers+1;
        if(queryResultValid && queryResultReady)queryTransfers=queryTransfers+1;
    end
    task automatic waitClocks(input integer clocks);
        repeat(clocks)@(negedge clk);
    endtask
    task automatic issue(input logic [3:0] opcode,input logic [5:0] value);
        begin
            hostToggle=!hostToggle;
            dut.probes.src_jtag={hostToggle,3'd0,opcode,18'd0,value};
        end
    endtask
    task automatic waitAck;
        integer timeoutCount;
        begin
            timeoutCount=0;
            while(dut.probeWord[47]!==hostToggle && timeoutCount<100)begin
                @(negedge clk);timeoutCount=timeoutCount+1;
            end
            if(dut.probeWord[47]!==hostToggle)$fatal(1,"Command acknowledgement timeout");
        end
    endtask
    initial begin
        debugWords=0;
        for(int i=0;i<perception_pkg::DEBUG_WORD_COUNT;i++)debugWords[i*32+:32]=32'h10000000+i;
        waitClocks(4);reset=0;waitClocks(8);
        if($bits(queryResult_t)!=141 || $bits(targetRequest_t)!=24 || $bits(targetReport_t)!=141)
            $fatal(1,"Public v3 wire widths differ");
        if(dut.probeWord[127:64]!==64'h4244424712345678 || dut.probeWord[63:48]!=={8'(perception_pkg::DEBUG_SCHEMA_VERSION),8'd3} || dut.probeWord[39:32]!==8'(perception_pkg::DEBUG_WORD_COUNT))
            $fatal(1,"BDBG/build/schema header mismatch");
        // A transient entire source word must not be accepted.
        dut.probes.src_jtag=32'h81000003;waitClocks(1);
        dut.probes.src_jtag=0;waitClocks(8);
        if(commandValid || dut.ackToggle)$fatal(1,"Unstable source accepted");
        issue(1,6'h13);waitClocks(8);
        if(!commandValid || commandOperation!=TARGET_SELECT || commandMarkerType!=MARKER_BAY || commandDigit!=3 || dut.ackToggle)
            $fatal(1,"SELECT payload/early ack");
        waitClocks(7);
        if(!commandValid || commandDigit!=3 || dut.ackToggle)$fatal(1,"Stalled command changed");
        commandReady=1;waitAck();waitClocks(2);commandReady=0;
        if(commandTransfers!=1 || commandValid)$fatal(1,"SELECT duplicate transfer");
        issue(2,15);waitClocks(8);
        if(!commandValid || commandOperation!=TARGET_CLEAR || !dut.ackToggle)$fatal(1,"CLEAR lost or acknowledged before ready");
        commandReady=1;waitAck();waitClocks(2);commandReady=0;
        if(commandTransfers!=2)$fatal(1,"CLEAR transfer count");
        issue(3,0);waitAck();waitClocks(5);
        if(calPulses!=1)$fatal(1,"Calibration arm is not one pulse");
        issue(4,0);waitAck();waitClocks(5);
        if(speechPulses!=1)$fatal(1,"Speech arm is not one pulse");
        interactionArmReady=0;
        issue(3,0);waitAck();waitClocks(5);
        if(!dut.commandError||dut.rejectionReason!=2||calPulses!=2)
            $fatal(1,"Busy calibration must return action rejection once");
        interactionArmReady=1;
        issue(5,0);waitAck();waitClocks(2);
        debugWords='1;
        for(int index=0;index<perception_pkg::DEBUG_WORD_COUNT;index++)begin
            dut.probes.src_jtag={hostToggle,3'd0,4'd5,8'd0,8'(index),8'd0};
            waitClocks(8);
            if(dut.probeWord[31:0]!==32'h10000000+index)$fatal(1,"Frozen word changed/index mismatch %0d",index);
        end
        dut.probes.src_jtag={hostToggle,3'd0,4'd5,8'd0,8'd255,8'd0};waitClocks(8);
        if(dut.probeWord[31:0]!==0)$fatal(1,"Out-of-range address leaked data");
        issue(6,2);waitAck();waitClocks(2);
        if(orientationProfile!=2)$fatal(1,"Orientation command failed");
        issue(7,1);waitAck();waitClocks(2);
        if(!autoCycle)$fatal(1,"Auto cycle command failed");
        issue(1,6'h19);waitAck();waitClocks(2);
        if(commandValid || !dut.probeWord[46])$fatal(1,"Invalid bay was accepted");
        // Typed SELECT keeps red1 separate from blue1, and BJ is REFERENCE/F.
        for(int item=0;item<2;item++)begin
            issue(1,item==0?6'h21:6'h3f);waitClocks(8);
            if(!commandValid || commandMarkerType!=(item==0?MARKER_FUNCTION:MARKER_REFERENCE) ||
                    commandDigit!=(item==0?1:15))$fatal(1,"Typed SELECT identity lost");
            commandReady=1;waitAck();waitClocks(2);commandReady=0;
        end
        // A pending query must reject a second request without using Csim's
        // single held command slot. Tracking SELECT remains independent.
        queryBusy=1;issue(8,0);waitAck();waitClocks(2);
        if(commandValid || !dut.commandError || dut.rejectionReason!=2 || !dut.probeWord[40])
            $fatal(1,"Busy LIST was queued or did not report actual busy");
        queryBusy=0;waitClocks(3);
        if(!dut.probeWord[40])$fatal(1,"Action busy metadata changed without another transaction");
        issue(8,0);waitClocks(8);
        if(!commandValid || commandOperation!=TARGET_LIST || commandMarkerType!=MARKER_NONE || commandDigit!=15)
            $fatal(1,"LIST command malformed");
        commandReady=1;waitAck();waitClocks(2);commandReady=0;
        issue(9,6'h21);waitClocks(8);
        if(!commandValid || commandOperation!=TARGET_GET || commandMarkerType!=MARKER_FUNCTION || commandDigit!=1)
            $fatal(1,"GET command malformed");
        commandReady=1;waitAck();waitClocks(2);commandReady=0;
        // READ_QUERY does not ack before ready/valid transfer, consumes exactly
        // one result and freezes its own eight-word packet in the existing RAM.
        for(int item=0;item<16;item++)begin
            queryResult='0;queryResult.requestTag=16'h7788;queryResult.frameId=16'hffff;
            queryResult.captureStartUs=32'hfffffff0;queryResult.configVersion=8;
            queryResult.reason=QUERY_OK;queryResult.count=16;queryResult.index=4'(item);
            queryResult.last=(item==15);queryResult.markerType=MARKER_BAY;queryResult.digit=1;
            queryResult.centreU=100;queryResult.centreV=150;queryResult.boxWidth=12;queryResult.boxHeight=30;queryResult.quality=200;
            queryBusy=1;queryResultValid=1;issue(10,0);
            while(!queryResultReady)@(negedge clk);
            if(dut.ackToggle===hostToggle)$fatal(1,"READ_QUERY acknowledged before actual handshake");
            waitAck();waitClocks(2);queryResultValid=0;
            if(queryTransfers!=item+1 || dut.frozenWords[0+:32]!=32'h51525033 ||
                    dut.frozenWords[32+:160]!={19'd0,queryResult} ||
                    dut.frozenWords[192+:32]!=32'h12345678 || dut.frozenWords[224+:32]!=32'h00000308)
                $fatal(1,"QRP3 packet/transfer mismatch %0d",item);
            queryResult='1;
            dut.probes.src_jtag={hostToggle,3'd0,4'd10,8'd0,8'd0,8'd0};waitClocks(8);
            if(dut.probeWord[31:0]!=32'h51525033 || queryTransfers!=item+1)
                $fatal(1,"Address read consumed or changed a query result");
            // A QRP3 packet has eight words; prior status-bank contents must
            // not leak through its unused tail, even though storage is reused.
            for(int address=8;address<perception_pkg::DEBUG_WORD_COUNT;address++)begin
                dut.probes.src_jtag={hostToggle,3'd0,4'd10,8'd0,8'(address),8'd0};
                waitClocks(8);
                if(dut.probeWord[31:0]!==0 || queryTransfers!=item+1)
                    $fatal(1,"Query tail was nonzero or consumed another packet at %0d",address);
            end
        end
        // No valid result is explicit BUSY, with current query busy frozen in
        // metadata. The previous successful packet is never silently replaced.
        issue(10,0);waitAck();waitClocks(2);
        if(!dut.commandError || dut.rejectionReason!=2 || !dut.probeWord[40] || queryTransfers!=16 ||
                dut.frozenWords[0+:32]!=32'h51525033)$fatal(1,"Pending query READ semantics changed");
        queryBusy=0;issue(10,0);waitAck();waitClocks(2);
        if(!dut.commandError || dut.probeWord[40] || queryTransfers!=16)$fatal(1,"Idle drain termination not explicit");
        issue(5,0);waitAck();waitClocks(2);
        if(dut.probeWord[46] || dut.probeWord[31:0]!==32'hffffffff)$fatal(1,"Refresh/error clear failed");
        for(int address=8;address<perception_pkg::DEBUG_WORD_COUNT;address++)begin
            dut.probes.src_jtag={hostToggle,3'd0,4'd5,8'd0,8'(address),8'd0};
            waitClocks(8);
            if(dut.probeWord[31:0]!==32'hffffffff)
                $fatal(1,"Status refresh left query-tail mask active at %0d",address);
        end
        // A stable old toggle remains in ISSP across reset; do not replay it.
        reset=1;waitClocks(3);reset=0;waitClocks(10);
        if(commandValid || queryResultReady || autoCycle || orientationProfile!=0 || calibrateArm || speechArm || dut.frozenWords!='0)
            $fatal(1,"Reset replayed an old JTAG command");
        $display("PASS memberBDebug_tb: coherent commands, backpressure, %0d frozen words, reset",perception_pkg::DEBUG_WORD_COUNT);
        $finish;
    end
    initial begin #1000000;$fatal(1,"Global timeout");end
endmodule
