// ============================================================================
// Systolic Array Implementation of e^x
// ============================================================================
// Taylor series: e^x = sum_{n=0}^{N-1} x^n / n!
//
// Architecture: Linear systolic array of N processing elements.
// PE[0] outputs the constant 1 (= x^0/0!).
// PE[n] computes term[n] = term[n-1] * x / n
//
// Fixed-point format: Q4.12 (4 integer bits, 12 fractional bits)
// Total width: 16 bits, signed (2's complement)
// ============================================================================

module systolic_pe #(
    parameter TOTAL_W = 16,
    parameter FRAC_W  = 12,
    parameter PE_IDX  = 1       // which term this PE computes (1..N-1)
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    input  wire signed [TOTAL_W-1:0] x_in,
    input  wire signed [TOTAL_W-1:0] term_in,      // term from previous PE
    input  wire signed [TOTAL_W-1:0] partial_sum_in,
    output reg                     valid_out,
    output reg  signed [TOTAL_W-1:0] x_out,
    output reg  signed [TOTAL_W-1:0] term_out,
    output reg  signed [TOTAL_W-1:0] partial_sum_out
);

    // Reciprocal of PE_IDX in Q4.12 — precomputed as floor(4096 / PE_IDX)
    localparam signed [TOTAL_W-1:0] RECIP_N =
        (PE_IDX == 1)  ? 16'sd4096 :   // 1/1
        (PE_IDX == 2)  ? 16'sd2048 :   // 1/2
        (PE_IDX == 3)  ? 16'sd1365 :   // 1/3
        (PE_IDX == 4)  ? 16'sd1024 :   // 1/4
        (PE_IDX == 5)  ? 16'sd819  :   // 1/5
        (PE_IDX == 6)  ? 16'sd683  :   // 1/6
        (PE_IDX == 7)  ? 16'sd585  :   // 1/7
        (PE_IDX == 8)  ? 16'sd512  :   // 1/8
        (PE_IDX == 9)  ? 16'sd455  :   // 1/9
        (PE_IDX == 10) ? 16'sd410  :   // 1/10
                         16'sd4096;

    wire signed [2*TOTAL_W-1:0] mult_xterm;
    wire signed [2*TOTAL_W-1:0] mult_div;
    wire signed [TOTAL_W-1:0]   new_term;

    // term_out = term_in * x / n  =  (term_in * x) * (1/n)
    // Two fixed-point multiplications with rounding
    assign mult_xterm = term_in * x_in;
    wire signed [TOTAL_W-1:0] xterm_trunc = (mult_xterm + (1 << (FRAC_W-1))) >>> FRAC_W;

    assign mult_div  = xterm_trunc * RECIP_N;
    assign new_term  = (mult_div + (1 << (FRAC_W-1))) >>> FRAC_W;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out       <= 1'b0;
            x_out           <= {TOTAL_W{1'b0}};
            term_out        <= {TOTAL_W{1'b0}};
            partial_sum_out <= {TOTAL_W{1'b0}};
        end else begin
            valid_out       <= valid_in;
            x_out           <= x_in;
            term_out        <= new_term;
            partial_sum_out <= partial_sum_in + new_term;
        end
    end

endmodule


// Top-level systolic array: chains N_TERMS PEs
module systolic_exp #(
    parameter TOTAL_W = 16,
    parameter FRAC_W  = 12,
    parameter N_TERMS = 8      // number of Taylor terms (including the constant 1)
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire signed [TOTAL_W-1:0] x_in,
    output wire                    done,
    output wire signed [TOTAL_W-1:0] result
);

    // Pipeline wires between PEs
    wire                    pe_valid [0:N_TERMS-1];
    wire signed [TOTAL_W-1:0] pe_x     [0:N_TERMS-1];
    wire signed [TOTAL_W-1:0] pe_term  [0:N_TERMS-1];
    wire signed [TOTAL_W-1:0] pe_psum  [0:N_TERMS-1];

    // Stage 0: seed values (combinational)
    // term[0] = 1.0  (= x^0/0! = 1)
    // partial_sum[0] = 1.0
    localparam signed [TOTAL_W-1:0] ONE = {{(TOTAL_W-FRAC_W-1){1'b0}}, 1'b1, {FRAC_W{1'b0}}};

    reg                     s0_valid;
    reg signed [TOTAL_W-1:0] s0_x;
    reg signed [TOTAL_W-1:0] s0_term;
    reg signed [TOTAL_W-1:0] s0_psum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            s0_x     <= 0;
            s0_term  <= 0;
            s0_psum  <= 0;
        end else begin
            s0_valid <= start;
            s0_x     <= x_in;
            s0_term  <= ONE;       // x^0/0! = 1
            s0_psum  <= ONE;       // partial sum starts at 1
        end
    end

    assign pe_valid[0] = s0_valid;
    assign pe_x[0]     = s0_x;
    assign pe_term[0]  = s0_term;
    assign pe_psum[0]  = s0_psum;

    // Instantiate PEs for terms 1 through N_TERMS-1
    genvar i;
    generate
        for (i = 1; i < N_TERMS; i = i + 1) begin : gen_pe
            systolic_pe #(
                .TOTAL_W(TOTAL_W),
                .FRAC_W(FRAC_W),
                .PE_IDX(i)
            ) u_pe (
                .clk            (clk),
                .rst_n          (rst_n),
                .valid_in       (pe_valid[i-1]),
                .x_in           (pe_x[i-1]),
                .term_in        (pe_term[i-1]),
                .partial_sum_in (pe_psum[i-1]),
                .valid_out      (pe_valid[i]),
                .x_out          (pe_x[i]),
                .term_out       (pe_term[i]),
                .partial_sum_out(pe_psum[i])
            );
        end
    endgenerate

    assign done   = pe_valid[N_TERMS-1];
    assign result = pe_psum[N_TERMS-1];

endmodule
