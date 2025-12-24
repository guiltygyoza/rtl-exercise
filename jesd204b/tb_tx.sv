module tb_tx;

	timeunit 1ns;
	timeprecision 1ps;

	// Parameters
	localparam int unsigned W = 16;
	localparam int unsigned P = 32;
	localparam int unsigned NUM_SAMPLES    = 500;   // number of accepted samples to send
	localparam int unsigned DRAIN_TIMEOUT  = 5000;  // max cycles to wait for scoreboard to drain at end
	localparam time T_CQ = 1ns;

	// -----------------------------------------------------------------------------
	// Optional VCD dump: enable with +VCD
	// -----------------------------------------------------------------------------
	initial begin
		if ($test$plusargs("VCD")) begin
			$dumpfile("tb_tx.vcd");
			$dumpvars(0, tb_tx);
		end
	end

	// JESD core state machine thresholds (TB model)
	localparam int unsigned CGS_CYCLES      = 12;  // cycles of CGS before cgs_done
	localparam int unsigned ILAS_XFERS_CYCLE  = 20;  // "val&rdy" beats during ILAS before ilas_done

	// Clock/reset
	logic clk;
	logic rst_n;

	// Sample interface; TB driving DUT
	logic           sample_val;
	logic           sample_rdy;
	logic [W-1:0]   sample_dat;

	// JESD core status inputs to DUT
	logic jesd_cgs_done;
	logic jesd_ilas_done;
	logic jesd_link_up;

	// JESD core data interface
	logic           jesd_tx_rst_n;
	logic           jesd_tx_en;
	logic           jesd_tx_val;
	logic           jesd_tx_rdy;
	logic [P-1:0]   jesd_tx_dat;

	// Instantiate DUT
	tx #(.W(W), .P(P), .T_CQ(T_CQ)) dut (
		.clk          (clk),
		.rst_n        (rst_n),

		.sample_val   (sample_val),
		.sample_rdy   (sample_rdy),
		.sample_dat   (sample_dat),

		.jesd_tx_rst_n(jesd_tx_rst_n),
		.jesd_tx_en   (jesd_tx_en),
		.jesd_cgs_done(jesd_cgs_done),
		.jesd_ilas_done(jesd_ilas_done),
		.jesd_link_up (jesd_link_up),
		.jesd_tx_val  (jesd_tx_val),
		.jesd_tx_rdy  (jesd_tx_rdy),
		.jesd_tx_dat  (jesd_tx_dat)
	);

	// Clock generation: 100 MHz
	initial clk = 1'b0;
	always #5 clk = ~clk; // 5ns

	// Reset
	initial begin
		rst_n = 1'b0;

		jesd_cgs_done  = 1'b0;
		jesd_ilas_done = 1'b0;
		jesd_link_up   = 1'b0;

		jesd_tx_rdy = 1'b0;

		repeat (5) @(posedge clk);
		rst_n = 1'b1;
	end

	// -----------------------------------------------------------------------------
	// TB model of JESD core link sequencing: RST -> CGS -> ILAS -> DATA
	// -----------------------------------------------------------------------------
	typedef enum logic [1:0] {
		S_RST  = 2'd0,
		S_CGS  = 2'd1,
		S_ILAS = 2'd2,
		S_DATA= 2'd3
	} state_t;
	state_t state;

	int unsigned cgs_cnt;
	int unsigned ilas_cnt;
	logic inject_link_drops;

	// Model downstream readiness from PHY with occasional backpressure (in all states)
	// - In DATA, this affects real payload transfers
	// - In ILAS, this affects ILAS progress
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			jesd_tx_rdy <= #T_CQ 1'b0;
		end else begin
			// Simple pseudo-random backpressure pattern
			// 75% ready, 25% not-ready
			jesd_tx_rdy <= #T_CQ ($urandom_range(0,3) != 0);
		end
  	end

	// Core sequencing outputs (cgs_done/ilas_done/link_up)
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state          <= S_RST;
			cgs_cnt        <= 0;
			ilas_cnt       <= 0;
			jesd_cgs_done  <= #T_CQ 1'b0;
			jesd_ilas_done <= #T_CQ 1'b0;
			jesd_link_up   <= #T_CQ 1'b0;
			inject_link_drops <= 1'b1;
		end else begin
			// default
			state          <= state;
			cgs_cnt        <= cgs_cnt;
			ilas_cnt       <= ilas_cnt;
			jesd_cgs_done  <= #T_CQ jesd_cgs_done;
			jesd_ilas_done <= #T_CQ jesd_ilas_done;
			jesd_link_up   <= #T_CQ jesd_link_up;
			inject_link_drops <= inject_link_drops;

			unique case (state)

				S_RST: begin
					// Hold statuses low until DUT has enabled core and released reset.
					jesd_cgs_done  <= #T_CQ 1'b0;
					jesd_ilas_done <= #T_CQ 1'b0;
					jesd_link_up   <= #T_CQ 1'b0;
					cgs_cnt        <= 0;
					ilas_cnt       <= 0;

					if (jesd_tx_rst_n && jesd_tx_en) begin
						state <= S_CGS;
					end
				end

				S_CGS: begin
					// CGS -> ILAS when a simple cycle counter reaches threshold
					jesd_cgs_done  <= #T_CQ 1'b0;
					jesd_ilas_done <= #T_CQ 1'b0;
					jesd_link_up   <= #T_CQ 1'b0;

					if (cgs_cnt == (CGS_CYCLES-1)) begin
						jesd_cgs_done <= #T_CQ 1'b1;
						state         <= S_ILAS;
						ilas_cnt      <= 0;
					end else begin
						cgs_cnt <= cgs_cnt + 1;
					end
        		end

				S_ILAS: begin
					// ILAS -> DATA when counter increments ONLY on "downstream val&rdy"
					jesd_ilas_done <= #T_CQ 1'b0;
					jesd_link_up   <= #T_CQ 1'b0;

					if (jesd_tx_rdy) begin
						if (ilas_cnt == (ILAS_XFERS_CYCLE-1)) begin
							jesd_ilas_done <= #T_CQ 1'b1;
							jesd_link_up   <= #T_CQ 1'b1;
							state       <= S_DATA;
						end else begin
							ilas_cnt <= ilas_cnt + 1;
						end
					end
				end

				S_DATA: begin
					// In DATA: all status high unless we inject a drop event.
					jesd_cgs_done  <= #T_CQ 1'b1;
					jesd_ilas_done <= #T_CQ 1'b1;
					jesd_link_up   <= #T_CQ 1'b1;

					// Inject link drop at 5% probability to verify DUT stalls payload.
					// Disabled during end-of-test drain to ensure the expected queue can empty.
					if (inject_link_drops && ($urandom_range(0,19) == 0)) begin
						jesd_link_up <= #T_CQ 1'b0;
					end
				end

				default: state <= S_RST;
      		endcase
    	end
  	end

	// -----------------------------------------------------------------------------
	// Driver
	// -----------------------------------------------------------------------------
	// Queue for samples
	logic [W-1:0] expected_sample_queue[$];

	// Drive samples: keep sample_val high most of the time with changing data,
	// but only advance data when a transfer occurs (sample_val && sample_rdy).
	int unsigned dut_ingested_samples;
	int unsigned matched_samples;
	logic [W-1:0] drv_dat_q;
	logic         drv_val_q;

	// Clocking block driver to avoid TB updates exactly at posedge sampling time
	/* verilator lint_off UNUSEDSIGNAL */
	/* verilator lint_off UNDRIVEN */
	clocking drv_cb @(posedge clk);
		// samples input at posedge clk + 1step; 1step is the simulator's smallest time unit
	    // output takes effect at posedge clk + 1ns
		default input #1step output #1ns;
		output sample_val, sample_dat;
		input  sample_rdy;
	endclocking
	/* verilator lint_on UNDRIVEN */
	/* verilator lint_on UNUSEDSIGNAL */

	initial begin
		// Initialize drive state
		drv_val_q = 1'b0;
		drv_dat_q = 16'h1000;
		dut_ingested_samples = 0;
		matched_samples = 0;
		expected_sample_queue.delete();

		// Drive initial values (applied with clocking output skew)
		drv_cb.sample_val <= drv_val_q;
		drv_cb.sample_dat <= drv_dat_q;

		// Wait for reset deassertion
		@(posedge rst_n);

		forever begin
			@drv_cb; // posedge clk event; inputs sampled with #1step, outputs updated with #1ns

			// Only drive samples during S_DATA; otherwise hold sample_val low
			if (state == S_DATA) begin
				// Determine whether a transfer occurred at THIS clock edge (using the DUT-visible signals)
				if (sample_val && drv_cb.sample_rdy) begin
					drv_dat_q = drv_dat_q + 16'h0001;
					dut_ingested_samples = dut_ingested_samples + 1;
				end

				// Drive exactly NUM_SAMPLES transfers into the DUT, then stop and allow drain.
				drv_val_q = (dut_ingested_samples < NUM_SAMPLES);

				drv_cb.sample_val <= drv_val_q;
				drv_cb.sample_dat <= drv_dat_q;
			end else begin
				drv_val_q = 1'b0;
				drv_cb.sample_val <= 1'b0;
				drv_cb.sample_dat <= drv_dat_q;
			end
		end
	end

	// -----------------------------------------------------------------------------
	// Scoreboard
	// -----------------------------------------------------------------------------
	// Check: DUT must not assert jesd_tx_val when payload transfer is not allowed
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			// no-op in reset
		end else begin
			if (!(jesd_cgs_done && jesd_ilas_done && jesd_link_up) && jesd_tx_val) begin
				$fatal(1, "ERROR: jesd_tx_val asserted when payload not allowed. time=%0t", $time);
			end
		end
	end

	// Scoreboard: on each JESD payload transfer, compare to expected queue.
	// Note: we are driving at a clock skew, but checking right at the clock edge, which means:
	// - samples driven at clock edge i + skew would be logged in queue at clock edge i+1
	// - samples arriving at clock edge i + skew would be processed at clock edge i+1
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			// no-op in reset
			matched_samples <= 0;
		end else begin
			if (sample_val && sample_rdy) begin
				expected_sample_queue.push_back(sample_dat);
			end

			if (jesd_tx_val && jesd_tx_rdy) begin
				if (expected_sample_queue.size() == 0) begin
					$fatal(1, "ERROR: JESD transfer with empty expected queue. time=%0t", $time);
				end else begin
					logic [W-1:0] expected_sample;

					// Pop from expected sample queue and compare against the sample sent by DUT
					expected_sample = expected_sample_queue.pop_front();
					if (jesd_tx_dat[W-1:0] !== expected_sample) begin // DUT samples are just zero-padded
						$fatal(1,
							"ERROR: Data mismatch. exp=%0h got=%0h (jesd_tx_dat=%0h) time=%0t",
							expected_sample, jesd_tx_dat[W-1:0], jesd_tx_dat, $time
						);
					end

					// Upper bits should be zero because of zero-padded
					if (P > W && jesd_tx_dat[P-1:W] !== '0) begin
						$fatal(1, "ERROR: Upper bits not zero. Upper bits: %b, jesd_tx_dat=%0h time=%0t",
							jesd_tx_dat[P-1:W], jesd_tx_dat, $time
						);
					end

					// If we got here, the sample matched
					matched_samples <= matched_samples + 1;
				end
			end
		end
	end

	// Checks on JESD reset and enable produced by DUT
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			if (jesd_tx_rst_n !== 1'b0) $fatal(1, "ERROR: jesd_tx_rst_n must be 0 in reset");
			if (jesd_tx_en    !== 1'b0) $fatal(1, "ERROR: jesd_tx_en must be 0 in reset");
		end else begin
			// no-op out of reset
		end
	end

	// End condition
	initial begin
		// Wait for reset deassertion
		@(posedge rst_n);

		// Wait until we've injected the desired number of samples
		wait (dut_ingested_samples == NUM_SAMPLES);

		// Stop link drops so we can deterministically drain
		inject_link_drops = 1'b0;

		// Drain: finish when the expected queue empties, but fail if it doesn't within DRAIN_TIMEOUT cycles
		fork
			begin : wait_empty
				wait (expected_sample_queue.size() == 0);
				$display("-----------------------------------------------------------");
				$display("PASS: Completed simulation. expected_sample_queue is empty.");
				$display("Matched samples = %0d (dut_ingested_samples=%0d)", matched_samples, dut_ingested_samples);
				$display("-----------------------------------------------------------");
				$finish;
			end
			begin : timeout
				repeat (DRAIN_TIMEOUT) @(posedge clk);
				$fatal(1, "ERROR: Timeout draining expected_sample_queue. Remaining = %0d", expected_sample_queue.size());
			end
		join_any
		disable fork;
	end

endmodule
