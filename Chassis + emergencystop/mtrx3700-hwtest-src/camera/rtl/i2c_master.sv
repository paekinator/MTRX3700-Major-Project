module i2c_master (
    input  clk,      // The I2C bit clock (SCL runs at this frequency): 20 kHz in the testbench, 100 kHz on the board (the WM8731 accepts up to 400 kHz).

    output i2c_scl,  // I2C clock
    inout  i2c_sda,  // I2C DATA

    input  [6:0] slav_addr,
    input  read_not_write,
    input  [7:0] reg_addr,

    input  [7:0] write_data,
    input  write_valid,
    output logic write_ready,

    output logic [7:0] read_data,
    output logic read_valid,
    input  read_ready,

    output logic error
);

    logic sda_set;  // 1 means use high impedance on the I2C data line (undriven by the master - it is 1 by default). 0 means pull-down the I2C data line to a 0.
    logic scl_idle; // This sets the I2C clock to the idle high state.
    
    enum logic [3:0] {INIT, START, SLAVE_ADDR, READ_OR_WRITE, ACK1, REG_ADDR, ACK2, DATA, ACK3, STOP0, STOP1, STOP2} state = INIT, next_state;
        
    assign i2c_scl = scl_idle | ~clk;     // The SCLK is 1 if idle, else it is the clock inverted (this is so that the positive edge of SCLK is in the middle of a data bit).
    assign i2c_sda = sda_set ? 1'bz : 0 ; // I2C: set the data line to the high-impedance Z state when sending a `1`, else set to `0`.

    logic ack_1, ack_2, ack_3;               // Acknowledgement status bits for each separate acknowledgement - after slave address, after register address and after data.
    assign error = ack_1 | ack_2 | ack_3;    // If any of the acknowledgements from the receiver are high, then an error has occured (acknowledge is active-low).
    
    logic [2:0] counter = 0; // Use this to count bits.
    
    always_comb begin : fsm_next_state
        next_state = INIT;
        case(state)
            INIT:          next_state = write_valid ? START : INIT;     // Move to the START state once a 'write_valid' signal has been received.
            START:         next_state = SLAVE_ADDR;
            SLAVE_ADDR:    next_state = counter == 6 ? READ_OR_WRITE : SLAVE_ADDR; // Send slave address to the device
            READ_OR_WRITE: next_state = ACK1;
            ACK1:          next_state = REG_ADDR;                         
            REG_ADDR:      next_state = counter == 7 ? ACK2 : REG_ADDR;   // Send the register address to the device
            ACK2:          next_state = DATA;                             
            DATA:          next_state = counter == 7 ? ACK3 : DATA;      // Send the data to the device
            ACK3:          next_state = STOP0;
            STOP0:         next_state = STOP1;                        // Here, we use 3 STOP states to deal with the SCL and SDA stop symbol timings. 
            STOP1:         next_state = STOP2;    
            STOP2:         next_state = INIT;    
        endcase
    end    

    logic  [6:0] slav_addr_temp;
    logic  [7:0] write_data_temp;
    logic  [7:0] reg_addr_temp;
    logic        read_not_write_temp;

    always_ff @(posedge clk) begin : registers
        state <= next_state;
        case (state)
            INIT:   begin ack_1 <= 0 ; ack_2 <= 0 ; ack_3 <= 0; end
            ACK1       :  ack_1 <= i2c_sda;
            ACK2       :  ack_2 <= i2c_sda;
            ACK3       :  ack_3 <= i2c_sda;
        endcase
        if (state == SLAVE_ADDR || state == REG_ADDR || state == DATA) begin
            counter <= counter + 1; // Only count bits in these states (i.e. when we are actually sending information)
        end
        else counter <= 0;
        if (write_ready && write_valid) begin
            slav_addr_temp      <= slav_addr;
            write_data_temp     <= write_data;
            reg_addr_temp       <= reg_addr;
            read_not_write_temp <= read_not_write;
        end
    end

    always_comb begin : fsm_output
        sda_set = 1;
        scl_idle = 0;
        write_ready = 0;
        case (state)
            INIT          : begin write_ready = 1;                      scl_idle = 1; end // Reset registers.
            START         : begin sda_set = 0;                          scl_idle = 1; end // Pull SDA down for start condition
            SLAVE_ADDR    :       sda_set =  slav_addr_temp[6-counter];                   // SLAVE ADDR: The address of the slave we wish to write to.
            READ_OR_WRITE :       sda_set =        read_not_write_temp;
            REG_ADDR      :       sda_set =   reg_addr_temp[7-counter];                   // SUB ADDR: The address of the register we wish to write to. 
            DATA          :       sda_set = write_data_temp[7-counter];                   // DATA: The data we wish to write.
            STOP0         :       sda_set = 0;
            STOP1         : begin sda_set = 0;                          scl_idle = 1; end
            STOP2         :                                             scl_idle = 1;         
        endcase
    end

    always_comb if (read_not_write) $error("I2C read transaction not implemented!"); // (always_comb, not a bare `always`: an always block with no timing control spins forever in ModelSim)

endmodule
