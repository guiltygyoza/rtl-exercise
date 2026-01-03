#!/usr/bin/env python3
"""
Generate a combinational SystemVerilog LUT module: cos_lut_2048.sv

Spec:
- Input address x is 11-bit, representing phase in units of 1/2048 turn:
    phase_turns = x / 2048.0   (in turns)
    phase_radians = 2*pi * phase_turns
- Output y is 16-bit signed SQ1.15 representing cos(2*pi * phase_turns)
- Quantization: round-to-nearest (with symmetric handling for negative values)
- Range: [-1, 1) maps to [-32768, 32767] in SQ1.15
  Note: +1.0 is represented as 0x7FFF (32767), -1.0 as 0x8000 (-32768)

Usage:
  python3 cos_lut_gen_2048.py
  python3 cos_lut_gen_2048.py --out cos_lut_2048.sv
"""

import argparse
import math
from pathlib import Path

N = 2048
FRAC_OUT = 15
SCALE_OUT = 1 << FRAC_OUT
MAX_SQ1_15 = 0x7FFF      # +0.999969... (represents +1.0 saturated)
MIN_SQ1_15 = -0x8000     # -1.0


def quantize_sq1_15(y: float) -> int:
    """
    Quantize float y in [-1, 1] to signed SQ1.15, returning a 16-bit two's complement int (0..65535).
    Uses round-to-nearest with symmetric behavior for negative values.
    """
    q = int(round(y * SCALE_OUT))  # symmetric rounding for negatives (bankers on .5, acceptable here)

    if q > MAX_SQ1_15:
        q = MAX_SQ1_15
    if q < MIN_SQ1_15:
        q = MIN_SQ1_15

    # Convert to 16-bit two's complement for hex emission
    return q & 0xFFFF


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="cos_lut_2048.sv", help="Output .sv filename")
    args = ap.parse_args()
    out_path = Path(args.out)

    vals = []
    for addr in range(N):
        phase_turns = addr / float(N)  # addr / 2048.0
        y = math.cos(2.0 * math.pi * phase_turns)
        vals.append(quantize_sq1_15(y))

    lines = []
    lines.append("// -----------------------------------------------------------------------------")
    lines.append("// Auto-generated cos(2*pi*x) LUT: 2048 entries")
    lines.append("//")
    lines.append("// Address encoding: x_real = x / 2048.0 turns  (x in [0..2047])")
    lines.append("// Output encoding : y is SQ1.15, y = round(cos(2*pi*x_real) * 2^15)")
    lines.append("// Note: +1.0 is saturated to 0x7FFF (32767), -1.0 is 0x8000 (-32768)")
    lines.append("// -----------------------------------------------------------------------------")
    lines.append("")
    lines.append("module cos_lut_2048 (")
    lines.append("    input  logic              en,")
    lines.append("    input  logic [10:0]       x,")
    lines.append("    output logic signed [15:0] y")
    lines.append(");")
    lines.append("    timeunit 1ns;")
    lines.append("    timeprecision 1ps;")
    lines.append("")
    lines.append("    always_comb begin")
    lines.append("        if (!en) begin")
    lines.append("            y = 16'sd0;")
    lines.append("        end else begin")
    lines.append("            unique case (x)")

    for addr, q16 in enumerate(vals):
        lines.append(f"                11'd{addr}: y = 16'sh{q16:04X};")

    lines.append("                default: y = 16'sd0;")
    lines.append("            endcase")
    lines.append("        end")
    lines.append("    end")
    lines.append("endmodule")
    lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")

    # Sanity prints (consistent with addr/N generation)
    def hx(i: int) -> str:
        return f"0x{vals[i] & 0xFFFF:04X}"

    print(f"Wrote {out_path} with {N} entries.")
    print(f"addr=0      turns={0/N:.6f}   rad={2*math.pi*0/N:.6f}   y={hx(0)}     (expected ~+1)")
    print(f"addr=512    turns={512/N:.6f} rad={2*math.pi*512/N:.6f} y={hx(512)}  (expected ~0)")
    print(f"addr=1024   turns={1024/N:.6f} rad={2*math.pi*1024/N:.6f} y={hx(1024)} (expected ~-1)")
    print(f"addr=1536   turns={1536/N:.6f} rad={2*math.pi*1536/N:.6f} y={hx(1536)} (expected ~0)")
    print(f"addr=2047   turns={2047/N:.6f} rad={2*math.pi*2047/N:.6f} y={hx(2047)} (expected ~+1)")

if __name__ == "__main__":
    main()
