module tx #(
	parameter int unsigned W = 16,  // sample_data width
	parameter int unsigned P = 32,  // jesd_tx_data width (parallel interface width); requires P>=W
	parameter time         T_CQ = 1ns
) (
	// Clock/resets
	input  logic           clk,
	input  logic           rst_n,

	// Sample interface
	input  logic           sample_val,
	output logic           sample_rdy,
	input  logic [W-1:0]   sample_dat,

	// JESD core interface
	output logic           jesd_tx_rst_n,
	output logic           jesd_tx_en,
	input  logic           jesd_cgs_done,
	input  logic           jesd_ilas_done,
	input  logic           jesd_link_up,
	output logic           jesd_tx_val,
	input  logic           jesd_tx_rdy,
	output logic [P-1:0]   jesd_tx_dat
);
	timeunit 1ns;
	timeprecision 1ps;

	// Simulation-time assertion to ensure P >= W
	initial begin : PARAMETER_CHECK
		// pragma synthesis_off
		if (P < W) begin
			$error("Error in tx module: Parameter P (jesd_tx_data width) must be >= W (sample_data width). P=%0d W=%0d", P, W);
		end
		// pragma synthesis_on
	end

	logic payload_allowed;
	logic skid_buffer_val;
	logic skid_buffer_rdy;
	logic [W-1:0] skid_buffer_dat;

	// Assigns
	assign payload_allowed = jesd_cgs_done & jesd_ilas_done & jesd_link_up;

	// Skid buffer to connect the val/rdy/dat interfaces of incoming sample and outgoing JESD core
	// note: skid buffer invariant: downstream_val & downstream_rdy constitutes a downstream transfer
	skid_buffer #(.W(W), .T_CQ(T_CQ)) inst_skid_buffer (
	.clk           (clk),
	.rst_n         (rst_n),
	.upstream_val  (sample_val),
	.upstream_rdy  (sample_rdy),
	.upstream_dat  (sample_dat),
	.downstream_val(skid_buffer_val),
	.downstream_rdy(skid_buffer_rdy),
	.downstream_dat(skid_buffer_dat)
	);
	assign jesd_tx_val = skid_buffer_val & payload_allowed;
	assign skid_buffer_rdy = jesd_tx_rdy & payload_allowed;
	assign jesd_tx_dat = { {(P-W){1'b0}}, skid_buffer_dat };

	// jesd_tx reset and enable
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			jesd_tx_rst_n <= #T_CQ 1'b0;
			jesd_tx_en    <= #T_CQ 1'b0;
		end else begin
			jesd_tx_rst_n <= #T_CQ 1'b1;
			jesd_tx_en    <= #T_CQ 1'b1;
		end
	end

endmodule
