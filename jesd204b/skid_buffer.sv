module skid_buffer #(
	parameter int unsigned W = 16,
	parameter time         T_CQ = 1ns
) (
	// Clock/resets
	input  logic           clk,
	input  logic           rst_n,

	// Upstream
	input  logic           upstream_val,
	output logic           upstream_rdy,
	input  logic [W-1:0]   upstream_dat,

	// Downstream
	output logic           downstream_val,
	input  logic           downstream_rdy,
	output logic [W-1:0]   downstream_dat
);

	timeunit 1ns;
	timeprecision 1ps;

	logic upstream_xfer, downstream_xfer;
	logic buffer_full;
	logic [W-1:0] buffer_d, buffer_q;
	logic push, pop, has_bypassed;

	// Assigns
	assign downstream_xfer = downstream_val & downstream_rdy;
	assign upstream_xfer = upstream_val & upstream_rdy;
	assign downstream_val = buffer_full || upstream_val;
	assign downstream_dat = buffer_full ? buffer_q : upstream_dat;

	// push to buffer if upstream transfer occurrs & hasn't bypassed
	assign has_bypassed = !buffer_full & downstream_xfer;
	assign push = upstream_xfer & !has_bypassed;

	// pop buffer if downstream transfer occurrs & buffer is full
	// (the downstream transfer must have come from the buffer)
	assign pop = buffer_full & downstream_xfer;

	// ready for upstream if:
	// - buffer isn't full, or
	// - if downstream just consumed (which means our buffer is becoming empty)
	assign upstream_rdy = !buffer_full || downstream_rdy;
	assign buffer_d = upstream_dat;

	// Sequential blocks. keep them simple
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			buffer_q <= #T_CQ '0;
			buffer_full <= #T_CQ '0;
		end else if (!push & pop) begin
			buffer_q <= #T_CQ '0; // cleared
			buffer_full <= #T_CQ '0;
		end else if (push & !pop) begin
			buffer_q <= #T_CQ buffer_d; // push
			buffer_full <= #T_CQ '1;
		end else if (push & pop) begin
			buffer_q <= #T_CQ buffer_d; // push
			buffer_full <= #T_CQ '1;
		end else begin // !push & !pop
			// stay put
			buffer_q <= #T_CQ buffer_q;
			buffer_full <= #T_CQ buffer_full;
		end
	end

endmodule
