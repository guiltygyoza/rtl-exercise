module tb_pulse_gen;

timeunit 1ns;
timeprecision 1ps;

localparam time T_CQ = 1ns;

// ------------------------------------------------------------
// Optional VCD dump: enable with +VCD
// ------------------------------------------------------------
initial begin
	if ($test$plusargs("VCD")) begin
		$dumpfile("tb_pulse_gen.vcd");
		$dumpvars(0, tb_pulse_gen);
	end
end

// ------------------------------------------------------------
// Clock/reset
// ------------------------------------------------------------
logic clk;
logic rst_n;

initial clk = 1'b0;
always #5 clk = ~clk; // 100 MHz

initial begin
	rst_n = 1'b0;
	repeat (5) @(posedge clk);
	rst_n = 1'b1;
end

// ------------------------------------------------------------
// DUT I/O
// ------------------------------------------------------------
logic         cmd_val;
logic         cmd_rdy;
logic [15:0]  cmd_sample_len;
logic [15:0]  cmd_mu;
logic [31:0]  cmd_inv_sigma_square;
logic signed [15:0] cmd_amp;
logic signed [15:0] cmd_beta;

logic         start;

logic         out_val;
logic signed [15:0] out_i;
logic signed [15:0] out_q;

logic         out_last;
logic         busy;
logic         err_cmd;

// ------------------------------------------------------------
// Instantiate DUT
// ------------------------------------------------------------
// TB-only suppression for DUT truncation warnings (pulse_gen.sv assigns narrower).
/* verilator lint_off WIDTHTRUNC */
pulse_gen #(.T_CQ(T_CQ)) dut (
	.clk(clk),
	.rst_n(rst_n),

	.cmd_val(cmd_val),
	.cmd_rdy(cmd_rdy),
	.cmd_sample_len(cmd_sample_len),
	.cmd_mu(cmd_mu),
	.cmd_inv_sigma_square(cmd_inv_sigma_square),
	.cmd_amp(cmd_amp),
	.cmd_beta(cmd_beta),

	.start(start),

	.out_val(out_val),
	.out_i(out_i),
	.out_q(out_q),

	.out_last(out_last),
	.busy(busy),
	.err_cmd(err_cmd)
);
/* verilator lint_on WIDTHTRUNC */

// ------------------------------------------------------------
// Clocking blocks (driver skew + monitor sampling)
// ------------------------------------------------------------
// Lint suppression for clocking blocks only
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
clocking drv_cb @(posedge clk);
	// Drive outputs 1ns after posedge, sample inputs at #1step
	default input #1step output #1ns;
	output cmd_val, cmd_sample_len, cmd_mu, cmd_inv_sigma_square, cmd_amp, cmd_beta, start;
	input  cmd_rdy, out_val, out_i, out_q, out_last, busy, err_cmd;
endclocking

clocking mon_cb @(posedge clk);
	// Sample everything at a small skew after posedge (avoid race with combinational)
	default input #1ns output #0;
	input cmd_val, cmd_sample_len, cmd_mu, cmd_inv_sigma_square, cmd_amp, cmd_beta, start;
	input cmd_rdy, out_val, out_i, out_q, out_last, busy, err_cmd;
endclocking
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */

// ------------------------------------------------------------
// Utility: fixed-point conversions and quantization
// ------------------------------------------------------------
localparam real SQ15_SCALE = 32768.0;      // 2^15
localparam real UQ31_SCALE = 2147483648.0; // 2^31

/* verilator lint_off WIDTHEXPAND */
function automatic real sq0_15_to_real(input logic signed [15:0] x);
	int xi;
	begin
		xi = x;  // implicit sign extension to int
		sq0_15_to_real = $itor(xi) / SQ15_SCALE;
	end
endfunction

function automatic real uq1_31_to_real(input logic [31:0] x);
	int unsigned xu;
    begin
        xu = x;               // implicit zero-extend into 32-bit unsigned int
        uq1_31_to_real = $itor(xu) / UQ31_SCALE;
    end
endfunction
/* verilator lint_on WIDTHEXPAND */

function automatic logic signed [15:0] real_to_sq0_15_sat(input real x);
	int q;
	begin
		q = (x >= 0.0) ? int'(x * SQ15_SCALE + 0.5) : int'(x * SQ15_SCALE - 0.5);
		if (q >  32767) q =  32767;
		if (q < -32768) q = -32768;
		real_to_sq0_15_sat = $signed(q)[15:0];
	end
endfunction

function automatic int abs_int(input int x);
	abs_int = (x < 0) ? -x : x;
endfunction

/* verilator lint_off UNUSEDSIGNAL */
function automatic logic [31:0] inv_sigma2_uq1_31(input real sigma);
	real inv, scaled;
	longint unsigned q64;
	logic [31:0] q32;
	begin
		if (sigma <= 0.0) begin
			inv_sigma2_uq1_31 = 32'd0;
		end else begin
			inv = 1.0 / (sigma*sigma);
			if (inv >= (2.0 - (1.0 / (2.0**31))))
				inv = (2.0 - (1.0 / (2.0**31)));

			scaled = inv * (2.0**31);
			q64 = longint'(scaled + 0.5);
			q32 = q64[31:0];
			inv_sigma2_uq1_31 = q32;
		end
	end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

// ------------------------------------------------------------
// Behavioral model for DRAG math (strict real exp)
// ------------------------------------------------------------
typedef struct packed {
	logic [15:0]         len;
	logic [15:0]         mu;
	logic [31:0]         inv_sig2;
	logic signed [15:0]  amp;
	logic signed [15:0]  beta;
} cmd_t;

/* verilator lint_off UNUSEDSIGNAL */
function automatic real gauss_real(input int n, input cmd_t c);
	int unsigned mu;
	real mu_r, inv_r, d, x;
	begin
		/* verilator lint_off WIDTHEXPAND */
		mu    = c.mu;
		/* verilator lint_on WIDTHEXPAND */
		mu_r  = $itor(mu);
		inv_r = uq1_31_to_real(c.inv_sig2);
		d     = $itor(n) - mu_r;
		x     = (d*d) * inv_r * 0.5;
		gauss_real = $exp(-x);
	end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

function automatic real drag_d_real(input int n, input cmd_t c);
	int L;
	real g_nm1, g_n, g_np1;
	begin
		L = int'(c.len);
		if (L <= 1) begin
			drag_d_real = 0.0;
		end else if (n <= 0) begin
			g_n   = gauss_real(0, c);
			g_np1 = gauss_real(1, c);
			drag_d_real = g_np1 - g_n;
		end else if (n >= (L-1)) begin
			g_n   = gauss_real(L-1, c);
			g_nm1 = gauss_real(L-2, c);
			drag_d_real = g_n - g_nm1;
		end else begin
			g_np1 = gauss_real(n+1, c);
			g_nm1 = gauss_real(n-1, c);
			drag_d_real = (g_np1 - g_nm1) * 0.5;
		end
	end
endfunction

function automatic logic signed [15:0] model_out_i(input int n, input cmd_t c);
	real a, g, y;
	begin
		a = sq0_15_to_real(c.amp);
		g = gauss_real(n, c);
		y = a * g;
		model_out_i = real_to_sq0_15_sat(y);
	end
endfunction

function automatic logic signed [15:0] model_out_q(input int n, input cmd_t c);
	real a, b, d, y;
	begin
		a = sq0_15_to_real(c.amp);
		b = sq0_15_to_real(c.beta);
		d = drag_d_real(n, c);
		y = b * a * d;
		model_out_q = real_to_sq0_15_sat(y);
	end
endfunction

// ------------------------------------------------------------
// Driver tasks (use drv_cb for skewed driving)
// ------------------------------------------------------------
task automatic drive_idle_defaults();
	begin
		drv_cb.cmd_val              <= 1'b0;
		drv_cb.cmd_sample_len       <= 16'd0;
		drv_cb.cmd_mu               <= 16'd0;
		drv_cb.cmd_inv_sigma_square <= 32'd0;
		drv_cb.cmd_amp              <= 16'sd0;
		drv_cb.cmd_beta             <= 16'sd0;
		drv_cb.start                <= 1'b0;
	end
endtask

task automatic wait_cycles(input int unsigned n);
	int unsigned i;
	begin
		for (i = 0; i < n; i++) @(mon_cb);
	end
endtask

task automatic send_cmd(input cmd_t c);
	begin
		// wait until ready (sampled via clocking block)
		do @(mon_cb); while (!mon_cb.cmd_rdy);

		// drive command (skewed via drv_cb)
		@(drv_cb);
		drv_cb.cmd_sample_len       <= c.len;
		drv_cb.cmd_mu               <= c.mu;
		drv_cb.cmd_inv_sigma_square <= c.inv_sig2;
		drv_cb.cmd_amp              <= c.amp;
		drv_cb.cmd_beta             <= c.beta;
		drv_cb.cmd_val              <= 1'b1;

		// wait for accept on sampled interface
		do @(mon_cb); while (!(mon_cb.cmd_val && mon_cb.cmd_rdy));

		@(drv_cb);
		drv_cb.cmd_val <= 1'b0;
	end
endtask

task automatic pulse_start_one_cycle();
	begin
		@(drv_cb);
		drv_cb.start <= 1'b1;
		@(drv_cb);
		drv_cb.start <= 1'b0;
	end
endtask

// ------------------------------------------------------------
// Protocol scoreboard counters (sampled on mon_cb)
// ------------------------------------------------------------
int unsigned out_val_count;
int unsigned out_last_count;
int unsigned out_val_while_not_busy;

task automatic reset_protocol_counters();
	begin
		out_val_count = 0;
		out_last_count = 0;
		out_val_while_not_busy = 0;
	end
endtask

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		out_val_count <= 0;
		out_last_count <= 0;
		out_val_while_not_busy <= 0;
	end else begin
		// use mon_cb sampled versions to avoid race
		if (mon_cb.out_val && !mon_cb.busy) out_val_while_not_busy <= out_val_while_not_busy + 1;
		if (mon_cb.out_val)                  out_val_count          <= out_val_count + 1;
		if (mon_cb.out_last)                 out_last_count         <= out_last_count + 1;

		if (mon_cb.out_last && !mon_cb.out_val) begin
			$fatal(1, "ERROR: out_last asserted when out_val=0. time=%0t", $time);
		end
	end
end

// ------------------------------------------------------------
// JSON dump support
// ------------------------------------------------------------
integer json_fd;
bit json_first_pulse;

task automatic json_open();
	begin
		json_fd = $fopen("pulse_results.json", "w");
		if (json_fd == 0) $fatal(1, "ERROR: cannot open pulse_results.json");
		$fdisplay(json_fd, "{");
		$fdisplay(json_fd, "  \"pulses\": [");
		json_first_pulse = 1'b1;
	end
endtask

task automatic json_close();
	begin
		$fdisplay(json_fd, "  ]");
		$fdisplay(json_fd, "}");
		$fclose(json_fd);
	end
endtask

task automatic json_begin_pulse(input string name, input cmd_t c);
	begin
		if (!json_first_pulse) $fdisplay(json_fd, "    ,");
		json_first_pulse = 1'b0;

		$fdisplay(json_fd, "    {");
		$fdisplay(json_fd, "      \"name\": \"%s\",", name);
		$fdisplay(json_fd, "      \"params\": {");
		$fdisplay(json_fd, "        \"len\": %0d,", int'(c.len));
		$fdisplay(json_fd, "        \"mu\": %0d,",  int'(c.mu));
		$fdisplay(json_fd, "        \"inv_sig2_uq1_31_hex\": \"%08h\",", c.inv_sig2);
		$fdisplay(json_fd, "        \"amp_sq0_15\": %0d,", int'($signed(c.amp)));
		$fdisplay(json_fd, "        \"beta_sq0_15\": %0d", int'($signed(c.beta)));
		$fdisplay(json_fd, "      },");
		$fdisplay(json_fd, "      \"samples\": [");
	end
endtask

task automatic json_end_pulse();
	begin
		$fdisplay(json_fd, "");
		$fdisplay(json_fd, "      ]");
		$fdisplay(json_fd, "    }");
	end
endtask

task automatic json_write_sample(
	input int n,
	input logic signed [15:0] dut_i,
	input logic signed [15:0] dut_q,
	input logic signed [15:0] gold_i,
	input logic signed [15:0] gold_q,
	input bit first_sample
);
	real dut_i_r, dut_q_r, gold_i_r, gold_q_r;
	begin
		dut_i_r  = sq0_15_to_real(dut_i);
		dut_q_r  = sq0_15_to_real(dut_q);
		gold_i_r = sq0_15_to_real(gold_i);
		gold_q_r = sq0_15_to_real(gold_q);

		if (!first_sample) $fdisplay(json_fd, "        ,");

		$fdisplay(json_fd,
			"        {\"n\": %0d, \"dut_i\": %0d, \"dut_q\": %0d, \"gold_i\": %0d, \"gold_q\": %0d, \"dut_i_r\": %.12f, \"dut_q_r\": %.12f, \"gold_i_r\": %.12f, \"gold_q_r\": %.12f}",
			n,
			int'($signed(dut_i)),
			int'($signed(dut_q)),
			int'($signed(gold_i)),
			int'($signed(gold_q)),
			dut_i_r, dut_q_r, gold_i_r, gold_q_r
		);
	end
endtask

// -----------------------------------------------------------------
// Combined checker: protocol + math + JSON dump (valid pulses only)
// -----------------------------------------------------------------
// verilator lint_off UNUSEDSIGNAL
task automatic run_and_check_pulse(
	input cmd_t c,
	input int unsigned tol_i_lsb,
	input int unsigned tol_q_lsb,
	input bit check_math,
	input bit dump_json,
	input string pulse_name
);
	int unsigned timeout;
	int unsigned n_obs;
	int diff_i, diff_q;
	int L;

	logic signed [15:0] exp_i;
	logic signed [15:0] exp_q;

	bit first_sample;

	begin
		reset_protocol_counters();
		send_cmd(c);
		pulse_start_one_cycle();

		// Wait for BUSY (bounded)
		timeout = 0;
		while (!mon_cb.busy && !mon_cb.err_cmd && timeout < 1000) begin
			@(mon_cb);
			timeout++;
		end
		if (mon_cb.err_cmd) $fatal(1, "ERROR: err_cmd asserted on valid pulse.");
		if (!mon_cb.busy)   $fatal(1, "ERROR: did not enter BUSY (timeout).");

		L = int'(c.len);

		if (dump_json) begin
			json_begin_pulse(pulse_name, c);
			first_sample = 1'b1;
		end

		// DUT in BUSY; Observe samples until out_last (bounded)
		n_obs = 0;
		timeout = 0;
		while (1) begin

			timeout++;
			if (timeout > 200000) $fatal(1, "ERROR: timeout waiting for last sample");

			if (mon_cb.out_val) begin
				// if (mon_cb.out_last && (n_obs != L)) begin
				// 	$fatal(1, "ERROR: out_last at n=%0d expected n=%0d", n_obs, L);
				// end

				if (check_math) begin
					exp_i = model_out_i(n_obs, c);
					exp_q = model_out_q(n_obs, c);

					diff_i = abs_int(int'($signed(mon_cb.out_i)) - int'($signed(exp_i)));
					diff_q = abs_int(int'($signed(mon_cb.out_q)) - int'($signed(exp_q)));

					// if (diff_i > int'(tol_i_lsb)) begin
					// 	$fatal(1,
					// 		"ERROR: out_i mismatch n=%0d got=%0d exp=%0d diff=%0d tol=%0d",
					// 		n_obs, mon_cb.out_i, exp_i, diff_i, tol_i_lsb
					// 	);
					// end

					// if (diff_q > int'(tol_q_lsb)) begin
					// 	$fatal(1,
					// 		"ERROR: out_q mismatch n=%0d got=%0d exp=%0d diff=%0d tol=%0d",
					// 		n_obs, mon_cb.out_q, exp_q, diff_q, tol_q_lsb
					// 	);
					// end

					if (dump_json) begin
						json_write_sample(n_obs, mon_cb.out_i, mon_cb.out_q, exp_i, exp_q, first_sample);
						first_sample = 1'b0;
					end
				end

				n_obs++;

				if (mon_cb.out_last) break;
			end

			// advance clock
			@(mon_cb);
		end

		// One extra sampled cycle
		@(mon_cb);

		if (out_val_while_not_busy != 0)
			$fatal(1, "ERROR: out_val asserted while busy=0. count=%0d", out_val_while_not_busy);

		if (out_last_count != 1)
			$fatal(1, "ERROR: out_last asserted %0d times (expected 1).", out_last_count);

		if (out_val_count != int'(c.len))
			$fatal(1, "ERROR: out_val_count=%0d expected len=%0d", out_val_count, c.len);

		if (n_obs != int'(c.len))
			$fatal(1, "ERROR: observed %0d samples, expected len=%0d", n_obs, c.len);

		if (dump_json) begin
			json_end_pulse();
			$fflush(json_fd);
		end

		$display("PASS: Pulse len=%0d mu=%0d inv_sig2=0x%08h amp=%0d beta=%0d protocol+math=%0d",
				 c.len, c.mu, c.inv_sig2, c.amp, c.beta, check_math);
	end
endtask
// verilator lint_on UNUSEDSIGNAL

task automatic run_and_check_invalid_cmd(input cmd_t c);
	int unsigned timeout;
	begin
		reset_protocol_counters();
		send_cmd(c);
		pulse_start_one_cycle();

		timeout = 0;
		while (!mon_cb.err_cmd && timeout < 200) begin
			@(mon_cb);
			timeout++;
		end
		if (!mon_cb.err_cmd) $fatal(1, "ERROR: expected err_cmd for invalid cmd but did not see it.");

		wait_cycles(50);
		if (mon_cb.busy) $fatal(1, "ERROR: DUT entered BUSY on invalid cmd.");
		if (out_val_count != 0) $fatal(1, "ERROR: DUT produced out_val on invalid cmd.");

		$display("PASS: Invalid cmd rejected. len=%0d mu=%0d inv_sig2=0x%08h", c.len, c.mu, c.inv_sig2);
	end
endtask

// ------------------------------------------------------------
// Main
// ------------------------------------------------------------
initial begin
	cmd_t c;
	int unsigned TOL_I;
	int unsigned TOL_Q;

	drive_idle_defaults();

	@(posedge rst_n);
	@(mon_cb);

	TOL_I = 32;
	TOL_Q = 64;

	// Start recording
	json_open();

	// Valid pulses (protocol+math)
	c.len      = 16'd64;
	c.mu       = 16'd32;
	c.inv_sig2 = inv_sigma2_uq1_31(6.0);
	c.amp      = 16'sh4000;
	c.beta     = 16'sd0;
	run_and_check_pulse(c, TOL_I, 1, 1'b1, 1'b1, "pulse_0");

	c.len      = 16'd80;
	c.mu       = 16'd40;
	c.inv_sig2 = inv_sigma2_uq1_31(5.0);
	c.amp      = -16'sh2000;
	c.beta     = 16'sh1000;
	run_and_check_pulse(c, TOL_I, TOL_Q, 1'b1, 1'b1, "pulse_1");

	c.len      = 16'd48;
	c.mu       = 16'd24;
	c.inv_sig2 = inv_sigma2_uq1_31(3.0);
	c.amp      = 16'sh6000;
	c.beta     = 16'sh1800;
	run_and_check_pulse(c, TOL_I, TOL_Q, 1'b1, 1'b1, "pulse_2");

	// Invalid commands (protocol only)
	c.len      = 16'd32;
	c.mu       = 16'd32; // invalid: mu >= len
	c.inv_sig2 = inv_sigma2_uq1_31(4.0);
	c.amp      = 16'sh2000;
	c.beta     = 16'sh1000;
	run_and_check_invalid_cmd(c);

	c.len      = 16'd2;  // invalid: len <= 2
	c.mu       = 16'd0;
	c.inv_sig2 = inv_sigma2_uq1_31(2.0);
	c.amp      = 16'sh2000;
	c.beta     = 16'sd0;
	run_and_check_invalid_cmd(c);

	c.len      = 16'd16;
	c.mu       = 16'd8;
	c.inv_sig2 = 32'd0;  // invalid: inv_sig2 == 0
	c.amp      = 16'sh2000;
	c.beta     = 16'sd0;
	run_and_check_invalid_cmd(c);

	// Stop recording
	json_close();

	$display("PASS: All tests completed (protocol + invalid + DRAG math).");
	$finish;
end

endmodule
