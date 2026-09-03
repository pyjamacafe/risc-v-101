// Testbench for the single-cycle RV32I core.
//
// Produces a detailed per-instruction execution log (sim.log and console):
//   cycle, time, PC, raw instruction, decoded mnemonic, register write
//   (rd <- value), memory store (address, data, byte enables) and any
//   control-flow change with the next PC.
//
// The program writes a status word to address 0x4000:
//   0x600D600D  -> TEST PASSED
//   0xDEADBEEF  -> TEST FAILED (failing PC stored at 0x4004)

`timescale 1ns/1ps

module tb_rv32i;

    localparam MEM_BYTES = 65536;
    localparam HEX_FILE  = "sw/test.hex";

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    wire [31:0] pc, inst;
    reg  [31:0] peek_addr = 32'h4000;
    wire [31:0] peek_data;

    // ---- trace ports from the core ----
    wire [ 4:0] dbg_rd;
    wire [31:0] dbg_wb_data;
    wire        dbg_reg_write;
    wire [31:0] dbg_data_addr;
    wire [ 3:0] dbg_st_wen;
    wire [31:0] dbg_st_data;
    wire [31:0] dbg_pc_next;

    rv32i_core #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE (HEX_FILE)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .dbg_pc         (pc),
        .dbg_inst       (inst),
        .dbg_peek_addr  (peek_addr),
        .dbg_peek_data  (peek_data),
        .dbg_rd         (dbg_rd),
        .dbg_wb_data    (dbg_wb_data),
        .dbg_reg_write  (dbg_reg_write),
        .dbg_data_addr  (dbg_data_addr),
        .dbg_st_wen     (dbg_st_wen),
        .dbg_st_data    (dbg_st_data),
        .dbg_pc_next    (dbg_pc_next)
    );

    always #5 clk = ~clk;      // 100 MHz clock

    integer fd, cyc, last_pc, stalls;
    reg [31:0] status;
    wire is_load  = (inst[6:0] == 7'b0000011);
    wire is_store = (inst[6:0] == 7'b0100011);

    // Decode the RV32I instruction to a mnemonic string.
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
                default:    m = "?????";
            endcase
        end
    endtask

    reg [8*8-1:0] mnem;

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_rv32i);
        fd = $fopen("sim.log", "w");

        $fwrite(fd, "================================================================\n");
        $fwrite(fd, " RV32I single-cycle core -- detailed execution log\n");
        $fwrite(fd, " legend: rd=dest reg, ld@=load address, st=store [addr] <- data\n");
        $fwrite(fd, "         CF = control flow taken -> target\n");
        $fwrite(fd, "================================================================\n");
        $fwrite(fd, "  #    time        pc       inst      mnemonic  effect\n");
        $fwrite(fd, "----------------------------------------------------------------\n");

        $display("=====================================================================");
        $display(" RV32I single-cycle core -- detailed execution log");
        $display("  #    time        pc       inst      mnemonic  effect");
        $display("---------------------------------------------------------------------");

        // Hold reset for two cycles, then deassert it mid-cycle so the
        // first post-reset sample (at pc = 0) is captured in the log.
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;

        last_pc = 0;
        stalls  = 0;
        for (cyc = 0; cyc < 500; cyc = cyc + 1) begin
            #1;                          // mid-cycle: current instruction is stable
            get_mnemonic(inst, mnem);

            //  #    time        pc       inst      mnemonic
            $fwrite(fd, "%4d  %8t  %08x  %08x  %-7s", cyc, $time, pc, inst, mnem);
            $write("%4d  %8t  %08x  %08x  %-7s", cyc, $time, pc, inst, mnem);

            if (dbg_reg_write) begin
                $fwrite(fd, "  x%0d <- %08x", dbg_rd, dbg_wb_data);
                $write("  x%0d <- %08x", dbg_rd, dbg_wb_data);
            end
            if (is_load) begin
                $fwrite(fd, "  ld@%08x", dbg_data_addr);
                $write("  ld@%08x", dbg_data_addr);
            end
            if (dbg_st_wen != 4'b0) begin
                $fwrite(fd, "  st[%08x] <- %08x wen=%04b", dbg_data_addr, dbg_st_data, dbg_st_wen);
                $write("  st[%08x] <- %08x wen=%04b", dbg_data_addr, dbg_st_data, dbg_st_wen);
            end
            if (dbg_pc_next != pc + 32'd4) begin
                $fwrite(fd, "  CF -> %08x", dbg_pc_next);
                $write("  CF -> %08x", dbg_pc_next);
            end
            $fwrite(fd, "\n");
            $write("\n");

            if (pc == last_pc) begin
                stalls = stalls + 1;
                if (stalls > 20) begin
                    $display("(halt detected: PC stable for %0d cycles)", stalls);
                    $fwrite(fd, "(halt detected: PC stable for %0d cycles)\n", stalls);
                    break;
                end
            end else begin
                last_pc = pc;
                stalls  = 0;
            end

            @(negedge clk);          // wait for the next mid-cycle sample point
        end

        #5;
        peek_addr = 32'h4000;
        #1;
        status = peek_data;

        $fwrite(fd, "----------------------------------------------------------------\n");
        if (status == 32'h600D600D) begin
            $display("==================== TEST PASSED ====================");
            $fwrite(fd, "==================== TEST PASSED ====================\n");
        end else begin
            peek_addr = 32'h4004;
            #1;
            $display("==================== TEST FAILED ====================");
            $display("status      = %08x (expected 600D600D)", status);
            $display("failing pc  = %08x", peek_data);
            $fwrite(fd, "==================== TEST FAILED ====================\n");
            $fwrite(fd, "status      = %08x (expected 600D600D)\n", status);
            $fwrite(fd, "failing pc  = %08x\n", peek_data);
        end

        // Dump the data region written by the program.
        $display("----------------------------------------------------------");
        $display("data region dump (written by the test program):");
        $fwrite(fd, "data region dump (written by the test program):\n");
        peek_addr = 32'h3000; #1;
        $display("  mem[0x3000] = %08x  (expected 0000000e)", peek_data);
        $fwrite(fd, "  mem[0x3000] = %08x  (expected 0000000e)\n", peek_data);
        peek_addr = 32'h3004; #1;
        $display("  mem[0x3004] = %08x  (expected 0004fffe)", peek_data);
        $fwrite(fd, "  mem[0x3004] = %08x  (expected 0004fffe)\n", peek_data);

        $fclose(fd);
        $finish;
    end

endmodule