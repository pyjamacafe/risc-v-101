// Testbench for the RV32I SoC (core + memory + system bus + UART + timer).
//
// Produces a detailed per-instruction execution log (sim_soc.log and
// console) including register writes, memory/peripheral accesses and
// control-flow changes (branches, JAL/JALR, interrupts to the handler,
// mret returns).
//
// The UART TX line is looped back to the RX input so the program can
// transmit bytes and receive them back.
//
// The program writes a status word to address 0x4000:
//   0x600D600D  -> TEST PASSED
//   0xDEADBEEF  -> TEST FAILED

`timescale 1ns/1ps
`include "riscv_decode.vh"

module tb_soc;

    localparam MEM_BYTES = 65536;
    localparam HEX_FILE  = "sw/soc_test.hex";
    localparam UART_DIV  = 8;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    wire [31:0] pc, inst;
    wire [ 3:0] irq;
    wire        uart_tx;
    reg  [31:0] peek_addr = 32'h4000;
    wire [31:0] peek_data;
    wire [ 4:0] dbg_rd;
    wire [31:0] dbg_wb_data;
    wire        dbg_reg_write;
    wire [31:0] dbg_data_addr;
    wire [ 3:0] dbg_st_wen;
    wire [31:0] dbg_st_data;
    wire [31:0] dbg_pc_next;

    // UART loopback: TX drives the RX input.
    rv32i_soc #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE (HEX_FILE),
        .UART_DIV  (UART_DIV)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .uart_rx        (uart_tx),
        .uart_tx        (uart_tx),
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
        .dbg_pc_next    (dbg_pc_next),
        .dbg_irq        (irq)
    );

    always #5 clk = ~clk;      // 100 MHz clock

    integer fd, cyc, last_pc, stalls;
    reg [31:0] status;
    wire is_load  = (inst[6:0] == 7'b0000011);
    wire is_store = (inst[6:0] == 7'b0100011);
    reg [8*8-1:0] mnem;

    initial begin
        $dumpfile("wave_soc.vcd");
        $dumpvars(0, tb_soc);
        fd = $fopen("sim_soc.log", "w");

        $fwrite(fd, "================================================================\n");
        $fwrite(fd, " RV32I SoC (core + bus + UART + timer) -- detailed execution log\n");
        $fwrite(fd, " legend: rd=dest reg, ld@=load address, st=store [addr] <- data\n");
        $fwrite(fd, "         CF = control flow taken -> target (incl. interrupts)\n");
        $fwrite(fd, "================================================================\n");
        $fwrite(fd, " ADDRESS MAP (SoC configuration)\n");
        $fwrite(fd, "   0x00000000 - 0x0FFFFFFF   main memory (unified; %0d KiB implemented)\n",
                MEM_BYTES / 1024);
        $fwrite(fd, "   0x10000000 - 0x1FFFFFFF   UART  0x00 status, 0x04 tx, 0x08 rx, 0x0C irq_en\n");
        $fwrite(fd, "   0x20000000 - 0x2FFFFFFF   timer 0x00 ctrl, 0x04 load, 0x08 count, 0x0C status\n");
        $fwrite(fd, "   0x30000000 - 0xFFFFFFFF   unmapped (reads 0, writes dropped)\n");
        $fwrite(fd, "   irq[0]=timer  irq[1]=uart_rx  irq[2]=uart_tx\n");
        $fwrite(fd, "================================================================\n");
        $fwrite(fd, "  #    time        pc       inst      mnemonic  effect\n");
        $fwrite(fd, "----------------------------------------------------------------\n");

        $display("=====================================================================");
        $display(" RV32I SoC (core + bus + UART + timer) -- detailed execution log");
        $display(" ADDRESS MAP:");
        $display("   0x00000000-0x0FFFFFFF  main memory (%0d KiB)", MEM_BYTES/1024);
        $display("   0x10000000-0x1FFFFFFF  UART   0x00 status, 0x04 tx, 0x08 rx, 0x0C irq_en");
        $display("   0x20000000-0x2FFFFFFF  timer  0x00 ctrl, 0x04 load, 0x08 count, 0x0C status");
        $display("   0x30000000-0xFFFFFFFF  unmapped");
        $display("  #    time        pc       inst      mnemonic  effect");
        $display("---------------------------------------------------------------------");

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;

        last_pc = 0;
        stalls  = 0;
        for (cyc = 0; cyc < 8000; cyc = cyc + 1) begin
            #1;
            get_mnemonic(inst, mnem);

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
                if (stalls > 40) begin
                    $display("(halt detected: PC stable for %0d cycles)", stalls);
                    $fwrite(fd, "(halt detected: PC stable for %0d cycles)\n", stalls);
                    break;
                end
            end else begin
                last_pc = pc;
                stalls  = 0;
            end

            @(negedge clk);
        end

        #5;
        peek_addr = 32'h4000;
        #1;
        status = peek_data;

        $fwrite(fd, "----------------------------------------------------------------\n");
        if (status == 32'h600D600D) begin
            $display("==================== SOC TEST PASSED ====================");
            $fwrite(fd, "==================== SOC TEST PASSED ====================\n");
        end else begin
            $display("==================== SOC TEST FAILED ====================");
            $display("status = %08x (expected 600D600D)", status);
            $fwrite(fd, "==================== SOC TEST FAILED ====================\n");
            $fwrite(fd, "status = %08x (expected 600D600D)\n", status);
        end

        $display("----------------------------------------------------------");
        $display("irq counter value (timer interrupts handled):");
        peek_addr = 32'h174; #1;
        $display("  mem[0x174] = %08x  (expected 00000003)", peek_data);
        $fwrite(fd, "irq counter value (timer interrupts handled):\n");
        $fwrite(fd, "  mem[0x174] = %08x  (expected 00000003)\n", peek_data);

        $fclose(fd);
        $finish;
    end

endmodule