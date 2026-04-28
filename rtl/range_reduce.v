// ============================================================================
// Range Reduction for e^x computation
// ============================================================================
// Decomposes x into:   x = k * ln(2) + r,  where 0 <= r < ln(2)
// Then:                e^x = 2^k * e^r
//
// This keeps r within [0, ln2) ~= [0, 0.693), well inside the convergence
// radius of both Taylor series (with 8 terms) and hyperbolic CORDIC (~1.118).
//
// Fixed-point: Q4.12 signed, 16-bit
// ============================================================================

module range_reduce #(
    parameter TOTAL_W = 16,
    parameter FRAC_W  = 12
)(
    input  wire signed [TOTAL_W-1:0] x_in,
    output wire signed [TOTAL_W-1:0] r_out,
    output wire signed [7:0]          k_out
);

    // ln(2) in Q4.12 = round(0.693147 * 4096) = 2839
    localparam signed [TOTAL_W-1:0] LN2 = 16'sd2839;

    // 1/ln(2) in Q4.12 = round(1.442695 * 4096) = 5909
    localparam signed [TOTAL_W-1:0] INV_LN2 = 16'sd5909;

    // k = floor(x / ln2) via fixed-point multiply: x * (1/ln2)
    // Both operands are Q4.12, product is Q8.24 in 32 bits
    wire signed [2*TOTAL_W-1:0] k_prod;
    assign k_prod = x_in * INV_LN2;

    // Extract integer part = arithmetic right shift by 2*FRAC_W = 24
    // This gives floor(x/ln2) for both positive and negative x
    wire signed [2*TOTAL_W-1:0] k_int;
    assign k_int = k_prod >>> (2 * FRAC_W);
    assign k_out = k_int[7:0];

    // r = x - k * ln(2) — guaranteed to be in [0, ln2)
    // k_out is small integer, LN2 is Q4.12, product fits in 32 bits
    wire signed [31:0] k_x_ln2;
    assign k_x_ln2 = $signed(k_out) * $signed(LN2);
    assign r_out = x_in - k_x_ln2[TOTAL_W-1:0];

endmodule


// Apply 2^k scaling to a Q4.12 value
module scale_by_2k #(
    parameter TOTAL_W = 16,
    parameter FRAC_W  = 12
)(
    input  wire signed [TOTAL_W-1:0] val_in,
    input  wire signed [7:0]          k,
    output reg  signed [TOTAL_W-1:0] val_out
);

    wire signed [31:0] extended = {{16{val_in[TOTAL_W-1]}}, val_in};

    // Compute |k| safely using full-width negate then truncate
    wire signed [7:0] neg_k = -k;
    wire [4:0] abs_k = (k >= 0) ? k[4:0] : neg_k[4:0];

    wire signed [31:0] shifted =
        (k >= 0) ? (extended <<< abs_k) : (extended >>> abs_k);

    // Saturate on overflow (positive shift can exceed Q4.12 range)
    wire overflow = (k >= 0) &&
                    (shifted > 32'sd32767 || shifted < -32'sd32768);

    always @(*) begin
        if (overflow)
            val_out = val_in[TOTAL_W-1] ? {1'b1, {(TOTAL_W-1){1'b0}}}
                                        : {1'b0, {(TOTAL_W-1){1'b1}}};
        else
            val_out = shifted[TOTAL_W-1:0];
    end

endmodule
