`timescale 1ns/1ps
// 32 x 32-bit register file for RV32I.
// Two combinational read ports, one write port (positive edge).
// Register x0 is hardwired to zero.

module register_file (
    input  wire        clk,
    input  wire        we,        // write enable
    input  wire [ 4:0] rs1,       // read address 1
    input  wire [ 4:0] rs2,       // read address 2
    input  wire [ 4:0] rd,        // write address
    input  wire [31:0] wdata,     // write data
    output reg  [31:0] rd1,       // read data 1
    output reg  [31:0] rd2,       // read data 2
    // Debug access (GDB remote stub)
    input  wire [ 4:0] dbg_ridx,  // debug read address
    output reg  [31:0] dbg_rval,  // debug read data
    input  wire        dbg_we,    // debug write enable
    input  wire [ 4:0] dbg_widx,  // debug write address
    input  wire [31:0] dbg_wval   // debug write data
);

    reg [31:0] regs [0:31];

    // x0 is hardwired to zero.
    always @(*) begin
        rd1 = (rs1 == 5'b00000) ? 32'b0 : regs[rs1];
        rd2 = (rs2 == 5'b00000) ? 32'b0 : regs[rs2];
        dbg_rval = regs[dbg_ridx];
    end

    always @(posedge clk) begin
        if (dbg_we && (dbg_widx != 5'b00000))
            regs[dbg_widx] <= dbg_wval;
        else if (we && (rd != 5'b00000))
            regs[rd] <= wdata;
    end

endmodule