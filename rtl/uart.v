`timescale 1ns/1ps
// Memory-mapped UART with 8N1 TX and RX engines.
//
// Register map (offset within the UART window, e.g. 0x10000000):
//   0x00 STATUS  (RO) : bit 0 = TX_READY (transmitter idle), bit 1 = RX_AVAIL
//   0x04 TX_DATA (WO) : write a byte to transmit
//   0x08 RX_DATA (RO) : received byte; a read clears RX_AVAIL
//   0x0C IRQ_EN  (RW) : bit 0 = RX interrupt enable, bit 1 = TX interrupt enable
//
// IRQ outputs are level signals:
//   irq_rx = RX_AVAIL & irq_en[0]           (high until RX_DATA is read)
//   irq_tx = TX_DONE_PENDING & irq_en[1]    (high until STATUS is read)
//
// Note: the RX buffer holds a single byte. Software must read RX_DATA
// before the next byte finishes arriving, otherwise it is overwritten.
//
// CLK_DIV is the number of clock cycles per bit period (<= 65536).

module uart #(
    parameter CLK_DIV = 8
) (
    input  wire        clk,
    input  wire        rst,
    // Bus slave port
    input  wire [31:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [ 3:0] bus_wen,
    input  wire        bus_rd,
    output reg  [31:0] bus_rdata,
    // Serial lines
    output wire        tx,
    input  wire        rx,
    // Interrupts
    output wire        irq_rx,
    output wire        irq_tx
);

    localparam STATUS = 2'b00;
    localparam TXDATA = 2'b01;
    localparam RXDATA = 2'b10;
    localparam IRQEN  = 2'b11;

    wire [1:0] sel = bus_addr[3:2];

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    reg [31:0] irq_en;      // bit0 = RX enable, bit1 = TX enable
    reg        rx_avail;
    reg        tx_done_pend;
    reg [ 7:0] rx_data;

    // ------------------------------------------------------------------
    // TX engine (8N1)
    // ------------------------------------------------------------------
    reg        tx_busy;
    reg [ 7:0] tx_shift;
    reg [ 3:0] tx_bit;
    reg [15:0] tx_cnt;
    reg        tx_line;
    wire       tx_ready;

    wire tx_load = (sel == TXDATA) && (|bus_wen);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_busy  <= 1'b0;
            tx_line  <= 1'b1;        // idle high
            tx_bit   <= 4'd0;
            tx_cnt   <= 16'd0;
            tx_shift <= 8'd0;
        end else if (tx_load && !tx_busy) begin
            tx_busy  <= 1'b1;
            tx_shift <= bus_wdata[7:0];
            tx_bit   <= 4'd0;        // start bit
            tx_cnt   <= 16'd0;
            tx_line  <= 1'b0;        // assert start bit
        end else if (tx_busy) begin
            if (tx_cnt == CLK_DIV - 1) begin
                tx_cnt <= 16'd0;
                if (tx_bit == 4'd9) begin            // stop bit done
                    tx_busy        <= 1'b0;
                    tx_line        <= 1'b1;
                    tx_done_pend   <= 1'b1;
                end else begin
                    tx_bit <= tx_bit + 4'd1;
                    if (tx_bit == 4'd8)              // enter stop bit
                        tx_line <= 1'b1;
                    else                             // data bit
                        tx_line <= tx_shift[tx_bit[2:0]];
                end
            end else begin
                tx_cnt <= tx_cnt + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // RX engine (8N1)
    // ------------------------------------------------------------------
    reg        rx_busy;
    reg [ 7:0] rx_shift;
    reg [ 3:0] rx_bit;
    reg [15:0] rx_cnt;

    wire rx_clear = (sel == RXDATA) && bus_rd;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_busy   <= 1'b0;
            rx_bit    <= 4'd0;
            rx_cnt    <= 16'd0;
            rx_shift  <= 8'd0;
            rx_data   <= 8'd0;
            rx_avail  <= 1'b0;
        end else if (rx_clear) begin
            rx_avail <= 1'b0;
        end else if (!rx_busy) begin
            if (rx == 1'b0) begin                    // start bit edge
                rx_busy <= 1'b1;
                rx_bit  <= 4'd0;
                // Half a bit period to the centre of the start bit.
                // (CLK_DIV>>1)-1 because the countdown adds one cycle for
                // the cycle on which the value is loaded.
                rx_cnt  <= (CLK_DIV >> 1) - 1;
            end
        end else if (rx_cnt == 16'd0) begin
            case (rx_bit)
                4'd0: begin                          // sample start bit
                    if (rx == 1'b1)                  // false start, re-arm
                        rx_busy <= 1'b0;
                    else begin
                        rx_bit <= 4'd1;
                        rx_cnt <= CLK_DIV - 1;
                    end
                end
                4'd1, 4'd2, 4'd3, 4'd4,
                4'd5, 4'd6, 4'd7, 4'd8: begin        // data bits 0..7
                    rx_shift[rx_bit[2:0] - 3'd1] <= rx;
                    rx_bit <= rx_bit + 4'd1;
                    rx_cnt <= CLK_DIV - 1;
                end
                default: begin                       // stop bit
                    rx_busy  <= 1'b0;
                    rx_data  <= rx_shift;
                    rx_avail <= 1'b1;
                end
            endcase
        end else begin
            rx_cnt <= rx_cnt - 16'd1;
        end
    end

    // ------------------------------------------------------------------
    // Register writes
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            irq_en       <= 32'b0;
            tx_done_pend <= 1'b0;
        end else if (tx_load) begin
            tx_done_pend <= 1'b0;                    // new transmission
        end else if ((sel == STATUS) && bus_rd) begin
            tx_done_pend <= 1'b0;
        end else if ((sel == IRQEN) && (|bus_wen)) begin
            irq_en <= bus_wdata;
        end
    end

    // ------------------------------------------------------------------
    // Register reads / interrupts
    // ------------------------------------------------------------------
    assign tx_ready = !tx_busy;

    always @(*) begin
        case (sel)
            STATUS: bus_rdata = {30'b0, rx_avail, tx_ready};
            RXDATA: bus_rdata = {24'b0, rx_data};
            default: bus_rdata = 32'b0;
        endcase
    end

    assign tx      = tx_line;
    assign irq_rx  = rx_avail & irq_en[0];
    assign irq_tx  = tx_done_pend & irq_en[1];

endmodule