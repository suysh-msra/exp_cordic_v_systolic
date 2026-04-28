# ============================================================================
# Makefile for e^x Hardware Implementation Comparison
# Supports: Icarus Verilog (iverilog) and Verilator
# ============================================================================

# Tools
IVERILOG  = iverilog
VVP       = vvp
GTKWAVE   = gtkwave

# Source files
RTL_DIR   = rtl
TB_DIR    = tb
RTL_SRC   = $(RTL_DIR)/range_reduce.v $(RTL_DIR)/systolic_exp.v $(RTL_DIR)/cordic_exp.v \
            $(RTL_DIR)/systolic_exp_top.v $(RTL_DIR)/cordic_exp_top.v
TB_SRC    = $(TB_DIR)/tb_exp_compare.v

# Output
SIM_OUT   = sim_exp
VCD_FILE  = exp_compare.vcd
LOG_FILE  = sim_results.log

.PHONY: all sim wave clean

all: sim

# Compile and simulate with Icarus Verilog
sim: $(RTL_SRC) $(TB_SRC)
	$(IVERILOG) -g2012 -Wall -o $(SIM_OUT) $(TB_SRC) $(RTL_SRC)
	$(VVP) $(SIM_OUT) | tee $(LOG_FILE)
	@echo ""
	@echo "Results saved to $(LOG_FILE)"
	@echo "Waveform saved to $(VCD_FILE)"

# View waveforms
wave: $(VCD_FILE)
	$(GTKWAVE) $(VCD_FILE) &

clean:
	rm -f $(SIM_OUT) $(VCD_FILE) $(LOG_FILE)
	rm -rf obj_dir
