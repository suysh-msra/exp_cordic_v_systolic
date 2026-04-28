// ============================================================================
// Top-level: Systolic e^x with Range Reduction
// ============================================================================
// Pipeline:  range_reduce (comb) → systolic_exp (compute e^r) → scale_by_2k
//
// systolic_exp pipeline depth:
//   1 cycle (s0 register) + (N_TERMS-2) cycles (PEs 1..N_TERMS-1)
//   = N_TERMS-1 cycles total from start to done.
//
// k_pipe must match this depth so the shift factor arrives with the result.
// ============================================================================

module systolic_exp_top #(
    parameter TOTAL_W = 16,
    parameter FRAC_W  = 12,
    parameter N_TERMS = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire signed [TOTAL_W-1:0] x_in,
    output wire                    done,
    output wire signed [TOTAL_W-1:0] result
);

    // Range reduction (combinational)
    wire signed [TOTAL_W-1:0] r;
    wire signed [7:0]          k;

    range_reduce #(.TOTAL_W(TOTAL_W), .FRAC_W(FRAC_W)) u_rr (
        .x_in  (x_in),
        .r_out (r),
        .k_out (k)
    );

    // k pipeline: N_TERMS-1 stages to align with systolic pipeline depth
    // k_pipe[0] captured same cycle as s0, k_pipe[N_TERMS-2] aligns with done
    localparam K_DEPTH = N_TERMS - 1;
    reg signed [7:0] k_pipe [0:K_DEPTH-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < K_DEPTH; i = i + 1)
                k_pipe[i] <= 0;
        end else begin
            k_pipe[0] <= k;
            for (i = 1; i < K_DEPTH; i = i + 1)
                k_pipe[i] <= k_pipe[i-1];
        end
    end

    // Systolic compute of e^r
    wire                    sys_done;
    wire signed [TOTAL_W-1:0] sys_result;

    systolic_exp #(
        .TOTAL_W(TOTAL_W),
        .FRAC_W(FRAC_W),
        .N_TERMS(N_TERMS)
    ) u_sys (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (start),
        .x_in   (r),
        .done   (sys_done),
        .result (sys_result)
    );

    // Scale by 2^k (combinational on pipeline-aligned k)
    scale_by_2k #(.TOTAL_W(TOTAL_W), .FRAC_W(FRAC_W)) u_scale (
        .val_in  (sys_result),
        .k        (k_pipe[K_DEPTH-1]),
        .val_out (result)
    );

    assign done = sys_done;

endmodule
