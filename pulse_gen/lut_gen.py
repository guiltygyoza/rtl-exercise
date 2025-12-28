#!/usr/bin/env python3
"""
Generate a combinational SystemVerilog LUT module: exp_lut_1024.sv

Spec:
- Input address x is 10-bit UQ4.6, hence x / 64 gives us the real number x for exp(-x) calculation
- Output y is 16-bit UQ0.15 representing exp(-x_real)
- Quantization: round-to-nearest
- Represent 1.0 as 0x7FFF (32767) to avoid ever setting bit[15]=1.

Usage:
  python3 gen_exp_lut_1024.py
  python3 gen_exp_lut_1024.py --out exp_lut_1024.sv
"""

import argparse
import math
from pathlib import Path

N = 1024
FRAC_IN = 6
FRAC_OUT = 15
SCALE_OUT = 1 << FRAC_OUT
MAX_UQ0_15 = 0x7FFF  # 32767


def quantize_uq0_15(y: float) -> int:
    q = int(math.floor(y * SCALE_OUT + 0.5))  # round-to-nearest
    if q < 0:
        q = 0
    if q > MAX_UQ0_15:
        q = MAX_UQ0_15
    return q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="exp_lut_1024.sv", help="Output .sv filename")
    args = ap.parse_args()
    out_path = Path(args.out)

    vals = []
    for addr in range(N):
        x = addr / float(1 << FRAC_IN)  # addr / 64.0
        y = math.exp(-x)
        vals.append(quantize_uq0_15(y))

    lines = []
    lines.append("// -----------------------------------------------------------------------------")
    lines.append("// Auto-generated exp(-x) LUT: 1024 entries")
    lines.append("//")
    lines.append("// Address encoding: x is Q4.6 over [0,16): x_real = x / 64")
    lines.append("// Output encoding : y is UQ0.15, y = round(exp(-x_real) * 2^15)")
    lines.append("// Note: 1.0 is represented as 0x7FFF (not 0x8000) to keep MSB=0.")
    lines.append("// -----------------------------------------------------------------------------")
    lines.append("")
    lines.append("module exp_lut_1024 (")
    lines.append("    input  logic        en,")
    lines.append("    input  logic [9:0]  x,")
    lines.append("    output logic [15:0] y")
    lines.append(");")
    lines.append("    always_comb begin")
    lines.append("        if (!en) begin")
    lines.append("            y = 16'd0;")
    lines.append("        end else begin")
    lines.append("            unique case (x)")

    for addr, q in enumerate(vals):
        lines.append(f"                10'd{addr}: y = 16'h{q:04X};")

    lines.append("                default: y = 16'd0;")
    lines.append("            endcase")
    lines.append("        end")
    lines.append("    end")
    lines.append("endmodule")
    lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")

    # Small sanity print
    print(f"Wrote {out_path} with {N} entries.")
    print(f"addr=0    x=0.000000  y=0x{vals[0]:04X}")
    print(f"addr=64   x=1.000000  y=0x{vals[64]:04X}  (exp(-1)={math.exp(-1.0):.6f})")
    print(f"addr=1023 x={1023/64.0:.6f}  y=0x{vals[1023]:04X}  (exp(-x)={math.exp(-(1023/64.0)):.3e})")


if __name__ == "__main__":
    main()
