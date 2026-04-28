// ============================================================================
// CORDIC Implementation of e^x  (Hyperbolic Vectoring Mode)
// ============================================================================
// Identity: e^x = cosh(x) + sinh(x)
//
// Hyperbolic CORDIC iteratively rotates a vector to compute cosh/sinh.
// Initialization: X0 = K_h (hyperbolic gain), Y0 = 0, Z0 = x
// After N iterations: X_N ≈ K_h·cosh(x), Y_N ≈ K_h·sinh(x)
// where K_h is pre-compensated in the initial X value.
//
// Result: e^x = X_N + Y_N
//
// Fixed-point: Q4.12 signed (16-bit total)
//
// Hyperbolic CORDIC requires repeating iterations at indices
// 4, 13, 40, ... (3k+1 rule) for convergence. We repeat iteration 4
// within our 12-iteration pipeline (indices 1..12 with 4 repeated = 13 steps).
// ============================================================================

module cordic_exp #(
    parameter TOTAL_W = 16,
    parameter FRAC_W  = 12,
    parameter N_ITER  = 16       // number of micro-rotations (including repeats)
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire signed [TOTAL_W-1:0] x_in,
    output reg                     done,
    output reg  signed [TOTAL_W-1:0] result
);

    // Hyperbolic atanh lookup table in Q4.12
    // atanh(2^{-i}) for i = 1, 2, 3, ...
    // atanh(t) = 0.5 * ln((1+t)/(1-t))
    // Values: atanh(0.5)=0.5493, atanh(0.25)=0.2554, atanh(0.125)=0.1257, ...
    reg signed [TOTAL_W-1:0] atanh_table [0:15];

    initial begin
        atanh_table[0]  = 16'sd2250;  // atanh(2^-1) = 0.54931 * 4096 ≈ 2250
        atanh_table[1]  = 16'sd1046;  // atanh(2^-2) = 0.25541 * 4096 ≈ 1046
        atanh_table[2]  = 16'sd515;   // atanh(2^-3) = 0.12566 * 4096 ≈ 515
        atanh_table[3]  = 16'sd256;   // atanh(2^-4) = 0.06258 * 4096 ≈ 256
        atanh_table[4]  = 16'sd128;   // atanh(2^-5) = 0.03126 * 4096 ≈ 128
        atanh_table[5]  = 16'sd64;    // atanh(2^-6) = 0.01563
        atanh_table[6]  = 16'sd32;    // atanh(2^-7) = 0.00781
        atanh_table[7]  = 16'sd16;    // atanh(2^-8) = 0.00391
        atanh_table[8]  = 16'sd8;     // atanh(2^-9) = 0.00195
        atanh_table[9]  = 16'sd4;     // atanh(2^-10)= 0.00098
        atanh_table[10] = 16'sd2;     // atanh(2^-11)= 0.00049
        atanh_table[11] = 16'sd1;     // atanh(2^-12)= 0.00024
        atanh_table[12] = 16'sd1;     // atanh(2^-13)
        atanh_table[13] = 16'sd0;
        atanh_table[14] = 16'sd0;
        atanh_table[15] = 16'sd0;
    end

    // Hyperbolic CORDIC iteration schedule
    // Must repeat iterations at index 4, 13, 40, ... (k = 3j+1)
    // For 16 total steps, the shift-index schedule is:
    // step:  0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
    // shift: 1  2  3  4  4  5  6  7  8  9 10 11 12 13 13 14
    // (repeat at step 4 → shift=4 again, repeat at step 14 → shift=13 again)
    reg [3:0] shift_schedule [0:15];
    initial begin
        shift_schedule[0]  = 4'd1;
        shift_schedule[1]  = 4'd2;
        shift_schedule[2]  = 4'd3;
        shift_schedule[3]  = 4'd4;
        shift_schedule[4]  = 4'd4;   // repeat i=4
        shift_schedule[5]  = 4'd5;
        shift_schedule[6]  = 4'd6;
        shift_schedule[7]  = 4'd7;
        shift_schedule[8]  = 4'd8;
        shift_schedule[9]  = 4'd9;
        shift_schedule[10] = 4'd10;
        shift_schedule[11] = 4'd11;
        shift_schedule[12] = 4'd12;
        shift_schedule[13] = 4'd13;
        shift_schedule[14] = 4'd13;  // repeat i=13
        shift_schedule[15] = 4'd14;
    end

    // atanh table indexed by shift value (reuse same entry for repeats)
    reg [3:0] atanh_idx_schedule [0:15];
    initial begin
        atanh_idx_schedule[0]  = 4'd0;   // shift=1 → atanh_table[0]
        atanh_idx_schedule[1]  = 4'd1;
        atanh_idx_schedule[2]  = 4'd2;
        atanh_idx_schedule[3]  = 4'd3;
        atanh_idx_schedule[4]  = 4'd3;   // repeat
        atanh_idx_schedule[5]  = 4'd4;
        atanh_idx_schedule[6]  = 4'd5;
        atanh_idx_schedule[7]  = 4'd6;
        atanh_idx_schedule[8]  = 4'd7;
        atanh_idx_schedule[9]  = 4'd8;
        atanh_idx_schedule[10] = 4'd9;
        atanh_idx_schedule[11] = 4'd10;
        atanh_idx_schedule[12] = 4'd11;
        atanh_idx_schedule[13] = 4'd12;
        atanh_idx_schedule[14] = 4'd12;  // repeat
        atanh_idx_schedule[15] = 4'd13;
    end

    // K_h (hyperbolic gain compensation) = product of sqrt(1 - 2^{-2i})
    // For iterations i=1..14 with repeats at 4,13:
    // K_h ≈ 0.82816 → in Q4.12: round(0.82816 * 4096) = 3393
    // But we want 1/K_h as initial X since CORDIC output = K_h * cosh(z).
    // Actually we set X0 = 1/K_h so output is cosh(z) directly.
    // 1/K_h ≈ 1.20744 → round(1.20744 * 4096) = 4947
    localparam signed [TOTAL_W-1:0] INV_K_H = 16'sd4947;

    // State machine
    localparam S_IDLE = 2'd0;
    localparam S_CALC = 2'd1;
    localparam S_DONE = 2'd2;

    reg [1:0]                  state;
    reg [4:0]                  iter;
    reg signed [TOTAL_W+3:0]  x_reg;    // extra guard bits
    reg signed [TOTAL_W+3:0]  y_reg;
    reg signed [TOTAL_W+3:0]  z_reg;
    reg                        input_neg;
    reg signed [TOTAL_W-1:0]  x_abs;

    wire [3:0] cur_shift    = shift_schedule[iter[3:0]];
    wire [3:0] cur_atanh_idx = atanh_idx_schedule[iter[3:0]];

    wire signed [TOTAL_W+3:0] x_shifted = x_reg >>> cur_shift;
    wire signed [TOTAL_W+3:0] y_shifted = y_reg >>> cur_shift;

    wire                       sigma = z_reg[TOTAL_W+3]; // sign of z: 0=positive, 1=negative
    wire signed [TOTAL_W+3:0] atanh_val = {{4{atanh_table[cur_atanh_idx][TOTAL_W-1]}}, atanh_table[cur_atanh_idx]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            iter      <= 0;
            x_reg     <= 0;
            y_reg     <= 0;
            z_reg     <= 0;
            done      <= 1'b0;
            result    <= 0;
            input_neg <= 1'b0;
            x_abs     <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // For negative x, compute e^|x| then take reciprocal
                        // But reciprocal is expensive; instead CORDIC handles negative z natively
                        // since sinh(-x) = -sinh(x), cosh(-x) = cosh(x)
                        // e^x = cosh(x) + sinh(x) works for negative x too
                        x_reg <= {{4{INV_K_H[TOTAL_W-1]}}, INV_K_H};
                        y_reg <= 0;
                        z_reg <= {{4{x_in[TOTAL_W-1]}}, x_in};
                        iter  <= 0;
                        state <= S_CALC;
                    end
                end

                S_CALC: begin
                    if (iter == N_ITER[4:0]) begin
                        // e^x = cosh(x) + sinh(x) = x_reg + y_reg
                        result <= x_reg[TOTAL_W-1:0] + y_reg[TOTAL_W-1:0];
                        done   <= 1'b1;
                        state  <= S_DONE;
                    end else begin
                        if (!sigma) begin
                            // z >= 0: rotate positively
                            x_reg <= x_reg + y_shifted;
                            y_reg <= y_reg + x_shifted;
                            z_reg <= z_reg - atanh_val;
                        end else begin
                            // z < 0: rotate negatively
                            x_reg <= x_reg - y_shifted;
                            y_reg <= y_reg - x_shifted;
                            z_reg <= z_reg + atanh_val;
                        end
                        iter <= iter + 1;
                    end
                end

                S_DONE: begin
                    done  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
