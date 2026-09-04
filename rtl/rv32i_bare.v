`timescale 1ns/1ps
// Bare single-cycle RV32I CPU: core + unified instruction/data memory.
// This is the "present configuration" without any peripherals.

module rv32i_bare #(
    parameter MEM_BYTES = 65536,
    parameter INIT_FILE = ""
) (
    input  wire        clk,
    input  wire        rst,
    // Debug / observation ports
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_inst,
    input  wire [31:0] dbg_peek_addr,
    output wire [31:0] dbg_peek_data,
    // Detailed trace ports
    output wire [ 4:0] dbg_rd,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_reg_write,
    output wire [31:0] dbg_data_addr,
    output wire [ 3:0] dbg_st_wen,
    output wire [31:0] dbg_st_data,
    output wire [31:0] dbg_pc_next
);

    wire [31:0] inst_addr;
    wire [31:0] inst;
    wire [31:0] data_addr;
    wire [31:0] data_wdata;
    wire [ 3:0] data_wen;
    wire [31:0] data_rdata;

    rv32i_core #(
        .INTR_EN (0)
    ) u_core (
        .clk           (clk),
        .rst           (rst),
        .inst_addr     (inst_addr),
        .inst          (inst),
        .data_addr     (data_addr),
        .data_wdata    (data_wdata),
        .data_wen      (data_wen),
        .data_read     (),
        .data_rdata    (data_rdata),
        .irq           (4'b0000),
        .dbg_pc        (dbg_pc),
        .dbg_inst      (dbg_inst),
        .dbg_rd        (dbg_rd),
        .dbg_wb_data   (dbg_wb_data),
        .dbg_reg_write (dbg_reg_write),
        .dbg_data_addr (dbg_data_addr),
        .dbg_st_wen    (dbg_st_wen),
        .dbg_st_data   (dbg_st_data),
        .dbg_pc_next   (dbg_pc_next)
    );

    unified_memory #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE (INIT_FILE)
    ) u_mem (
        .clk         (clk),
        .inst_addr   (inst_addr),
        .inst        (inst),
        .data_addr   (data_addr),
        .data_wdata  (data_wdata),
        .data_wen    (data_wen),
        .data_rdata  (data_rdata),
        .dbg_addr    (dbg_peek_addr),
        .dbg_data    (dbg_peek_data)
    );

endmodule