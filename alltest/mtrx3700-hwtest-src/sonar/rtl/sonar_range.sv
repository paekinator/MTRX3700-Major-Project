// V2026.1 (one-line fix, found with hcsr04_model.sv): IDLE waits for ECHO to be LOW before
// triggering. When nothing is in range the sensor holds ECHO high for ~38 ms, longer than the
// 23.3 ms MEASURE window; the 2025 code then went straight back to TRIG, the sensor ignored that
// trigger (still busy), WAIT saw the *old* echo still high and MEASURE timed the tail of it:
// a bogus ~2.5 m reading after every "nothing there". Everything else is the 2025 code.
module sonar_range(
  input  logic        clk,          // 43.904 MHz
  input  logic        start_measure,
  input  logic        rst,
  input  logic        echo,

  output logic        trig,
  output logic [11:0] distance,
  output logic        ready,
  output logic        valid
);

localparam int TRIG_PERIOD      = 440;        // ~10 us at 43.904 MHz
localparam int MAX_MEASUREMENT  = 1024000;    //  ~23.3 ms window
localparam int TIMEOUT_500MS    = 21952000;   //  0.5 s at 43.904 MHz

typedef enum logic [2:0] { IDLE, TRIG, MEASURE, WAIT, DATA_VALID } sonar_state;

// Counters
/* verilator tracing_off */   // V2026.1: not traced (they change every clock and would make the waveform file
logic [31:0] trig_count = '0; //          tens of MB); watch `distance` (= count >> 8) and `state` instead.
logic [31:0] count      = '0;
logic [31:0] wait_count = '0;
/* verilator tracing_on */

// Sync async inputs
logic echo_meta, echo_sync;
logic sm_meta, sm_sync;

always_ff @(posedge clk) begin
  echo_meta <= echo;
  echo_sync <= echo_meta;

  sm_meta   <= start_measure;
  sm_sync   <= sm_meta;
end

// FSM state
sonar_state state = IDLE, next_state;

// Sequential
always_ff @(posedge clk) begin
  if (rst) begin
    state      <= IDLE;        // reset state IN the flop
    trig       <= 1'b0;
    ready      <= 1'b0;
    trig_count <= '0;
    count      <= '0;
    wait_count <= '0;
  end else begin
    state <= next_state;

    // defaults each cycle
    ready <= 1'b0;

    unique case (state)
      IDLE: begin
        trig       <= 1'b0;
        trig_count <= '0;
        count      <= '0;
        wait_count <= '0;
        ready      <= 1'b1;
      end
      TRIG: begin
        trig       <= 1'b1;
        trig_count <= trig_count + 1;
      end
      WAIT: begin
        trig       <= 1'b0;
        wait_count <= wait_count + 1;
      end
      MEASURE: begin
        trig  <= 1'b0;
        count <= count + 1;
      end
      default: begin
        trig <= 1'b0;
      end
    endcase
  end
end

// Combinational
always_comb begin
  next_state = state;  // hold by default
  valid      = 1'b0;

  if (rst) begin
    next_state = IDLE;
  end else begin
    unique case (state)
      IDLE:       next_state = (sm_sync == 1'b1 && echo_sync == 1'b0) ? TRIG : IDLE;   // V2026.1: never trigger while ECHO is still high (see the note at the top)
      TRIG:       next_state = (trig_count == TRIG_PERIOD-1) ? WAIT : TRIG;
      WAIT:       next_state = (echo_sync == 1'b1) ? MEASURE
                                : (wait_count >= TIMEOUT_500MS ? IDLE : WAIT);
      MEASURE:    next_state = (count >= MAX_MEASUREMENT-1 || (echo_sync != 1'b1))
                                ? DATA_VALID : MEASURE;
      DATA_VALID: begin
        next_state = IDLE;
        valid      = 1'b1;
      end
      default:    next_state = IDLE; // recovery
    endcase
  end
end

assign distance = (count >> 8); // note: this is divide by 256

endmodule
