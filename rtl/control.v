`timescale 1ns/1ps
// RV32I control unit (single-cycle).
//
// Decodes the opcode and produces all control signals for the datapath.
//
// Control signal encodings:
//   write_src  : 2'b00 = ALU result, 2'b01 = memory read data,
//                2'b10 = immediate (LUI)
//   alu_src_a  : 1'b0 = rs1,        1'b1 = PC
//   alu_src_b  : 2'b00 = rs2,       2'b01 = immediate, 2'b10 = 4
//   jump       : 2'b00 = none,      2'b01 = JAL,        2'b10 = JALR
//   alu_control: see alu.v
//   imm_sel    : see imm_gen.v
//   mem_size   : 2'b00 = byte, 2'b01 = half, 2'b10 = word
//   mem_sign   : 1'b1 = sign extend, 1'b0 = zero extend (loads only)

module control (
    input  wire [31:0] inst,
    output reg         reg_write,
    output reg         mem_write,
    output reg         branch,
    output reg  [ 1:0] jump,
    output reg  [ 1:0] write_src,
    output reg         alu_src_a,
    output reg  [ 1:0] alu_src_b,
    output reg  [ 3:0] alu_control,
    output reg  [ 2:0] imm_sel,
    output reg  [ 1:0] mem_size,
    output reg         mem_sign
);

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    // ALU control for R-type / I-type arithmetic based on funct3/funct7.
    function [3:0] alu_decode;
        input [2:0] f3;
        input [6:0] f7;
        begin
            case (f3)
                3'b000 : alu_decode = (f7 == 7'b0100000) ? 4'b0110 : 4'b0010; // SUB/ADD
                3'b001 : alu_decode = 4'b1001; // SLL
                3'b010 : alu_decode = 4'b0111; // SLT
                3'b011 : alu_decode = 4'b1000; // SLTU
                3'b100 : alu_decode = 4'b0011; // XOR
                3'b101 : alu_decode = (f7 == 7'b0100000) ? 4'b1011 : 4'b1010; // SRA/SRL
                3'b110 : alu_decode = 4'b0001; // OR
                3'b111 : alu_decode = 4'b0000; // AND
                default: alu_decode = 4'b0010;
            endcase
        end
    endfunction

    always @(*) begin
        // Defaults: no writeback, no memory access, PC + 4.
        reg_write   = 1'b0;
        mem_write   = 1'b0;
        branch      = 1'b0;
        jump        = 2'b00;
        write_src   = 2'b00;
        alu_src_a   = 1'b0;
        alu_src_b   = 2'b00;
        alu_control = 4'b0010;
        imm_sel     = 3'b000;
        mem_size    = 2'b10;
        mem_sign    = 1'b1;

        case (opcode)
            7'b0110111 : begin                        // LUI
                reg_write = 1'b1;
                write_src = 2'b10;                    // result = immediate
                imm_sel   = 3'b011;                   // U-type
            end
            7'b0010111 : begin                        // AUIPC
                reg_write = 1'b1;
                alu_src_a = 1'b1;                     // A = PC
                alu_src_b = 2'b01;                    // B = immediate
                alu_control = 4'b0010;                // PC + imm
                imm_sel   = 3'b011;                   // U-type
            end
            7'b1101111 : begin                        // JAL
                reg_write   = 1'b1;
                jump        = 2'b01;
                alu_src_a   = 1'b1;                   // A = PC
                alu_src_b   = 2'b10;                  // B = 4
                alu_control = 4'b0010;                // PC + 4 -> rd
                imm_sel     = 3'b100;                 // J-type
            end
            7'b1100111 : begin                        // JALR
                reg_write   = 1'b1;
                jump        = 2'b10;
                alu_src_a   = 1'b1;                   // A = PC
                alu_src_b   = 2'b10;                  // B = 4
                alu_control = 4'b0010;                // PC + 4 -> rd
                imm_sel     = 3'b000;                 // I-type
            end
            7'b1100011 : begin                        // Branches
                branch = 1'b1;
                imm_sel = 3'b010;                     // B-type
                case (funct3)
                    3'b000 : alu_control = 4'b0110;   // BEQ : subtract
                    3'b001 : alu_control = 4'b0110;   // BNE : subtract
                    3'b100 : alu_control = 4'b0111;   // BLT : signed compare
                    3'b101 : alu_control = 4'b0111;   // BGE : signed compare
                    3'b110 : alu_control = 4'b1000;   // BLTU: unsigned compare
                    3'b111 : alu_control = 4'b1000;   // BGEU: unsigned compare
                    default: alu_control = 4'b0110;
                endcase
            end
            7'b0000011 : begin                        // Loads
                reg_write = 1'b1;
                write_src = 2'b01;                    // from memory
                alu_src_b = 2'b01;                    // B = immediate
                alu_control = 4'b0010;                // address = rs1 + imm
                imm_sel   = 3'b000;                   // I-type
                case (funct3)
                    3'b000 : begin mem_size = 2'b00; mem_sign = 1'b1; end // LB
                    3'b001 : begin mem_size = 2'b01; mem_sign = 1'b1; end // LH
                    3'b010 : begin mem_size = 2'b10; mem_sign = 1'b0; end // LW
                    3'b100 : begin mem_size = 2'b00; mem_sign = 1'b0; end // LBU
                    3'b101 : begin mem_size = 2'b01; mem_sign = 1'b0; end // LHU
                    default: begin mem_size = 2'b10; mem_sign = 1'b0; end
                endcase
            end
            7'b0100011 : begin                        // Stores
                mem_write = 1'b1;
                alu_src_b = 2'b01;                    // B = immediate
                alu_control = 4'b0010;                // address = rs1 + imm
                imm_sel   = 3'b001;                   // S-type
                case (funct3)
                    3'b000 : mem_size = 2'b00;        // SB
                    3'b001 : mem_size = 2'b01;        // SH
                    3'b010 : mem_size = 2'b10;        // SW
                    default: mem_size = 2'b10;
                endcase
            end
            7'b0010011 : begin                        // I-type arithmetic/shifts
                reg_write   = 1'b1;
                alu_src_b   = 2'b01;
                alu_control = alu_decode(funct3, funct7);
                imm_sel     = 3'b000;
            end
            7'b0110011 : begin                        // R-type
                reg_write   = 1'b1;
                alu_control = alu_decode(funct3, funct7);
            end
            default : begin
                // Unsupported instruction: stall everything.
                reg_write   = 1'b0;
                mem_write   = 1'b0;
            end
        endcase
    end

endmodule