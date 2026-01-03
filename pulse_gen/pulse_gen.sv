module pulse_gen #(
	parameter time         T_CQ = 1ns
) (
	// Clock/resets
	input  logic               clk,
	input  logic               rst_n,

	// Command handshake interface
	input  logic               cmd_val,
	output logic               cmd_rdy,
	// cmd_sample_len: 16b unsigned integer, UQ16.0
	input  logic [15:0]        cmd_sample_len,
	// cmd_mu: 16b unsigned integer w.r.t length, UQ16.0
	input  logic [15:0]        cmd_mu,
	// cmd_inv_sigma_square: UQ1.31, software precomputed 1/sigma2, with sigma being UQ8.8 and sigma minimum being 1.0 in decimal
	input  logic [31:0]        cmd_inv_sigma_square,
	// cmd_amp: 16b signed, normalized to [-1, 1); SQ0.15
	input  logic signed [15:0] cmd_amp,
	// cmd_beta: 16b signed DRAG scaling; SQ0.15
	input  logic signed [15:0] cmd_beta,
	// wah-wah controls
	input  logic               cmd_use_ww,
	input  logic signed [15:0] cmd_Am,    // SQ0.15
	input  logic [15:0]        cmd_wm,    // UQ0.16

	// Explicit start trigger for pulse firing
	input  logic               start,

	// Output; no backpressure
	output logic               out_val,
	output logic signed [15:0] out_i,     // SQ0.15, [-1, 1)
	output logic signed [15:0] out_q,     // SQ0.15, [-1, 1)

	// Status
	output logic               out_last,
	output logic               busy,    // high from first valid sample to out_last cycle
	output logic               err_cmd
);
	timeunit 1ns;
	timeprecision 1ps;

	// -------------
	// Control logic
	// -------------

	// flops for the command
	logic [15:0]  cmd_sample_len_q;
	logic [15:0]  cmd_mu_q;
	logic [31:0]  cmd_inv_sigma_square_q;
	logic signed [15:0] cmd_amp_q;
	logic signed [15:0] cmd_beta_q;
	logic         cmd_use_ww_q;
	logic signed [15:0] cmd_Am_q;
	logic [15:0]  cmd_wm_q;


	// counting output samples
	logic [15:0] out_counter_d, out_counter_q;

	// State machine
	typedef enum logic [1:0] {
		IDLE   = 2'd0,
		LOADED = 2'd1,
		BUSY   = 2'd2
	} state_t;

	state_t state_d, state_q;

	// flag for command validity
	logic valid_cmd;
	assign valid_cmd = (cmd_sample_len_q > 16'd2) &&
	                   (cmd_mu_q < cmd_sample_len_q) &&
	                   (cmd_inv_sigma_square_q != 32'd0) &&
					   (!cmd_use_ww_q || (cmd_wm_q != 16'd0)); // Am can be 0 (pulse degenerates to DRAG)

	// Calculating next state
	always_comb begin
		// default
		state_d = state_q;
		unique case (state_q)
			IDLE: begin
				if (cmd_val && cmd_rdy) begin
					state_d = LOADED;
				end
			end
			LOADED: begin
				if (cmd_val && cmd_rdy) begin // reload; last command before start wins
					state_d = LOADED;
				end else if (start && valid_cmd) begin
					state_d = BUSY;
				end else begin
					state_d = LOADED;
				end
			end
			BUSY: begin
				if (out_last) begin
					state_d = IDLE;
				end
			end
			default: state_d = IDLE;
		endcase
	end
	assign err_cmd = (state_q == LOADED) && !valid_cmd;
	assign busy = (state_q == BUSY);
	assign out_last = busy && (out_counter_q == cmd_sample_len_q - 16'd1);
	assign cmd_rdy = (state_q != BUSY);

	// State flop
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n)
			state_q <= #T_CQ IDLE;
		else
			state_q <= #T_CQ state_d;
	end

	// Command flops
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			cmd_sample_len_q       <= #T_CQ 16'd0;
			cmd_mu_q               <= #T_CQ 16'd0;
			cmd_inv_sigma_square_q <= #T_CQ 32'd0;
			cmd_amp_q              <= #T_CQ 16'sd0;
			cmd_beta_q             <= #T_CQ 16'sd0;
			cmd_use_ww_q           <= #T_CQ 1'b0;
			cmd_Am_q               <= #T_CQ 16'sd0;
			cmd_wm_q               <= #T_CQ 16'd0;
		end else if (cmd_val && cmd_rdy) begin
			cmd_sample_len_q       <= #T_CQ cmd_sample_len;
			cmd_mu_q               <= #T_CQ cmd_mu;
			cmd_inv_sigma_square_q <= #T_CQ cmd_inv_sigma_square;
			cmd_amp_q              <= #T_CQ cmd_amp;
			cmd_beta_q             <= #T_CQ cmd_beta;
			cmd_use_ww_q           <= #T_CQ cmd_use_ww;
			cmd_Am_q               <= #T_CQ cmd_Am;
			cmd_wm_q               <= #T_CQ cmd_wm;
		end else begin
			cmd_sample_len_q       <= #T_CQ cmd_sample_len_q;
			cmd_mu_q               <= #T_CQ cmd_mu_q;
			cmd_inv_sigma_square_q <= #T_CQ cmd_inv_sigma_square_q;
			cmd_amp_q              <= #T_CQ cmd_amp_q;
			cmd_beta_q             <= #T_CQ cmd_beta_q;
			cmd_use_ww_q           <= #T_CQ cmd_use_ww_q;
			cmd_Am_q               <= #T_CQ cmd_Am_q;
			cmd_wm_q               <= #T_CQ cmd_wm_q;
		end
	end

	// Counter flop
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			out_counter_q <= #T_CQ 16'd0;
		end else begin
			out_counter_q <= #T_CQ out_counter_d;
		end
	end
	assign out_counter_d = (state_q != BUSY) ? '0 : out_counter_q + 'd1;

	// ---------------
	// Data path logic
	// ---------------

	// ---------------------------------
	// 1) Gaussian: G[n], G[n+1], G[n-1]
	// ---------------------------------

	// Use gaussian_datapath module to generate G_n in UQ0.15
	logic [15:0] G_n;

	gaussian_datapath u_gaussian_datapath_0 (
		.en    ('b1),
		.n     (out_counter_q),
		.mu    (cmd_mu_q),
		.inv_sigma_square(cmd_inv_sigma_square_q),
		.G_n   (G_n)
	);

	// Instantiate gaussian_datapath for G[n+1],
	// enable only if n is not the last sample
	logic [15:0] G_n_plus_1;
	logic [15:0] n_plus_1;
	logic not_last_sample;
	assign n_plus_1 = out_counter_q + 16'd1;
	assign not_last_sample = ~out_last;
	gaussian_datapath u_gaussian_datapath_1 (
		.en    (not_last_sample),
		.n     (n_plus_1),
		.mu    (cmd_mu_q),
		.inv_sigma_square(cmd_inv_sigma_square_q),
		.G_n   (G_n_plus_1)
	);

	// Instantiate gaussian_datapath for G[n-1],
	// enable only if n is not the first sample
	logic [15:0] G_n_minus_1;
	logic [15:0] n_minus_1;
	logic not_first_sample;
	assign n_minus_1 = out_counter_q - 16'd1;
	assign not_first_sample = out_counter_q != '0;
	gaussian_datapath u_gaussian_datapath_2 (
		.en    (not_first_sample),
		.n     (n_minus_1),
		.mu    (cmd_mu_q),
		.inv_sigma_square(cmd_inv_sigma_square_q),
		.G_n   (G_n_minus_1)
	);

	// -------------------------------------------------
	// 2) Cosine(s): cos(wm*(n-mu)) for WW mode
	//    - cmd_wm_q is UQ0.16; unit: "turns per sample"
	//    - cosine LUT output is SQ1.15 in [-1, 1)
	// -------------------------------------------------

	logic signed [15:0] cos_n, cos_n_p1, cos_n_m1;

	cosine_datapath u_cos_0 (
		.en   (cmd_use_ww_q),
		.n    (out_counter_q),
		.mu   (cmd_mu_q),
		.wm   (cmd_wm_q),
		.cosv (cos_n)
	);

	cosine_datapath u_cos_1 (
		.en   (cmd_use_ww_q && not_last_sample),
		.n    (n_plus_1),
		.mu   (cmd_mu_q),
		.wm   (cmd_wm_q),
		.cosv (cos_n_p1)
	);

	cosine_datapath u_cos_2 (
		.en   (cmd_use_ww_q && not_first_sample),
		.n    (n_minus_1),
		.mu   (cmd_mu_q),
		.wm   (cmd_wm_q),
		.cosv (cos_n_m1)
	);

	// -------------------------------------------------
	// 3) Envelope selection:
	//    DRAG:    E[n] = G[n]
	//    Wah-Wah: E[n] = G[n] * (1 - Am*cos(wm*(n-mu)))
	//
	// Fixed-point:
	//   G[n]  : UQ0.15
	//   Am    : SQ0.15 (recommended 0..1)
	//   cos   : SQ1.15
	//   M[n]  : UQ1.15 (clamped)
	//   E[n]  : UQ1.15
	// -------------------------------------------------

	// Helper: compute M = 1 - Am*cos and clamp to UQ1.15
	function automatic logic [15:0] ww_mod_uq1_15(
		input logic signed [15:0] Am_sq0_15,
		input logic signed [15:0] cos_sq1_15
	);
		logic signed [31:0] am_cos_wide;  // SQ?30
		logic signed [15:0] am_cos_q1_15; // SQ1.15
		logic signed [16:0] m_signed;     // for clamp
		/* verilator lint_off UNUSEDSIGNAL */
		logic signed [31:0] am_cos_shifted;
		/* verilator lint_on UNUSEDSIGNAL */
		begin
			am_cos_wide  = $signed(Am_sq0_15) * $signed(cos_sq1_15); // 16x16 -> 32
			am_cos_shifted = am_cos_wide >>> 15;
			am_cos_q1_15   = am_cos_shifted[15:0];              // -> SQ1.15

			// 1.0 in Q1.15 is 0x8000 (when treated unsigned); do signed arithmetic around it
			m_signed = $signed({1'b0,16'h8000}) - $signed({am_cos_q1_15[15], am_cos_q1_15});

			// // clamp to [0, 0xFFFF] (UQ1.15)
			// if (m_signed <= 0)
			// 	ww_mod_uq1_15 = 16'd0;
			// else if (m_signed >= 17'sd65535)
			// 	ww_mod_uq1_15 = 16'hFFFF;
			// else
			// 	ww_mod_uq1_15 = m_signed[15:0];

			// Clamp modulation to [0, 1.0]
			// 1.0 in UQ1.15 is 0x8000
			if (m_signed <= 0)
				ww_mod_uq1_15 = 16'd0;
			else if (m_signed >= 17'sd32768)   // 0x8000
				ww_mod_uq1_15 = 16'h8000;
			else
				ww_mod_uq1_15 = m_signed[15:0];

		end
	endfunction

	// Helper: compute E = G * M, where G is UQ0.15 and M is UQ1.15 => E is UQ1.15
	function automatic logic [15:0] ww_env_uq1_15(
		input logic [15:0] G_uq0_15,
		input logic [15:0] M_uq1_15
	);
		/* verilator lint_off UNUSEDSIGNAL */
		logic [31:0] prod_uq1_30;
		/* verilator lint_on UNUSEDSIGNAL */
		begin
			prod_uq1_30  = $unsigned(G_uq0_15) * $unsigned(M_uq1_15);
			ww_env_uq1_15 = prod_uq1_30[30:15]; // UQ1.15
		end
	endfunction

	// Compute modulation M[n],M[n+1],M[n-1] (only meaningful in WW mode)
	logic [15:0] M_n, M_p1, M_m1;
	assign M_n  = ww_mod_uq1_15(cmd_Am_q, cos_n);
	assign M_p1 = ww_mod_uq1_15(cmd_Am_q, cos_n_p1);
	assign M_m1 = ww_mod_uq1_15(cmd_Am_q, cos_n_m1);

	// Compute envelope E[*] as UQ1.15.
	// In DRAG mode, promote G (UQ0.15) into UQ1.15 by zero-extending MSB.
	logic [15:0] E_n, E_p1, E_m1;

	wire [15:0] G0_as_uq1_15 = {1'b0, G_n[14:0]};
	wire [15:0] Gp_as_uq1_15 = {1'b0, G_n_plus_1[14:0]};
	wire [15:0] Gm_as_uq1_15 = {1'b0, G_n_minus_1[14:0]};

	wire [15:0] E0_ww = ww_env_uq1_15(G_n,         M_n);
	wire [15:0] Ep_ww = ww_env_uq1_15(G_n_plus_1,   M_p1);
	wire [15:0] Em_ww = ww_env_uq1_15(G_n_minus_1,  M_m1);

	assign E_n  = cmd_use_ww_q ? E0_ww : G0_as_uq1_15;
	assign E_p1 = cmd_use_ww_q ? Ep_ww : Gp_as_uq1_15;
	assign E_m1 = cmd_use_ww_q ? Em_ww : Gm_as_uq1_15;

	// -------------------------
	// 4) DRAG quadrature from FULL envelope E[n]
	//    - first: D[0]     = E[1] - E[0]
	//    - last : D[L-1]   = E[L-1] - E[L-2]
	//    - else : D[n]     = (E[n+1] - E[n-1])/2
	//
	// E is UQ1.15; differences fit in signed Q2.15-ish, use 17b/18b signed.
	// -------------------------

	logic signed [17:0] D_n; // signed with ~15 frac bits; sized for safety
	always_comb begin
		if (out_counter_q == 16'd0) begin
			D_n = $signed({1'b0, E_p1}) - $signed({1'b0, E_n});
		end else if (out_last) begin
			D_n = $signed({1'b0, E_n}) - $signed({1'b0, E_m1});
		end else begin
			D_n = ($signed({1'b0, E_p1}) - $signed({1'b0, E_m1})) >>> 1;
		end
	end

	// -------------------------
	// 5) Output assembly and saturation
	//
	// I:
	//   amp (SQ0.15) * E (UQ1.15) => SQ1.30
	//   >>>15 => SQ1.15, then saturate to SQ0.15 for DAC
	//
	// Q:
	//   beta (SQ0.15) * amp (SQ0.15) * D (signed ~Q2.15) => wide
	//   shift to ~Q?.15 and saturate to SQ0.15
	// -------------------------

	function automatic logic signed [15:0] sat_sq0_15(input logic signed [31:0] x_qn_15);
		begin
			if (x_qn_15 > 32'sd32767)
				sat_sq0_15 = 16'sh7FFF;
			else if (x_qn_15 < -32'sd32768)
				sat_sq0_15 = 16'sh8000;
			else
				sat_sq0_15 = x_qn_15[15:0];
		end
	endfunction

	// I path
	logic signed [31:0] i_q1_15;
	assign i_q1_15 = ($signed(cmd_amp_q) * $signed({1'b0, E_n})) >>> 15; // -> SQ1.15

	// Q path
	logic signed [47:0] q_wide;
	/* verilator lint_off UNUSEDSIGNAL */
	logic signed [47:0] q_shifted;
	/* verilator lint_on UNUSEDSIGNAL */
	logic signed [31:0] q_qn_15;
	assign q_wide  = $signed(cmd_beta_q) * $signed(cmd_amp_q) * $signed(D_n); // wide signed
	assign q_shifted = q_wide >>> 30;
	assign q_qn_15   = q_shifted[31:0];

	// Handle output
	assign out_val = (state_q == BUSY);
	assign out_i   = sat_sq0_15(i_q1_15);
	assign out_q   = sat_sq0_15(q_qn_15);


endmodule
