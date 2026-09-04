// Shared RV32I mnemonic decoder for testbenches.
`ifndef RISCV_DECODE_VH
`define RISCV_DECODE_VH

// Decodes the RV32I instruction to an 8-character mnemonic string.
task get_mnemonic;
    input  [31:0] i;
    output reg [8*8-1:0] m;
    begin
        case (i[6:0])
            7'b0110011: begin                      // R-type
                case (i[14:12])
                    3'b000: m = (i[31:25] == 7'b0100000) ? "SUB" : "ADD";
                    3'b001: m = "SLL";
                    3'b010: m = "SLT";
                    3'b011: m = "SLTU";
                    3'b100: m = "XOR";
                    3'b101: m = (i[31:25] == 7'b0100000) ? "SRA" : "SRL";
                    3'b110: m = "OR";
                    3'b111: m = "AND";
                    default: m = "????";
                endcase
            end
            7'b0010011: begin                      // I-type arithmetic
                case (i[14:12])
                    3'b000: m = "ADDI";
                    3'b001: m = "SLLI";
                    3'b010: m = "SLTI";
                    3'b011: m = "SLTIU";
                    3'b100: m = "XORI";
                    3'b101: m = (i[31:25] == 7'b0100000) ? "SRAI" : "SRLI";
                    3'b110: m = "ORI";
                    3'b111: m = "ANDI";
                    default: m = "????";
                endcase
            end
            7'b0000011: begin                      // loads
                case (i[14:12])
                    3'b000: m = "LB";
                    3'b001: m = "LH";
                    3'b010: m = "LW";
                    3'b100: m = "LBU";
                    3'b101: m = "LHU";
                    default: m = "????";
                endcase
            end
            7'b0100011: begin                      // stores
                case (i[14:12])
                    3'b000: m = "SB";
                    3'b001: m = "SH";
                    3'b010: m = "SW";
                    default: m = "????";
                endcase
            end
            7'b1100011: begin                      // branches
                case (i[14:12])
                    3'b000: m = "BEQ";
                    3'b001: m = "BNE";
                    3'b100: m = "BLT";
                    3'b101: m = "BGE";
                    3'b110: m = "BLTU";
                    3'b111: m = "BGEU";
                    default: m = "????";
                endcase
            end
            7'b0110111: m = "LUI";
            7'b0010111: m = "AUIPC";
            7'b1101111: m = "JAL";
            7'b1100111: m = "JALR";
            7'b1110011: begin                      // SYSTEM: CSR / mret
                if (i == 32'h30200073)
                    m = "MRET";
                else begin
                    case (i[14:12])
                        3'b001: m = "CSRRW";
                        3'b010: m = "CSRRS";
                        3'b011: m = "CSRRC";
                        3'b101: m = "CSRRWI";
                        3'b110: m = "CSRRST";
                        3'b111: m = "CSRRCI";
                        default: m = "SYS";
                    endcase
                end
            end
            default:    m = "?????";
        endcase
    end
endtask

`endif