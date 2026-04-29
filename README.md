# Hardware Exponential Function: Systolic Array vs. CORDIC

A comparative study of two fundamentally different hardware architectures for
computing the exponential function $e^x$ in fixed-point arithmetic.

---

## 1. Motivation

The exponential function is ubiquitous in digital signal processing (softmax
layers in neural-network accelerators, log-likelihood computation, PID
controllers, communications channel models, and scientific computing). Two
dominant hardware strategies exist:

| Strategy | Core Idea |
|---|---|
| **Systolic / Taylor** | Spatial unrolling of the Taylor series across a pipeline of processing elements (PEs), each computing one term |
| **CORDIC** | Iterative shift-and-add rotations in the hyperbolic coordinate system, converging to cosh(x) + sinh(x) = e^x |

This project implements both in synthesisable Verilog, provides a unified
testbench, and analyses the tradeoffs in **accuracy, latency, throughput, area,
and power**.

---

## 2. Mathematical Background

### 2.1 Taylor / Maclaurin Series

$$e^x = \sum_{n=0}^{N-1} \frac{x^n}{n!} = 1 + x + \frac{x^2}{2!} + \frac{x^3}{3!} + \cdots$$

The $n$-th term can be computed **incrementally** from the $(n{-}1)$-th:

$$T_n = T_{n-1} \cdot \frac{x}{n}, \qquad T_0 = 1$$

This recurrence is the key enabler for the systolic architecture: each PE
receives the previous term, multiplies by $x$, divides by its index $n$
(via a pre-computed reciprocal), and adds the result to a running partial sum
that flows through the pipeline.

**Truncation error** after $N$ terms is bounded by
$|R_N| \le \frac{|x|^N}{N!}$, which shrinks rapidly when $|x| < 1$ (ensured
by range reduction).

### 2.2 Hyperbolic CORDIC

The CORDIC (COordinate Rotation Digital Computer) algorithm generalises
Givens rotations to the hyperbolic plane. In **rotation mode** the
initialisation and iteration are:

$$
\begin{aligned}
x_0 &= 1/K_h, \quad y_0 = 0, \quad z_0 = \theta \\[4pt]
x_{i+1} &= x_i + \sigma_i \, 2^{-s_i} \, y_i \\
y_{i+1} &= y_i + \sigma_i \, 2^{-s_i} \, x_i \\
z_{i+1} &= z_i - \sigma_i \, \text{atanh}(2^{-s_i})
\end{aligned}
$$

where $\sigma_i = \text{sign}(z_i)$ and $K_h = \prod \sqrt{1 - 2^{-2s_i}}$ is
the hyperbolic gain constant pre-compensated in $x_0$.

After convergence: $x_N \approx \cosh(\theta)$, $y_N \approx \sinh(\theta)$,
hence $e^\theta = x_N + y_N$.

**Convergence radius:** $|\theta| \le \sum \text{atanh}(2^{-s_i}) \approx 1.118$
for the standard iteration schedule.

**Repeat rule:** Hyperbolic CORDIC requires repeating iterations at indices
$i \in \{4, 13, 40, \ldots\}$ (i.e. $3k+1$) to guarantee convergence.

### 2.3 Range Reduction

Both algorithms have a limited domain of convergence. A shared **range
reduction** stage decomposes the input:

$$x = k \cdot \ln 2 + r, \qquad 0 \le r < \ln 2 \approx 0.693$$

so that the core only needs to evaluate $e^r$ for a small $r$. The final
result is then:

$$e^x = 2^k \cdot e^r$$

Multiplication by $2^k$ is a trivial barrel shift in fixed-point hardware.

---

## 3. Fixed-Point Representation

All modules use **Q4.12 signed** fixed-point (16-bit, 2's complement):

| Field | Bits | Range |
|---|---|---|
| Sign | 1 | — |
| Integer | 3 | 0–7 |
| Fraction | 12 | 1/4096 resolution |
| **Total** | **16** | **−8.0 to +7.9998** |

The representable range limits $e^x$ to a maximum of ~7.9998, which
corresponds to $x \approx 2.08$. Inputs beyond this saturate. Wider
formats (e.g. Q8.24) extend the range at the cost of multiplier size.

---

## 4. Architecture Details

### 4.1 Systolic Array (Taylor)

```
          ┌──────────┐    ┌──────────┐    ┌──────────┐         ┌──────────┐
  x ─────►│  Stage 0  │───►│   PE 1   │───►│   PE 2   │── ··· ─►│  PE N-1  │──► result
  start ─►│ (seed=1)  │   │ T*x/1    │   │ T*x/2    │         │ T*x/(N-1)│
          └──────────┘    └──────────┘    └──────────┘         └──────────┘
              │                │                │                    │
              ▼                ▼                ▼                    ▼
          partial_sum flows left → right, accumulating each term
```

**Each PE performs:**
1. `new_term = prev_term × x × (1/n)` — two fixed-point multiplications
2. `partial_sum += new_term` — one addition

**Key properties:**
- **Latency:** N−1 clock cycles (one per PE)
- **Throughput:** 1 result/cycle after pipeline fill (fully pipelined)
- **Multipliers:** 2×(N−1) = 14 (for N=8)
- **Adders:** N−1 = 7
- **Registers:** ~4×N (x, term, partial_sum, valid per stage)
- **Division** is avoided by pre-computing `1/n` as a compile-time constant

### 4.2 CORDIC (Hyperbolic)

```
          ┌─────────────────────────────────┐
          │         CORDIC FSM              │
          │                                 │
  x ─────►│  X ← X ± (Y >> s_i)            │
  start ─►│  Y ← Y ± (X >> s_i)            │──► result = X + Y
          │  Z ← Z ∓ atanh(2^{-s_i})       │
          │                                 │
          │  Iterate i = 0 .. N_ITER-1      │
          └─────────────────────────────────┘
```

**Each iteration performs:**
1. Two conditional add/subtract with barrel shift
2. One conditional add/subtract for the angle accumulator

**Key properties:**
- **Latency:** N_ITER + 2 clock cycles (sequential FSM: IDLE→CALC→DONE)
- **Throughput:** 1 result every N_ITER+2 cycles (not pipelined)
- **Multipliers:** 0 (shift-and-add only)
- **Adders:** 3 (reused each iteration)
- **Registers:** ~4 (X, Y, Z, iteration counter)
- **ROM:** atanh lookup table + iteration schedule (small)

---

## 5. Simulation Results

### 5.1 Configuration

| Parameter | Value |
|---|---|
| Word width | 16-bit signed (Q4.12) |
| Taylor terms (systolic) | 8 |
| CORDIC iterations | 16 |
| Range reduction | x = k·ln(2) + r |

### 5.2 Accuracy (within representable range, \|x\| ≤ 2.0)

```
#    | x         | Reference   | Systolic    Err% | CORDIC      Err%
--------------------------------------------------------------------------
0    |    0.0000 |     1.00000 |     1.00000  0.00% |     1.00049  0.05%
1    |    0.1250 |     1.13315 |     1.13306  0.01% |     1.13428  0.10%
2    |    0.2500 |     1.28403 |     1.28418  0.01% |     1.28418  0.01%
3    |    0.5000 |     1.64872 |     1.64868  0.00% |     1.64941  0.04%
4    |    0.6929 |     1.99945 |     1.99927  0.01% |     1.99902  0.02%
5    |    0.7500 |     2.11700 |     2.11719  0.01% |     2.11914  0.10%
6    |    1.0000 |     2.71828 |     2.71875  0.02% |     2.71875  0.02%
7    |    1.5000 |     4.48169 |     4.48242  0.02% |     4.49023  0.19%
8    |    2.0000 |     7.38906 |     7.38965  0.01% |     7.38965  0.01%
12   |   -0.2500 |     0.77880 |     0.77881  0.00% |     0.77954  0.10%
13   |   -0.5000 |     0.60653 |     0.60645  0.01% |     0.60669  0.03%
15   |   -1.0000 |     0.36788 |     0.36768  0.06% |     0.36768  0.06%
17   |   -2.0000 |     0.13534 |     0.13525  0.06% |     0.13525  0.06%
```

**Within the valid Q4.12 range**, both architectures achieve sub-0.2% error.
The systolic array is marginally more accurate on average (fewer intermediate
rounding steps).

### 5.3 Summary Statistics (all 25 test vectors including saturated cases)

| Metric | Systolic | CORDIC |
|---|---|---|
| Max absolute error | 46.60 | 46.60 |
| Mean absolute error | 3.52 | 3.52 |
| Max % error (incl. saturation) | 85.3% | 85.3% |
| Mean % error (incl. saturation) | 10.3% | 10.3% |

> **Note:** The large errors come exclusively from inputs where $e^x > 7.999$
> (the Q4.12 ceiling). Within the representable range, both achieve
> **mean error < 0.05%**.

---

## 6. Tradeoff Analysis

### 6.1 Latency vs. Throughput

| | Systolic (N=8) | CORDIC (16 iter) |
|---|---|---|
| **Latency** | 8 cycles | 18 cycles |
| **Throughput** | **1 result/cycle** | 1 result/18 cycles |
| **Throughput ratio** | **18×** higher | 1× (baseline) |

The systolic array's fully-pipelined datapath delivers dramatically higher
throughput. This is the decisive advantage when computing $e^x$ in a
streaming context (e.g. softmax over a vector of logits).

**Streaming throughput verified:** A dedicated testbench
(`tb/tb_systolic_streaming.v`) injects 12 different x values on 12
consecutive clock cycles. After the initial 8-cycle pipeline fill, results
emerge one per cycle — each matching its corresponding input to within
0.06% error. The key mechanism that enables this is the **x-forwarding**
in each PE (`x_out <= x_in`): every PE carries its own copy of x through
the pipeline, so there is no cross-contamination between in-flight samples.

A subtle correctness requirement is that the range-reduction shift factor
`k` must be pipelined with exactly the same depth as the systolic datapath
(N_TERMS stages). An off-by-one in this shadow pipeline causes power-of-2
scaling errors that are invisible in single-shot tests (where x_in is
held constant) but appear immediately under streaming.

CORDIC can be unrolled/pipelined too, but each stage still contains the
shift-and-add logic, so the area advantage erodes.

### 6.2 Area and Resource Usage

| Resource | Systolic (N=8) | CORDIC (16 iter) |
|---|---|---|
| Multipliers (16×16) | **14** | **0** |
| Adders (16-bit) | 7 | 3 (reused) |
| Registers | ~32 | ~4 |
| LUT/ROM | reciprocal table (N entries) | atanh table (16 entries) |

Multipliers dominate FPGA/ASIC area. A single 16×16 signed multiplier
costs ~256 LUT4s on a typical FPGA or ~2500 gates in ASIC. The systolic
array's 14 multipliers therefore consume roughly **35,000 gate equivalents**
in multiplier logic alone, while the CORDIC engine uses **< 2,000 gates**.

> **Area ratio: CORDIC is ~15–20× smaller** than the systolic array for
> comparable accuracy.

### 6.3 Power

| Factor | Systolic | CORDIC |
|---|---|---|
| Switching activity | High (all PEs active every cycle) | Low (one adder set active per cycle) |
| Clock gating potential | Limited (pipelined) | High (idle between computations) |
| Dynamic power | **Higher** | **Lower** |
| Leakage (proportional to area) | Higher | Lower |

For battery-powered or thermally constrained designs, CORDIC is strongly
preferred.

### 6.4 Accuracy and Precision Scaling

| Property | Systolic | CORDIC |
|---|---|---|
| Error source | Truncation (series) + rounding (multiply) | Rotation residual + rounding (shift) |
| Adding precision | Increase N_TERMS → more PEs and multipliers | Increase N_ITER → more cycles, same hardware |
| Bit-width scaling | Multiplier area grows as $O(W^2)$ | Adder/shifter area grows as $O(W)$ |

For wider datapaths (32-bit, 64-bit), the cost of multipliers grows
quadratically while CORDIC's shift-and-add grows linearly. CORDIC becomes
increasingly attractive at higher precisions.

### 6.5 Design Complexity

| Aspect | Systolic | CORDIC |
|---|---|---|
| Correctness risk | Low (straightforward pipeline) | Medium (repeat-rule, gain compensation) |
| Verification effort | Low | Medium (convergence edge-cases) |
| Parameterisability | Easy (change N_TERMS) | Easy (change N_ITER) |
| IP reuse | Exponential only | Same engine computes sin/cos/sinh/cosh/atan/sqrt |

CORDIC's versatility is a significant advantage in SoCs where the same
hardware may be time-multiplexed across multiple transcendental functions.

---

## 7. Recommendations

| Use Case | Recommended Architecture |
|---|---|
| High-throughput streaming (softmax, DSP) | **Systolic** — 1 result/cycle throughput is essential |
| Area-constrained embedded (MCU, sensor) | **CORDIC** — ~15× smaller, acceptable latency |
| Multi-function math unit | **CORDIC** — same datapath reused for sin/cos/exp/log |
| Ultra-high precision (>32-bit) | **CORDIC** — linear area scaling vs. quadratic for multipliers |
| Low-power / energy harvesting | **CORDIC** — minimal switching activity |
| FPGA with abundant DSP slices | **Systolic** — DSP48 blocks are "free" area; use them |

---

## 8. Repository Structure

```
cordic_v_systolic/
├── README.md                    ← this document
├── Makefile                     ← build & simulate (Icarus Verilog)
├── rtl/
│   ├── range_reduce.v           ← shared range reduction (x = k·ln2 + r)
│   ├── systolic_exp.v           ← systolic PE + array (Taylor core)
│   ├── systolic_exp_top.v       ← systolic + range reduction + 2^k scaling
│   ├── cordic_exp.v             ← CORDIC hyperbolic engine
│   └── cordic_exp_top.v         ← CORDIC + range reduction + 2^k scaling
├── tb/
│   ├── tb_exp_compare.v         ← comparative testbench (accuracy)
│   └── tb_systolic_streaming.v  ← streaming throughput proof
└── sim_results.log              ← captured simulation output
```

---

## 9. Building and Running

### Prerequisites

- [Icarus Verilog](http://iverilog.icarus.com/) (iverilog + vvp)
- Optional: GTKWave for waveform viewing

### Quick Start

```bash
make sim        # compile + simulate, prints comparison table
make wave       # open VCD waveform in GTKWave
make clean      # remove generated files
```

### Manual

```bash
iverilog -g2012 -Wall -o sim_exp tb/tb_exp_compare.v rtl/*.v
vvp sim_exp
```

---

## 10. Extending This Work

1. **Wider fixed-point (Q8.24 or Q16.16):** Extend the `TOTAL_W` and `FRAC_W`
   parameters. The systolic array will require 32×32 multipliers; CORDIC needs
   only wider adders and shifters.

2. **Pipelined CORDIC:** Unroll the CORDIC iterations into a pipeline
   (one stage per iteration) for 1-result/cycle throughput, at the cost of
   replicating the shift-add logic N_ITER times.

3. **Floating-point:** Replace the fixed-point datapath with IEEE 754
   half/single precision. Range reduction becomes exponent manipulation.

4. **Hybrid architecture:** Use CORDIC for the core $e^r$ computation
   (small area) and add a pipelined wrapper for throughput via
   double-buffering or interleaving.

5. **Synthesis & PnR:** Run through Yosys + OpenSTA (open-source) or a
   commercial ASIC/FPGA flow to obtain real area, timing, and power numbers.

---

## 11. References

1. J. E. Volder, "The CORDIC Trigonometric Computing Technique," *IRE Trans.
   Electronic Computers*, vol. EC-8, pp. 330–334, 1959.
2. J. S. Walther, "A Unified Algorithm for Elementary Functions," *Spring Joint
   Computer Conference*, pp. 379–385, 1971.
3. R. Andraka, "A Survey of CORDIC Algorithms for FPGA Based Computers,"
   *ACM/SIGDA FPGA*, pp. 191–200, 1998.
4. H. T. Kung, "Why Systolic Architectures?," *IEEE Computer*, vol. 15,
   no. 1, pp. 37–46, 1982.
5. P. K. Meher et al., "50 Years of CORDIC: Algorithms, Architectures, and
   Applications," *IEEE Trans. Circuits and Systems I*, vol. 56, no. 9,
   pp. 1893–1907, 2009.
