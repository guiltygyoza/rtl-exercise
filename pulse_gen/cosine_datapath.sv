module cosine_datapath (
	input  logic         en,
	input  logic [15:0]  n,
	input  logic [15:0]  mu,
	input  logic [15:0]  wm,    // UQ0.16 turns/sample
	output logic signed [15:0] cosv // SQ1.15
);
	timeunit 1ns;
	timeprecision 1ps;

	// d = abs(n-mu)
	logic signed [16:0] diff;
	logic [16:0]        d_abs;

	assign diff  = $signed({1'b0, n}) - $signed({1'b0, mu});
	assign d_abs = diff[16] ? $unsigned(-diff) : $unsigned(diff);

	// phase: (UQ17.0 * UQ0.16) = UQ17.16
	/* verilator lint_off UNUSEDSIGNAL */
	logic [32:0] phase_uq17_16;
	/* verilator lint_on UNUSEDSIGNAL */
	assign phase_uq17_16 = $unsigned(d_abs) * $unsigned(wm);

	// Fractional turns (mod 1 turn)
	logic [15:0] phase_frac;
	assign phase_frac = phase_uq17_16[15:0];

	// 2048-entry table:
	//   addr selects sample, frac interpolates between addr and addr+1
	logic [10:0] addr, addr_p1;
	logic [4:0]  frac; // 0..31

	assign addr   = phase_frac[15:5];
	assign frac   = phase_frac[4:0];
	assign addr_p1 = addr + 11'd1; // wraps naturally (2047->0)

	logic signed [15:0] y0, y1;

	cos_lut_2048 lut0 (.en(en), .x(addr),   .y(y0));
	cos_lut_2048 lut1 (.en(en), .x(addr_p1),.y(y1));

	// y = y0 + (y1 - y0) * frac / 32
	logic signed [16:0] dy;
	logic signed [21:0] mul;     // dy(17) * frac(6 incl sign?) -> size safely
	/* verilator lint_off UNUSEDSIGNAL */
	logic signed [21:0] term;
	logic signed [17:0] sum;
	/* verilator lint_on UNUSEDSIGNAL */

	assign dy   = $signed({y1[15], y1}) - $signed({y0[15], y0}); // 17b
	assign mul  = dy * $signed({1'b0, frac});                    // 17b * 6b -> up to 23b
	assign term = mul >>> 5;                                     // divide by 32
	assign sum  = $signed({y0[15], y0}) + $signed(term[17:0]);

	// When disabled, value is unused by pulse_gen; drive +1.0 to be safe
	assign cosv = en ? sum[15:0] : 16'sh7FFF;
endmodule
