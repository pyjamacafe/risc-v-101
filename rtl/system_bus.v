`timescale 1ns/1ps
// Simple memory-mapped system bus with one master (the core data port) and
// three slaves (main memory, UART, timer).
//
// Address map (selected by bits [31:28]):
//   0x00000000 - 0x0FFFFFFF  main memory   (unified instruction/data)
//   0x10000000 - 0x1FFFFFFF  UART
//   0x20000000 - 0x2FFFFFFF  timer
//   anything else            unmapped -> reads return 0, writes dropped
//
// Reads are combinational (single-cycle); writes are gated per slave.
// A read strobe (m_rd) is forwarded so slaves can act on register reads.

module system_bus (
    // Master port (core data access)
    input  wire [31:0] m_addr,
    input  wire [31:0] m_wdata,
    input  wire [ 3:0] m_wen,
    input  wire        m_rd,
    output wire [31:0] m_rdata,
    // Memory slave
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [ 3:0] mem_wen,
    input  wire [31:0] mem_rdata,
    // UART slave
    output wire [31:0] uart_addr,
    output wire [31:0] uart_wdata,
    output wire [ 3:0] uart_wen,
    output wire        uart_rd,
    input  wire [31:0] uart_rdata,
    // Timer slave
    output wire [31:0] timer_addr,
    output wire [31:0] timer_wdata,
    output wire [ 3:0] timer_wen,
    output wire        timer_rd,
    input  wire [31:0] timer_rdata
);

    wire mem_sel   = (m_addr[31:28] == 4'h0);
    wire uart_sel  = (m_addr[31:28] == 4'h1);
    wire timer_sel = (m_addr[31:28] == 4'h2);

    // Address/data broadcast, write enables and read strobes gated per slave.
    assign mem_addr   = m_addr;
    assign mem_wdata  = m_wdata;
    assign mem_wen    = mem_sel  ? m_wen  : 4'b0000;

    assign uart_addr  = m_addr;
    assign uart_wdata = m_wdata;
    assign uart_wen   = uart_sel ? m_wen  : 4'b0000;
    assign uart_rd    = uart_sel & m_rd;

    assign timer_addr  = m_addr;
    assign timer_wdata = m_wdata;
    assign timer_wen   = timer_sel ? m_wen : 4'b0000;
    assign timer_rd    = timer_sel & m_rd;

    assign m_rdata = mem_sel   ? mem_rdata :
                     uart_sel  ? uart_rdata :
                     timer_sel ? timer_rdata : 32'b0;

endmodule