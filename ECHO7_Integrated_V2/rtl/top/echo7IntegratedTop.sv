// Derived from perceptionDemoTop.sv; inherited camera attribution: see OWNERS.md.
// Integrated robot: unchanged Member B pipeline + validated Member C modules.
// Sole target-request owner: chassis.control_u.adapter. No memberCSimulator.
// KEY1 retains both the visual frame snapshot and the Member C HEX page action.
`include "memberBBuildId.svh"
module echo7IntegratedTop #(
    parameter int CAMERA_FPS = 25, // Keep the verified 20 MHz PCLK setting.
    parameter int LEFT_POLARITY = -1, RIGHT_POLARITY = -1, TURN_SIGN = 1
) (
    input  wire        CLOCK_50,
    output wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    input wire IRDA_RXD,
    input  wire [3:0]  KEY,
    input  wire [9:0]  SW, // SW0/1 diagnostics; SW8 perspective bypass; SW9 pure camera.
    output wire [9:0]  LEDR,
    inout  wire [35:0] GPIO_1,
    output wire        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N,
    output wire [7:0]  VGA_R, VGA_G, VGA_B
);
    // Match the physical sensor clock to PartBDebug.sdc. This undefined-module
    // elaboration guard also applies in synthesis (same pattern as ov7670_config).
    generate if (CAMERA_FPS != 25) begin : requires_25fps
        MemberB_requires_CAMERA_FPS_25_and_20MHz_PCLK stop_here ();
    end endgenerate
    // ---- clocks ------------------------------------------------------------------------------
    wire clk_25, pll_locked;
    wire clk_10;
    video_pll video_pll_u (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(clk_25), .outclk_1(clk_10), .locked(pll_locked));
    wire sccb_clk;
    clock_divider #(.DIVISOR(250)) sccb_clk_u (.clk_in(clk_25), .clk_out(sccb_clk));   // 100 kHz

    // ---- reset: KEY0 (active low), synchronised into each domain ---------------------------------
    logic [1:0] rs25 = '1, rs_sccb = '1;
    always_ff @(posedge clk_25)   rs25    <= {rs25[0],    ~KEY[0] | ~pll_locked};
    always_ff @(posedge sccb_clk) rs_sccb <= {rs_sccb[0], ~KEY[0]};
    wire reset25 = rs25[1], reset_sccb = rs_sccb[1];
    // Independent physical switch bits control display options only. Each bit
    // crosses through two registers in the VGA domain; no multi-bit payload or
    // camera configuration is conveyed by these asynchronous switches.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [1:0] switchMeta=0,switchSync=0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic rawVgaMeta=0,rawVgaSync=0;
    always_ff @(posedge clk_25) begin
        if(reset25) begin switchMeta<=0;switchSync<=0;end
        else begin switchMeta<=SW[1:0];switchSync<=switchMeta;end
        if(reset25)begin rawVgaMeta<=0;rawVgaSync<=0;end
        else begin rawVgaMeta<=SW[9];rawVgaSync<=rawVgaMeta;end
    end

    // ---- the camera's pins ---------------------------------------------------------------------
    wire       cam_pclk  = GPIO_1[21];
    wire       cam_href  = GPIO_1[22];
    wire       cam_vsync = GPIO_1[23];
    wire [7:0] cam_d     = GPIO_1[19:12];
    wire       cam_reset_n, cam_pwdn, sioc;
    assign GPIO_1[20] = clk_10;          // XCLK10 MHz; sensor PLLx4 and CLKRC0x81 /2 produce20 MHz PCLK.
    assign GPIO_1[11] = cam_reset_n;     // RESET#
    assign GPIO_1[10] = cam_pwdn;        // PWDN
    assign GPIO_1[25] = sioc;            // SIO_C
    // GPIO_1[24] is SIO_D, driven open-drain from inside ov7670_config; every other pin stays an input

    // ---- configure the camera ------------------------------------------------------------------
    wire cfg_done, cfg_error;
    ov7670_config #(.FPS(CAMERA_FPS)) cfg_u (
        .clk(sccb_clk), .reset(reset_sccb), .sioc(sioc), .siod(GPIO_1[24]),
        .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn), .done(cfg_done), .error(cfg_error));

    // ---- capture the stream (PCLK domain) --------------------------------------------------------
    wire        frame_start, px_valid;
    wire [15:0] px;
    wire [9:0]  px_x;
    wire [8:0]  px_y;
    ov7670_capture cap_u (
        .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .frame_start(frame_start), .valid(px_valid), .pixel(px), .x(px_x), .y(px_y));

    // ---- one picture in memory: written at PCLK, read at clk_25 ----------------------------------
    wire [8:0]  rd_x;
    wire [7:0]  rd_y;
    wire [15:0] rd_pixel;
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(1), .PACKED(0)) fb_u (   // one 16-bit picture, 150 M10K: simple; a moving scene can tear (frame_buffer.sv has 2 / 3 banks and packing)
        .wr_clk(cam_pclk), .wr_frame_start(frame_start), .wr_valid(px_valid), .wr_x(px_x), .wr_y(px_y), .wr_pixel(px),
        .rd_clk(clk_25), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel));

    // ---- show it -----------------------------------------------------------------------------------
    wire [29:0] st_data;
    wire        st_sop, st_eop, st_valid, st_ready;
    camera_display #(.H_RES(640), .V_RES(480), .W(320), .H(240), .ROTATE_CCW_90(1)) disp_u (
        .clk(clk_25), .reset(reset25), .hold_enable(1'b1), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel),
        .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready));


    import perception_pkg::*;
    logic [1:0] rs50='1,rsPclk='1;
    // Shared reset: KEY0 asserts immediately; both B and C release together.
    always_ff @(posedge CLOCK_50 or negedge KEY[0]) begin
        if(!KEY[0]) rs50<=2'b11;
        else rs50<={rs50[0],1'b0};
    end
    always_ff @(posedge cam_pclk) rsPclk<={rsPclk[0],~KEY[0]};
    wire reset50=rs50[1],resetPclk=rsPclk[1];
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic bypassMeta=0,bypassSync=0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic rawProcessingMeta=0,rawProcessingSync=0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic rawDisplayMeta=0,rawDisplaySync=0;
    logic rawDisplayActive;
    always_ff @(posedge CLOCK_50)begin
        if(reset50)begin bypassMeta<=0;bypassSync<=0;end
        else begin bypassMeta<=SW[8];bypassSync<=bypassMeta;end
        if(reset50)begin rawProcessingMeta<=0;rawProcessingSync<=0;rawDisplayMeta<=0;rawDisplaySync<=0;end
        else begin
            rawProcessingMeta<=SW[9];rawProcessingSync<=rawProcessingMeta;
            rawDisplayMeta<=rawDisplayActive;rawDisplaySync<=rawDisplayMeta;
        end
    end
    logic [5:0] microsecondDivider;
    logic [31:0] timeUs;
    always_ff @(posedge CLOCK_50) begin
        if(reset50) begin microsecondDivider<=0;timeUs<=0;end
        else if(microsecondDivider==49)begin microsecondDivider<=0;timeUs<=timeUs+32'd1;end
        else microsecondDivider<=microsecondDivider+6'd1;
    end
    targetRequest_t targetRequest;
    targetReport_t targetReport;
    queryResult_t queryResult;
    userEvent_t userEvent;
    perceptionStatus_t status;
    logic requestValid,requestReady,reportValid,reportReady,eventValid,eventReady;
    logic commandValid,commandReady,calibrateArm,speechArm,autoCycle;
    targetOperation_t commandOperation;
    markerType_t commandMarkerType;
    logic queryResultValid,queryResultReady,queryBusy;
    // Debug SELECT/CLEAR/LIST/GET/AUTO are disabled: C exclusively owns the link.
    assign commandReady=1'b0;
    wire debugQueryBusy=queryBusy;
    // C does not consume interaction events; drain them to prevent stale events/overflow.
    assign eventReady=!reset50;
    logic debugInteractionArmReady;
    logic [3:0] commandDigit;
    logic [1:0] orientationProfile;
    logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] coreWords,debugWords,completedWords,cameraWords,displayWords;
    logic completedFrame;
    logic [15:0] completedFrameId;
    always_comb begin
        debugWords=coreWords;
        debugWords[(DEBUG_TAIL_BASE+4)*32+:32]=`MEMBER_B_BUILD_ID;
        // Schema7 distinguishes live control/display state from bit21, which
        // describes the completed camera frame. Each flag is a single-bit CDC.
        debugWords[7*32+22]=rawProcessingSync;
        debugWords[7*32+23]=rawDisplaySync;
    end
    perceptionCore core (
        .clk(CLOCK_50),.reset(reset50),.pclk(cam_pclk),.resetPclk(resetPclk),
        .cameraFrameStart(frame_start),.cameraPixelValid(px_valid),.cameraPixel(px),.cameraX(px_x),.cameraY(px_y),
        .timeUs(timeUs),.interactionEnable(1'b1),.interactionPermit(1'b1),
        .debugCalArm(calibrateArm),.debugSpeechArm(speechArm),.orientationProfile(orientationProfile),
        .debugInteractionArmReady(debugInteractionArmReady),
        .bypassPerspective(bypassSync),.processingEnable(!rawProcessingSync),
        .targetRequest(targetRequest),.targetRequestValid(requestValid),.targetRequestReady(requestReady),
        .targetReport(targetReport),.targetReportValid(reportValid),.targetReportReady(reportReady),
        .queryResult(queryResult),.queryResultValid(queryResultValid),.queryResultReady(queryResultReady),.queryBusy(queryBusy),
        .userEvent(userEvent),.userEventValid(eventValid),.userEventReady(eventReady),.status(status),
        .debugWords(coreWords),.completedFrame(completedFrame),.completedFrameId(completedFrameId));
    memberCBoard #(.LEFT_POLARITY(LEFT_POLARITY),.RIGHT_POLARITY(RIGHT_POLARITY),
        .TURN_SIGN(TURN_SIGN),.ULTRASONIC_ESTOP_MM(250)) chassis (
        .CLOCK_50(CLOCK_50),.reset50(reset50),.KEY(KEY[1:0]),.SW(SW[4:2]),.IRDA_RXD(IRDA_RXD),
        .timeUs(timeUs),.perceptionStatus(status),
        .targetRequest(targetRequest),.targetRequestValid(requestValid),.targetRequestReady(requestReady),
        .targetReport(targetReport),.targetReportValid(reportValid),.targetReportReady(reportReady),
        .SONAR_TRIG(GPIO_1[27]),.SONAR_ECHO(GPIO_1[29]),
        .CHASSIS_TX(GPIO_1[31]),.CHASSIS_RX(GPIO_1[33]),
        .LEDR(LEDR),.HEX0(HEX0),.HEX1(HEX1),.HEX2(HEX2),.HEX3(HEX3),.HEX4(HEX4),.HEX5(HEX5));
    memberBDebug #(.BUILD_ID(`MEMBER_B_BUILD_ID),.ALLOW_TARGET_COMMANDS(0)) debugControl (
        .clk(CLOCK_50),.reset(reset50),.debugWords(debugWords),.commandValid(commandValid),.commandReady(commandReady),
        .commandOperation(commandOperation),.commandMarkerType(commandMarkerType),.commandDigit(commandDigit),
        .queryResult(queryResult),.queryResultValid(queryResultValid),.queryResultReady(queryResultReady),.queryBusy(debugQueryBusy),
        .calibrateArm(calibrateArm),.speechArm(speechArm),
        .interactionArmReady(debugInteractionArmReady),
        .orientationProfile(orientationProfile),.autoCycle(autoCycle));
    // Wait until the tracker has consumed the completed observation. Freeze a
    // complete frame record, then cross it with a held-bus request/ack handshake.
    logic [1:0] completionDelay;
    always_ff @(posedge CLOCK_50)begin
        if(reset50)begin completionDelay<=0;completedWords<=0;end
        else begin
            completionDelay<={completionDelay[0],completedFrame};
            if(completionDelay[1])completedWords<=debugWords;
        end
    end
    heldBusCdc #(.WIDTH(DEBUG_WORD_COUNT*32)) resultToCamera (
        .sourceClk(CLOCK_50),.sourceReset(reset50),.sourceData(completedWords),
        .destinationClk(cam_pclk),.destinationReset(resetPclk),.destinationData(cameraWords),.destinationValid());
    heldBusCdc #(.WIDTH(DEBUG_WORD_COUNT*32)) resultToDisplay (
        .sourceClk(CLOCK_50),.sourceReset(reset50),.sourceData(completedWords),
        .destinationClk(clk_25),.destinationReset(reset25),.destinationData(displayWords),.destinationValid());
    logic [29:0] overlayData;
    logic overlaySop,overlayEop,overlayValid,overlayReady;
    memberBVgaModeSwitch overlay (
        .clk(clk_25),.reset(reset25),.debugWords(displayWords),
        .rawModeRequested(rawVgaSync),.rawModeActive(rawDisplayActive),
        .showCandidates(switchSync[0]),.showCentre(switchSync[1]),
        .inData(st_data),.inSop(st_sop),.inEop(st_eop),.inValid(st_valid),.inReady(st_ready),
        .outData(overlayData),.outSop(overlaySop),.outEop(overlayEop),.outValid(overlayValid),.outReady(overlayReady));
    vga_sink vga_u (
        .clk_clk(clk_25),.reset_reset_n(~reset25),.video_in_data(overlayData),
        .video_in_startofpacket(overlaySop),.video_in_endofpacket(overlayEop),
        .video_in_valid(overlayValid),.video_in_ready(overlayReady),
        .vga_CLK(VGA_CLK),.vga_HS(VGA_HS),.vga_VS(VGA_VS),.vga_BLANK(VGA_BLANK_N),.vga_SYNC(VGA_SYNC_N),
        .vga_R(VGA_R),.vga_G(VGA_G),.vga_B(VGA_B));
    // GRAB holds its actual captured frame while waiting for matching rectified
    // results. It never combines a new picture with the latest unrelated packet.
    logic [15:0] sensorFrameId;
    logic [15:0] snapshotFrameId;
    logic snapshotResultTimeout;
    logic [(DEBUG_WORD_COUNT+2)*32-1:0] snapshotResults;
    always_ff @(posedge cam_pclk)begin
        if(resetPclk)sensorFrameId<=0;
        else if(frame_start)sensorFrameId<=sensorFrameId+16'd1;
    end
    always_comb begin
        snapshotResults='0;
        for(int i=0;i<DEBUG_WORD_COUNT;i++)snapshotResults[(DEBUG_WORD_COUNT+1-i)*32+:32]=cameraWords[i*32+:32];
        snapshotResults[32+:32]={16'd0,snapshotFrameId};
        snapshotResults[0+:32]=`MEMBER_B_BUILD_ID;
    end
    logic snapBusy,snapReady;
    frame_snap #(.MODE(0),.N_RESULTS(DEBUG_WORD_COUNT+2),.WAIT_FOR_RESULTS(1)) snap_u (
        .pclk(cam_pclk),.reset(resetPclk),.frame_start(frame_start),.px_valid(px_valid),.pixel(px),.x(px_x),.y(px_y),
        .results(snapshotResults),.trigger(~KEY[1]),.busy(snapBusy),.ready(snapReady),
        .results_valid(cameraWords[3*32+:16]==snapshotFrameId),
        .captured_frame_id(snapshotFrameId),.result_timeout(snapshotResultTimeout));
    assign GPIO_1[9:0]=10'bz;
    // Only unused J3/J4/UART neighbours are tri-stated. Camera is GPIO[10:25].
    assign GPIO_1[35:32]=4'bzzzz; // [33] is UART RX, input only.
    assign GPIO_1[30:28]=3'bzzz;  // [29] is J3 ECHO, input only; J4 stays unused.
    assign GPIO_1[26]=1'bz;
endmodule
