// ============================================================================
// Top-level: CORDIC e^x with Range Reduction
// ============================================================================
// Pipeline:  range_reduce → cordic_exp (compute e^r) → scale_by_2k
// ============================================================================

module cordic_exp_top #(
    parameter TOTAL_W = 16,
    parameter FRAC_W  = 12,
    parameter N_ITER  = 16
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire signed [TOTAL_W-1:0] x_in,
    output wire                    done_out,
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

    // Latch k when start asserted, hold until done
    reg signed [7:0] k_saved;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            k_saved <= 0;
        else if (start)
            k_saved <= k;
    end

    // CORDIC compute of e^r
    wire                    cor_done;
    wire signed [TOTAL_W-1:0] cor_result;

    cordic_exp #(
        .TOTAL_W(TOTAL_W),
        .FRAC_W(FRAC_W),
        .N_ITER(N_ITER)
    ) u_cor (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (start),
        .x_in   (r),
        .done   (cor_done),
        .result (cor_result)
    );

    // Scale by 2^k
    scale_by_2k #(.TOTAL_W(TOTAL_W), .FRAC_W(FRAC_W)) u_scale (
        .val_in  (cor_result),
        .k        (k_saved),
        .val_out (result)
    );

    assign done_out = cor_done;

endmodule
