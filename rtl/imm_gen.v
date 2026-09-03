`timescale 1ns/1ps
// RV32I immediate generator.
//
// imm_sel encoding:
//   3'b000 : I-type   (arithmetic, loads, JALR)
//   3'b001 : S-type   (stores)
//   3'b010 : B-type   (branches, shifted left by 1)
//   3'b011 : U-type   (LUI, AUIPC, shifted left by 12)
//   3'b100 : J-type   (JAL, shifted left by 1)

module imm_gen (
    input  wire [31:0] inst,
    input  wire [ 2:0] imm_sel,
    output reg  [31:0] imm
);

    always @(*) begin
        case (imm_sel)
            3'b000 : imm = {{21{inst[31]}}, inst[30:20]};
            3'b001 : imm = {{21{inst[31]}}, inst[30:25], inst[11:7]};
            3'b010 : imm = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
            3'b011 : imm = {inst[31:12], 12'b0};
            3'b100 : imm = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
            default: imm = 32'b0;
        endcase
    end

endmodule