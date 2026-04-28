// ============================================================================
// Testbench: Comparative evaluation of Systolic vs CORDIC e^x
// ============================================================================
// Both DUTs include range reduction (x = k*ln2 + r, e^x = 2^k * e^r).
// Each DUT has independent start/x_in to avoid cross-triggering.
// Inputs are driven at negedge to avoid race conditions with posedge sampling.
// ============================================================================

`timescale 1ns / 1ps

module tb_exp_compare;

    parameter TOTAL_W = 16;
    parameter FRAC_W  = 12;
    parameter N_TERMS = 8;
    parameter N_ITER  = 16;
    parameter CLK_PER = 10;

    reg                          clk;
    reg                          rst_n;

    // Separate controls for each DUT
    reg                          sys_start;
    reg  signed [TOTAL_W-1:0]    sys_x;
    wire                         sys_done;
    wire signed [TOTAL_W-1:0]    sys_result;

    reg                          cor_start;
    reg  signed [TOTAL_W-1:0]    cor_x;
    wire                         cor_done;
    wire signed [TOTAL_W-1:0]    cor_result;

    // ---- DUT instantiation ----
    systolic_exp_top #(
        .TOTAL_W(TOTAL_W),
        .FRAC_W(FRAC_W),
        .N_TERMS(N_TERMS)
    ) u_systolic (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (sys_start),
        .x_in   (sys_x),
        .done   (sys_done),
        .result (sys_result)
    );

    cordic_exp_top #(
        .TOTAL_W(TOTAL_W),
        .FRAC_W(FRAC_W),
        .N_ITER(N_ITER)
    ) u_cordic (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (cor_start),
        .x_in   (cor_x),
        .done_out(cor_done),
        .result (cor_result)
    );

    // ---- Clock generation ----
    initial clk = 0;
    always #(CLK_PER/2) clk = ~clk;

    // ---- Helpers ----
    function real fixed_to_real;
        input signed [TOTAL_W-1:0] val;
        begin
            fixed_to_real = $itor(val) / $itor(1 << FRAC_W);
        end
    endfunction

    function signed [TOTAL_W-1:0] real_to_fixed;
        input real val;
        begin
            real_to_fixed = $rtoi(val * $itor(1 << FRAC_W));
        end
    endfunction

    // ---- Statistics accumulators ----
    real    sys_max_abs, cor_max_abs;
    real    sys_sum_abs, cor_sum_abs;
    real    sys_max_pct, cor_max_pct;
    real    sys_sum_pct, cor_sum_pct;
    integer num_tests;

    // ---- Test vectors ----
    parameter N_VECTORS = 25;
    reg signed [TOTAL_W-1:0] test_x [0:N_VECTORS-1];

    initial begin
        test_x[0]  = real_to_fixed(0.0);
        test_x[1]  = real_to_fixed(0.125);
        test_x[2]  = real_to_fixed(0.25);
        test_x[3]  = real_to_fixed(0.5);
        test_x[4]  = real_to_fixed(0.693);    // ~ ln(2)
        test_x[5]  = real_to_fixed(0.75);
        test_x[6]  = real_to_fixed(1.0);
        test_x[7]  = real_to_fixed(1.5);
        test_x[8]  = real_to_fixed(2.0);
        test_x[9]  = real_to_fixed(2.5);
        test_x[10] = real_to_fixed(3.0);
        test_x[11] = real_to_fixed(3.5);
        test_x[12] = real_to_fixed(-0.25);
        test_x[13] = real_to_fixed(-0.5);
        test_x[14] = real_to_fixed(-0.75);
        test_x[15] = real_to_fixed(-1.0);
        test_x[16] = real_to_fixed(-1.5);
        test_x[17] = real_to_fixed(-2.0);
        test_x[18] = real_to_fixed(-3.0);
        test_x[19] = real_to_fixed(0.01);
        test_x[20] = real_to_fixed(0.1);
        test_x[21] = real_to_fixed(1.25);
        test_x[22] = real_to_fixed(-0.1);
        test_x[23] = real_to_fixed(4.0);
        test_x[24] = real_to_fixed(-4.0);
        num_tests = N_VECTORS;
    end

    // ---- Reset ----
    task reset_all;
    begin
        rst_n     = 0;
        sys_start = 0;
        cor_start = 0;
        sys_x     = 0;
        cor_x     = 0;
        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
    end
    endtask

    // ---- Per-vector variables ----
    real    x_real, expected;
    real    sys_real, cor_real;
    real    s_err, c_err, s_pct, c_pct;
    integer i;
    integer sys_cycles, cor_cycles;
    integer sys_lat_sum, cor_lat_sum;

    // ---- Main test ----
    initial begin
        $dumpfile("exp_compare.vcd");
        $dumpvars(0, tb_exp_compare);

        sys_max_abs = 0; cor_max_abs = 0;
        sys_sum_abs = 0; cor_sum_abs = 0;
        sys_max_pct = 0; cor_max_pct = 0;
        sys_sum_pct = 0; cor_sum_pct = 0;
        sys_lat_sum = 0; cor_lat_sum = 0;

        reset_all;

        $display("");
        $display("==========================================================================");
        $display("    e^x Hardware Comparison: Systolic (Taylor) vs CORDIC (Hyperbolic)");
        $display("    Fixed-point: Q%0d.%0d (%0d-bit signed)",
                  TOTAL_W-FRAC_W, FRAC_W, TOTAL_W);
        $display("    Systolic: %0d Taylor terms, pipelined", N_TERMS);
        $display("    CORDIC:   %0d iterations, sequential FSM", N_ITER);
        $display("    Range reduction: x = k*ln(2) + r, e^x = 2^k * e^r");
        $display("==========================================================================");
        $display("%-4s | %-9s | %-11s | %-11s %3s | %-11s %3s",
                 "#", "x", "Reference", "Systolic", "Err%", "CORDIC", "Err%");
        $display("--------------------------------------------------------------------------");

        for (i = 0; i < num_tests; i = i + 1) begin

            // --- Drive systolic ---
            @(negedge clk);
            sys_x     = test_x[i];
            sys_start = 1;
            @(negedge clk);
            sys_start = 0;

            sys_cycles = 0;
            while (!sys_done) begin
                @(posedge clk);
                sys_cycles = sys_cycles + 1;
            end
            sys_real = fixed_to_real(sys_result);
            sys_lat_sum = sys_lat_sum + sys_cycles;

            // --- Drive CORDIC ---
            @(negedge clk);
            cor_x     = test_x[i];
            cor_start = 1;
            @(negedge clk);
            cor_start = 0;

            cor_cycles = 0;
            while (!cor_done) begin
                @(posedge clk);
                cor_cycles = cor_cycles + 1;
            end
            cor_real = fixed_to_real(cor_result);
            cor_lat_sum = cor_lat_sum + cor_cycles;

            // --- Compute errors ---
            x_real   = fixed_to_real(test_x[i]);
            expected = $exp(x_real);

            s_err = (sys_real > expected) ? (sys_real - expected) : (expected - sys_real);
            c_err = (cor_real > expected) ? (cor_real - expected) : (expected - cor_real);

            s_pct = (expected > 0.001) ? (s_err / expected * 100.0) : 0.0;
            c_pct = (expected > 0.001) ? (c_err / expected * 100.0) : 0.0;

            sys_sum_abs = sys_sum_abs + s_err;
            cor_sum_abs = cor_sum_abs + c_err;
            if (s_err > sys_max_abs) sys_max_abs = s_err;
            if (c_err > cor_max_abs) cor_max_abs = c_err;
            sys_sum_pct = sys_sum_pct + s_pct;
            cor_sum_pct = cor_sum_pct + c_pct;
            if (s_pct > sys_max_pct) sys_max_pct = s_pct;
            if (c_pct > cor_max_pct) cor_max_pct = c_pct;

            $display("%-4d | %9.4f | %11.5f | %11.5f %5.2f%% | %11.5f %5.2f%%",
                     i, x_real, expected, sys_real, s_pct, cor_real, c_pct);

            repeat(2) @(posedge clk);
        end

        $display("--------------------------------------------------------------------------");
        $display("");
        $display("========================= ACCURACY SUMMARY ==============================");
        $display("  Systolic Taylor (%0d terms):", N_TERMS);
        $display("    Max absolute error : %.6f", sys_max_abs);
        $display("    Mean absolute error: %.6f", sys_sum_abs / num_tests);
        $display("    Max  %% error       : %.3f%%", sys_max_pct);
        $display("    Mean %% error       : %.3f%%", sys_sum_pct / num_tests);
        $display("    Mean latency       : %0d cycles", sys_lat_sum / num_tests);
        $display("");
        $display("  CORDIC Hyperbolic (%0d iterations):", N_ITER);
        $display("    Max absolute error : %.6f", cor_max_abs);
        $display("    Mean absolute error: %.6f", cor_sum_abs / num_tests);
        $display("    Max  %% error       : %.3f%%", cor_max_pct);
        $display("    Mean %% error       : %.3f%%", cor_sum_pct / num_tests);
        $display("    Mean latency       : %0d cycles", cor_lat_sum / num_tests);
        $display("");
        $display("====================== ARCHITECTURE COMPARISON ==========================");
        $display("  %-30s | %-20s | %-20s", "Metric", "Systolic", "CORDIC");
        $display("  ---------------------------------------------------------------------");
        $display("  %-30s | %-20s | %-20s", "Compute paradigm", "Pipelined (spatial)", "Iterative (temporal)");
        $display("  %-30s | %-20d | %-20d", "Multipliers", (N_TERMS-1)*2, 0);
        $display("  %-30s | %-20d | %-20d", "Adders/Subtractors", N_TERMS-1, 3);
        $display("  %-30s | %-20d | %-20d", "Pipeline / state registers", N_TERMS*4, 4);
        $display("  %-30s | %-20d | %-20d", "Latency (cycles)", N_TERMS-1, N_ITER+2);
        $display("  %-30s | %-20s | %s",    "Throughput", "1 result/cycle", $sformatf("1 result/%0d cycles", N_ITER+2));
        $display("  %-30s | %-20s | %-20s", "Area cost", "HIGH (multipliers)", "LOW (shift+add)");
        $display("  %-30s | %-20s | %-20s", "Power profile", "Higher (parallel)", "Lower (sequential)");
        $display("  %-30s | %-20s | %-20s", "Best suited for", "High-throughput DSP", "Area-constrained");
        $display("========================================================================");
        $display("");

        #200;
        $finish;
    end

    initial begin
        #1000000;
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
