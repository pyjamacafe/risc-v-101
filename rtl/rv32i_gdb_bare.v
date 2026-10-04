`timescale 1ns/1ps
// Top level for the GDB debug harness (bare configuration): instantiates the
// core (INTR_EN = 0) plus the unified memory directly, and exposes the full
// debug interface (registers, memory peek/write, halt, PC write) as top-level
// ports that the C++ testbench (tb/gdb_bare_main.cpp) drives.
//
// This is the bare-configuration counterpart of rv32i_gdb.v (which wraps
// rv32i_soc). It avoids rv32i_bare because that wrapper ties the debug
// inputs off; here they are passed straight through to the core and memory.

module rv32i_gdb_bare #(
    parameter MEM_BYTES = 65536,
    parameter INIT_FILE = ""
) (
    input  wire        clk,
    input  wire        rst,
    // CPU observation
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_inst,
    // Register access
    input  wire [ 4:0] dbg_reg_ridx,
    output wire [31:0] dbg_reg_rval,
    input  wire        dbg_reg_we,
    input  wire [ 4:0] dbg_reg_widx,
    input  wire [31:0] dbg_reg_wval,
    // Memory access
    input  wire [31:0] dbg_peek_addr,
    output wire [31:0] dbg_peek_data,
    input  wire [31:0] dbg_mem_waddr,
    input  wire [31:0] dbg_mem_wdata,
    input  wire [ 3:0] dbg_mem_wen,
    // Halt / PC override
    input  wire        dbg_hold,
    input  wire        dbg_pc_we,
    input  wire [31:0] dbg_pc_wval
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
        .dbg_hold      (dbg_hold),
        .dbg_pc_we     (dbg_pc_we),
        .dbg_pc_wval   (dbg_pc_wval),
        .dbg_reg_ridx  (dbg_reg_ridx),
        .dbg_reg_rval  (dbg_reg_rval),
        .dbg_reg_we    (dbg_reg_we),
        .dbg_reg_widx  (dbg_reg_widx),
        .dbg_reg_wval  (dbg_reg_wval),
        .dbg_csr_idx   (12'b0),
        .dbg_csr_val   (),
        .dbg_pc        (dbg_pc),
        .dbg_inst      (dbg_inst),
        .dbg_rd        (),
        .dbg_wb_data   (),
        .dbg_reg_write (),
        .dbg_data_addr (),
        .dbg_st_wen    (),
        .dbg_st_data   (),
        .dbg_pc_next   ()
    );

    unified_memory #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE (INIT_FILE)
    ) u_mem (
        .clk            (clk),
        .inst_addr      (inst_addr),
        .inst           (inst),
        .data_addr      (data_addr),
        .data_wdata     (data_wdata),
        .data_wen       (data_wen),
        .data_rdata     (data_rdata),
        .dbg_addr       (dbg_peek_addr),
        .dbg_data       (dbg_peek_data),
        .dbg_write_addr (dbg_mem_waddr),
        .dbg_write_data (dbg_mem_wdata),
        .dbg_write_en   (dbg_mem_wen)
    );

endmodule
