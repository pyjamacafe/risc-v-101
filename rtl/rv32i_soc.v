`timescale 1ns/1ps
// RV32I SoC: single-cycle core + unified memory + system bus + peripherals.
//
//   Address map:
//     0x00000000 - 0x0FFFFFFF  main memory (unified; 64 KiB implemented)
//     0x10000000 - 0x1FFFFFFF  UART  (registers at 0x10000000-0x1000000F)
//     0x20000000 - 0x2FFFFFFF  timer (registers at 0x20000000-0x2000000F)
//     0x30000000 - 0xFFFFFFFF  unmapped (reads 0, writes dropped)
//
//   Interrupts (irq vector): irq[0] = timer, irq[1] = UART RX,
//   irq[2] = UART TX.

module rv32i_soc #(
    parameter MEM_BYTES = 65536,
    parameter INIT_FILE = "",
    parameter UART_DIV  = 8
) (
    input  wire        clk,
    input  wire        rst,
    // Serial lines
    input  wire        uart_rx,
    output wire        uart_tx,
    // Debug / observation ports
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_inst,
    input  wire [31:0] dbg_peek_addr,
    output wire [31:0] dbg_peek_data,
    // Debug / GDB interface
    input  wire        dbg_hold,
    input  wire        dbg_pc_we,
    input  wire [31:0] dbg_pc_wval,
    input  wire [ 4:0] dbg_reg_ridx,
    output wire [31:0] dbg_reg_rval,
    input  wire        dbg_reg_we,
    input  wire [ 4:0] dbg_reg_widx,
    input  wire [31:0] dbg_reg_wval,
    input  wire [11:0] dbg_csr_idx,
    output wire [31:0] dbg_csr_val,
    input  wire [31:0] dbg_mem_waddr,
    input  wire [31:0] dbg_mem_wdata,
    input  wire [ 3:0] dbg_mem_wen,
    // Detailed trace ports
    output wire [ 4:0] dbg_rd,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_reg_write,
    output wire [31:0] dbg_data_addr,
    output wire [ 3:0] dbg_st_wen,
    output wire [31:0] dbg_st_data,
    output wire [31:0] dbg_pc_next,
    output wire [ 3:0] dbg_irq
);

    wire [31:0] inst_addr;
    wire [31:0] inst;
    wire [31:0] data_addr;
    wire [31:0] data_wdata;
    wire [ 3:0] data_wen;
    wire        data_rd;
    wire [31:0] data_rdata;

    wire [31:0] mem_addr,  mem_wdata,  mem_rdata;
    wire [ 3:0] mem_wen;
    wire [31:0] uart_addr, uart_wdata, uart_rdata;
    wire [ 3:0] uart_wen;
    wire        uart_rd;
    wire [31:0] timer_addr, timer_wdata, timer_rdata;
    wire [ 3:0] timer_wen;
    wire        timer_rd;

    wire timer_irq, uart_rx_irq, uart_tx_irq;
    wire [3:0] irq;

    // CPU (with interrupt support)
    rv32i_core #(
        .INTR_EN (1)
    ) u_core (
        .clk           (clk),
        .rst           (rst),
        .inst_addr     (inst_addr),
        .inst          (inst),
        .data_addr     (data_addr),
        .data_wdata    (data_wdata),
        .data_wen      (data_wen),
        .data_read     (data_rd),
        .data_rdata    (data_rdata),
        .irq           (irq),
        .dbg_hold      (dbg_hold),
        .dbg_pc_we     (dbg_pc_we),
        .dbg_pc_wval   (dbg_pc_wval),
        .dbg_reg_ridx  (dbg_reg_ridx),
        .dbg_reg_rval  (dbg_reg_rval),
        .dbg_reg_we    (dbg_reg_we),
        .dbg_reg_widx  (dbg_reg_widx),
        .dbg_reg_wval  (dbg_reg_wval),
        .dbg_csr_idx   (dbg_csr_idx),
        .dbg_csr_val   (dbg_csr_val),
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

    // Unified memory (instruction + data share one array)
    unified_memory #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE (INIT_FILE)
    ) u_mem (
        .clk         (clk),
        .inst_addr   (inst_addr),
        .inst        (inst),
        .data_addr   (mem_addr),
        .data_wdata  (mem_wdata),
        .data_wen    (mem_wen),
        .data_rdata  (mem_rdata),
        .dbg_addr    (dbg_peek_addr),
        .dbg_data    (dbg_peek_data),
        .dbg_write_addr (dbg_mem_waddr),
        .dbg_write_data (dbg_mem_wdata),
        .dbg_write_en   (dbg_mem_wen)
    );

    // System bus
    system_bus u_bus (
        .m_addr       (data_addr),
        .m_wdata      (data_wdata),
        .m_wen        (data_wen),
        .m_rd         (data_rd),
        .m_rdata      (data_rdata),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wen      (mem_wen),
        .mem_rdata    (mem_rdata),
        .uart_addr    (uart_addr),
        .uart_wdata   (uart_wdata),
        .uart_wen     (uart_wen),
        .uart_rd      (uart_rd),
        .uart_rdata   (uart_rdata),
        .timer_addr   (timer_addr),
        .timer_wdata  (timer_wdata),
        .timer_wen    (timer_wen),
        .timer_rd     (timer_rd),
        .timer_rdata  (timer_rdata)
    );

    // Peripherals
    uart #(
        .CLK_DIV (UART_DIV)
    ) u_uart (
        .clk        (clk),
        .rst        (rst),
        .bus_addr   (uart_addr),
        .bus_wdata  (uart_wdata),
        .bus_wen    (uart_wen),
        .bus_rd     (uart_rd),
        .bus_rdata  (uart_rdata),
        .tx         (uart_tx),
        .rx         (uart_rx),
        .irq_rx     (uart_rx_irq),
        .irq_tx     (uart_tx_irq)
    );

    timer u_timer (
        .clk        (clk),
        .rst        (rst),
        .bus_addr   (timer_addr),
        .bus_wdata  (timer_wdata),
        .bus_wen    (timer_wen),
        .bus_rd     (timer_rd),
        .bus_rdata  (timer_rdata),
        .irq_out    (timer_irq)
    );

    interrupt_controller u_ic (
        .clk         (clk),
        .rst         (rst),
        .timer_irq   (timer_irq),
        .uart_rx_irq (uart_rx_irq),
        .uart_tx_irq (uart_tx_irq),
        .irq         (irq)
    );

    assign dbg_irq = irq;

endmodule