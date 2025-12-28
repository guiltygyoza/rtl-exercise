module pulse_gen #(
	parameter time         T_CQ = 1ns
) (
	// Clock/resets
	input  logic         clk,
	input  logic         rst_n,

	// Command handshake interface
	input  logic         cmd_val,
	output logic         cmd_rdy,
	// cmd_sample_len: 16b unsigned integer, UQ16.0
	input  logic [15:0]  cmd_sample_len,
	// cmd_mu: 16b unsigned integer w.r.t length, UQ16.0
	input  logic [15:0]  cmd_mu,
	// cmd_inv_sigma_square: UQ1.31, software precomputed 1/sigma2, with sigma being UQ8.8 and sigma minimum being 1.0 in decimal
	input  logic [31:0]  cmd_inv_sigma_square,
	// cmd_amp: 16b signed, normalized to [-1, 1); SQ0.15
	input  logic signed [15:0] cmd_amp,
	// cmd_beta: 16b signed DRAG scaling; SQ0.15
	input  logic signed [15:0] cmd_beta,

	// Explicit start trigger for pulse firing
	input  logic         start,

	// Output; no backpressure
	output logic         out_val,
	output logic signed [15:0] out_i,     // SQ0.15, [-1, 1)
	output logic signed [15:0] out_q,     // SQ0.15, [-1, 1)

	// Status
	output logic         out_last,
	output logic         busy,    // high from first valid sample to out_last cycle
	output logic         err_cmd
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
	                   (cmd_inv_sigma_square_q != 32'd0);

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
		end else if (cmd_val && cmd_rdy) begin
			cmd_sample_len_q       <= #T_CQ cmd_sample_len;
			cmd_mu_q               <= #T_CQ cmd_mu;
			cmd_inv_sigma_square_q <= #T_CQ cmd_inv_sigma_square;
			cmd_amp_q              <= #T_CQ cmd_amp;
			cmd_beta_q             <= #T_CQ cmd_beta;
		end else begin
			cmd_sample_len_q       <= #T_CQ cmd_sample_len_q;
			cmd_mu_q               <= #T_CQ cmd_mu_q;
			cmd_inv_sigma_square_q <= #T_CQ cmd_inv_sigma_square_q;
			cmd_amp_q              <= #T_CQ cmd_amp_q;
			cmd_beta_q             <= #T_CQ cmd_beta_q;
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

	// Use gaussian_datapath module to generate G_n in UQ0.15
	logic [15:0] G_n;

	gaussian_datapath u_gaussian_datapath_0 (
		.en    ('b1),
		.n     (out_counter_q),
		.mu    (cmd_mu_q),
		.inv_sigma_square(cmd_inv_sigma_square_q),
		.G_n   (G_n)
	);

	// compute DRAG quadrature term D[n] from gaussian term G[n], where n is the counter value
	// - for the first sample, D[0] = G[1] - G[0]
	// - for the last sample, D[L-1] = G[L-1] - G[L-2]
	// - otherwise, D[n] = (G[n+1] - G[n-1])/2

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

	// Compute DRAG quadrature term D[n] using the LUT outputs: G_n, G_n_plus_1, G_n_minus_1
	logic signed [15:0] D_n;
	always_comb begin
		if (out_counter_q == 16'd0) begin
			// G[1] - G[0]
			D_n = $signed(G_n_plus_1) - $signed(G_n);
		end else if (out_last) begin
			// G[L-1] - G[L-2]
			D_n = $signed(G_n) - $signed(G_n_minus_1);
		end else begin
			// (G[n+1] - G[n-1])/2
			D_n = ($signed(G_n_plus_1) - $signed(G_n_minus_1)) >>> 1;
		end
	end

	// Assemble in-phase and quadrature values
	logic signed [30:0] i_term; // amp (SQ0.15) * G_n (UQ0.15) -> SQ0.30
	assign i_term = $signed(cmd_amp_q) * $signed({1'b0, G_n});

	// beta (SQ0.15) * amp (SQ0.15) * D_n (SQ0.15) -> SQ0.45 (45 bits + 1 sign bit)
	logic signed [45:0] q_term;
	assign q_term = $signed(cmd_beta_q) * $signed(cmd_amp_q) * $signed(D_n);

	// Handle output
	// out_i and out_q are both SQ0.15
	assign out_val = (state_q == BUSY);
	assign out_i = $signed(16'(i_term >>> 15)); // $signed(i_term[30:15])
	assign out_q = $signed(16'(q_term >>> 30)); // $signed(q_term[45:30]);

endmodule
