`timescale 1ns/1ps
// Top level for the GDB debug harness: wraps rv32i_soc and exposes the
// debug interface (registers, CSRs, memory peek/write, halt, PC write)
// as top-level ports that the C++ testbench (tb/gdb_main.cpp) drives.

module rv32i_gdb #(
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
    // CSR access (read only)
    input  wire [11:0] dbg_csr_idx,
    output wire [31:0] dbg_csr_val,
    // Memory access
    input  wire [31:0] dbg_peek_addr,
    output wire [31:0] dbg_peek_data,
    input  wire [31:0] dbg_mem_waddr,
    input  wire [31:0] dbg_mem_wdata,
    input  wire [ 3:0] dbg_mem_wen,
    // Halt / PC override
    input  wire        dbg_hold,
    input  wire        dbg_pc_we,
    input  wire [31:0] dbg_pc_wval,
    // Serial (looped back for convenience)
    output wire        uart_tx
);

    wire tx, rx;
    assign rx = tx;                 // UART loopback

    wire [31:0] u_pc, u_inst, u_peek_data, u_reg_rval, u_csr_val;
    wire [31:0] u_wb_data, u_data_addr, u_st_data, u_pc_next;
    wire [ 4:0] u_rd;
    wire        u_reg_write;
    wire [ 3:0] u_st_wen;

    rv32i_soc #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE (INIT_FILE),
        .UART_DIV  (8)
    ) u_soc (
        .clk           (clk),
        .rst           (rst),
        .uart_rx       (rx),
        .uart_tx       (tx),
        .dbg_pc        (u_pc),
        .dbg_inst      (u_inst),
        .dbg_peek_addr (dbg_peek_addr),
        .dbg_peek_data (u_peek_data),
        .dbg_hold      (dbg_hold),
        .dbg_pc_we     (dbg_pc_we),
        .dbg_pc_wval   (dbg_pc_wval),
        .dbg_reg_ridx  (dbg_reg_ridx),
        .dbg_reg_rval  (u_reg_rval),
        .dbg_reg_we    (dbg_reg_we),
        .dbg_reg_widx  (dbg_reg_widx),
        .dbg_reg_wval  (dbg_reg_wval),
        .dbg_csr_idx   (dbg_csr_idx),
        .dbg_csr_val   (u_csr_val),
        .dbg_mem_waddr (dbg_mem_waddr),
        .dbg_mem_wdata (dbg_mem_wdata),
        .dbg_mem_wen   (dbg_mem_wen),
        .dbg_rd        (u_rd),
        .dbg_wb_data   (u_wb_data),
        .dbg_reg_write (u_reg_write),
        .dbg_data_addr (u_data_addr),
        .dbg_st_wen    (u_st_wen),
        .dbg_st_data   (u_st_data),
        .dbg_pc_next   (u_pc_next),
        .dbg_irq       ()
    );

    assign dbg_pc       = u_pc;
    assign dbg_inst     = u_inst;
    assign dbg_peek_data= u_peek_data;
    assign dbg_reg_rval = u_reg_rval;
    assign dbg_csr_val  = u_csr_val;
    assign uart_tx      = tx;

endmodule