
// Gaussian module encapsulating datapath logic for computing Gaussian samples
module gaussian_datapath (
	input  logic			   en, // enable
    input  logic [15:0]        n,  // sample index
    input  logic [15:0]        mu,
    input  logic [31:0]        inv_sigma_square,
    output logic [15:0]        G_n // Gaussian envelope
);
	timeunit 1ns;
	timeprecision 1ps;

	// Gaussian datapath using exp(-x) LUT with domain x in [0,16) encoded as Q4.6.
	//
	// Fixed-point assumptions:
	// - n, mu: UQ16.0 (sample index)
	// - inv_sigma_square: UQ1.31 representing (1/sigma^2)
	// - exp_arg x = (n-mu)^2 * (1/(2*sigma^2)) => UQ33.31 after >>1
	// - LUT address is Q4.6 taken directly from x around the binary point:
	//     addr = floor(x * 64)  for x in [0,16)  (i.e., addr = x[3:0].[5:0])
	//   Implemented by taking bits [34:25] from UQ33.31 value.
	// - LUT output: UQ0.15 stored in 16 bits
	//
	// Clamp:
	// - If x >= 15*ln(2) ~= 10.397, then exp(-x) < 2^-15 and LUT output should be 0.
	// - x_max in UQ33.31: round(10.397 * 2^31) = 22327833539 (rounded).

    // (n - mu), signed
    logic signed [16:0] n_minus_mu; // extra bit prevents overflow on subtraction
    assign n_minus_mu = $signed({1'b0, n}) - $signed({1'b0, mu});

    // (n - mu)^2, unsigned
    logic [33:0] n_minus_mu_sq; // 17b * 17b = 34b
    assign n_minus_mu_sq = $signed(n_minus_mu) * $signed(n_minus_mu);

    // x = (n-mu)^2 * (1/sigma^2) / 2
    // n_minus_mu_sq: UQ34.0, inv_sigma_square: UQ1.31 => product UQ35.31 (fits in 66b)
    logic [65:0] prod;
    logic [65:0] x_uq33_31_ext;
    assign prod         = n_minus_mu_sq * inv_sigma_square;
    assign x_uq33_31_ext = prod >> 1; // divide by 2

    // Clamp threshold for x >= 10.397 (15*ln(2)) in UQ33.31
    localparam logic [65:0] X_MAX_UQ33_31 = 66'd22327833539;

    logic lut_en;
    assign lut_en = (x_uq33_31_ext < X_MAX_UQ33_31);

    // LUT address: Q4.6 bits around the decimal point of UQ33.31
    // Q4.6 address corresponds to bits [34:31] (integer 2^3..2^0) and [30:25] (2^-1..2^-6).
    logic [9:0] lut_addr;
    assign lut_addr = x_uq33_31_ext[34:25];

    logic [15:0] lut_out;

    // LUT for y = exp(-x)
    exp_lut_1024 u_exp_lut_1024 (
        .en  (lut_en),
        .x   (lut_addr),
        .y   (lut_out)
    );

	// clamp output to 0 if enable is de-asserted
	assign G_n = en ? lut_out : '0;

endmodule
