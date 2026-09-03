`timescale 1ns/1ps
// 32-bit ALU for RV32I.
//
// Control encoding:
//   4'b0000 : A & B
//   4'b0001 : A | B
//   4'b0010 : A + B
//   4'b0011 : A ^ B
//   4'b0110 : A - B
//   4'b0111 : A < B  (signed,   result = 1 if true)
//   4'b1000 : A < B  (unsigned, result = 1 if true)
//   4'b1001 : A << B[4:0]
//   4'b1010 : A >> B[4:0] (logical)
//   4'b1011 : A >> B[4:0] (arithmetic)
//   4'b1100 : A (pass-through)
//
// The comparison flags lt_s and lt_u are always computed so that branch
// logic can use them without needing a dedicated comparator.

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [ 3:0] alu_control,
    output reg  [31:0] result,
    output wire        zero,    // result == 0
    output wire        lt_s,    // a < b (signed)
    output wire        lt_u     // a < b (unsigned)
);

    wire signed [31:0] a_s, b_s;
    assign a_s = a;
    assign b_s = b;

    assign lt_s = (a_s < b_s);
    assign lt_u = (a < b);

    always @(*) begin
        case (alu_control)
            4'b0000 : result = a & b;
            4'b0001 : result = a | b;
            4'b0010 : result = a + b;
            4'b0011 : result = a ^ b;
            4'b0110 : result = a - b;
            4'b0111 : result = {31'b0, lt_s};
            4'b1000 : result = {31'b0, lt_u};
            4'b1001 : result = a << b[4:0];
            4'b1010 : result = a >> b[4:0];
            4'b1011 : result = $signed(a) >>> b[4:0];
            4'b1100 : result = a;
            default : result = 32'hxxxxxxxx;
        endcase
    end

    assign zero = (result == 32'b0);

endmodule