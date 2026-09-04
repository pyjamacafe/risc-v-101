`timescale 1ns/1ps
// Memory-mapped countdown timer.
//
// Register map (offset within the timer window, e.g. 0x20000000):
//   0x00 CTRL   (RW) : bit 0 = enable countdown, bit 1 = interrupt enable
//   0x04 LOAD   (RW) : reload value; writing also loads COUNT and clears pending
//   0x08 COUNT  (RO) : current countdown value
//   0x0C STATUS (RO) : bit 0 = pending; a read clears pending
//
// When enabled, COUNT decrements every cycle. On reaching zero the pending
// flag is set and COUNT is reloaded from LOAD (periodic).
// irq_out = pending & irq_en & enable.

module timer #(
    parameter WIDTH = 32
) (
    input  wire        clk,
    input  wire        rst,
    // Bus slave port
    input  wire [31:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [ 3:0] bus_wen,
    input  wire        bus_rd,
    output reg  [31:0] bus_rdata,
    // Interrupt
    output wire        irq_out
);

    localparam TCTRL   = 2'b00;
    localparam TLOAD   = 2'b01;
    localparam TCOUNT  = 2'b10;
    localparam TSTATUS = 2'b11;

    wire [1:0] sel = bus_addr[3:2];

    reg        enable;
    reg        irq_en;
    reg        pending;
    reg [WIDTH-1:0] load;
    reg [WIDTH-1:0] count;

    wire load_write = (sel == TLOAD) && (|bus_wen);
    wire ctrl_write = (sel == TCTRL) && (|bus_wen);
    wire status_rd  = (sel == TSTATUS) && bus_rd;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            enable  <= 1'b0;
            irq_en  <= 1'b0;
            pending <= 1'b0;
            load    <= {WIDTH{1'b0}};
            count   <= {WIDTH{1'b0}};
        end else begin
            if (ctrl_write) begin
                enable <= bus_wdata[0];
                irq_en <= bus_wdata[1];
            end
            if (load_write) begin
                load    <= bus_wdata;
                count   <= bus_wdata;
                pending <= 1'b0;
            end
            if (status_rd)
                pending <= 1'b0;
            if (enable && !load_write) begin
                if (count == {WIDTH{1'b0}}) begin
                    pending <= 1'b1;
                    count   <= load;
                end else begin
                    count <= count - {{WIDTH-1{1'b0}}, 1'b1};
                end
            end
        end
    end

    always @(*) begin
        case (sel)
            TCTRL:   bus_rdata = {{WIDTH-2{1'b0}}, irq_en, enable};
            TLOAD:   bus_rdata = {{WIDTH-32{1'b0}}, load};   // WIDTH=32 for RV32
            TCOUNT:  bus_rdata = {{WIDTH-32{1'b0}}, count};
            TSTATUS: bus_rdata = {{WIDTH-1{1'b0}}, pending};
            default: bus_rdata = {WIDTH{1'b0}};
        endcase
    end

    assign irq_out = pending & irq_en & enable;

endmodule