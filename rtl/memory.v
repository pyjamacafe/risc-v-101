`timescale 1ns/1ps
// Unified instruction/data memory (von Neumann).
//
// A single byte-addressed storage array is shared by the instruction fetch
// and data access ports. Both reads are combinational so the single-cycle
// core can fetch the instruction and access data within one clock cycle.
// The write port is sequential and uses per-byte write enables so byte,
// halfword and word stores are all supported.
//
// The memory is loaded from an optional $readmemh hex file (word per line,
// little-endian byte order, i.e. the file contains the raw machine code
// bytes as they appear in memory).

module unified_memory #(
    parameter MEM_BYTES = 16384,
    parameter INIT_FILE = ""
) (
    input  wire        clk,
    // Instruction fetch port
    input  wire [31:0] inst_addr,
    output reg  [31:0] inst,
    // Data access port
    input  wire [31:0] data_addr,
    input  wire [31:0] data_wdata,
    input  wire [ 3:0] data_wen,   // one bit per byte
    output reg  [31:0] data_rdata,
    // Debug peek port (combinational read at an arbitrary address)
    input  wire [31:0] dbg_addr,
    output reg  [31:0] dbg_data,
    // Debug write port (GDB remote stub; held while the CPU is halted)
    input  wire [31:0] dbg_write_addr,
    input  wire [31:0] dbg_write_data,
    input  wire [ 3:0] dbg_write_en
);

    reg [7:0] mem [0:MEM_BYTES-1];

    integer i;
    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'h00;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // Combinational instruction fetch (word aligned).
    always @(*) begin
        if (inst_addr < MEM_BYTES - 3)
            inst = {mem[inst_addr + 3], mem[inst_addr + 2],
                    mem[inst_addr + 1], mem[inst_addr]};
        else
            inst = 32'h00000000;
    end

    // Word-aligned base of the data access, so the byte/halfword selection
    // made by the core using addr[1:0] lines up with mem[base + i].
    wire [31:0] data_base = data_addr & 32'hFFFFFFFC;

    // Combinational data read (aligned word).
    always @(*) begin
        if (data_base < MEM_BYTES - 3)
            data_rdata = {mem[data_base + 3], mem[data_base + 2],
                          mem[data_base + 1], mem[data_base]};
        else
            data_rdata = 32'h00000000;
    end

    // Combinational debug peek.
    always @(*) begin
        if (dbg_addr < MEM_BYTES - 3)
            dbg_data = {mem[dbg_addr + 3], mem[dbg_addr + 2],
                        mem[dbg_addr + 1], mem[dbg_addr]};
        else
            dbg_data = 32'h00000000;
    end

    // Sequential data write with per-byte write enables.
    always @(posedge clk) begin
        if (data_wen[0] && data_base < MEM_BYTES)
            mem[data_base]   <= data_wdata[7:0];
        if (data_wen[1] && data_base + 1 < MEM_BYTES)
            mem[data_base+1] <= data_wdata[15:8];
        if (data_wen[2] && data_base + 2 < MEM_BYTES)
            mem[data_base+2] <= data_wdata[23:16];
        if (data_wen[3] && data_base + 3 < MEM_BYTES)
            mem[data_base+3] <= data_wdata[31:24];
        // Debug writes (GDB): the CPU is held, so data_wen is inactive.
        if (dbg_write_en[0] && dbg_write_addr < MEM_BYTES)
            mem[dbg_write_addr]   <= dbg_write_data[7:0];
        if (dbg_write_en[1] && dbg_write_addr + 1 < MEM_BYTES)
            mem[dbg_write_addr+1] <= dbg_write_data[15:8];
        if (dbg_write_en[2] && dbg_write_addr + 2 < MEM_BYTES)
            mem[dbg_write_addr+2] <= dbg_write_data[23:16];
        if (dbg_write_en[3] && dbg_write_addr + 3 < MEM_BYTES)
            mem[dbg_write_addr+3] <= dbg_write_data[31:24];
    end

endmodule