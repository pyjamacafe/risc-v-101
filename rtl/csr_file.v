`timescale 1ns/1ps
// Minimal machine-mode CSR file for interrupt support.
//
// Implemented CSRs:
//   0x300 mstatus : MIE (bit 3, global interrupt enable), MPIE (bit 7)
//   0x304 mie     : per-line interrupt enable mask (bits 3:0)
//   0x305 mtvec   : trap vector base (direct mode)
//   0x340 mscratch
//   0x341 mepc    : trap return address
//   0x342 mcause  : trap cause (interrupts: 0x80000000 | irq index)
//   0x344 mip     : read-only pending interrupts (irq input)
//
// On an interrupt (take_trap): mepc <- trap_pc, mcause <- trap_cause,
// mstatus.MPIE <- MIE, mstatus.MIE <- 0.
// On mret (do_mret): mstatus.MIE <- MPIE, MPIE <- 1.
// Hardware updates take priority over software CSR writes.

module csr_file (
    input  wire        clk,
    input  wire        rst,
    // Software access
    input  wire [11:0] csr_addr,
    input  wire        csr_we,
    input  wire [31:0] csr_wdata,
    output reg  [31:0] csr_rdata,
    // Hardware access (interrupt handling)
    input  wire        take_trap,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_cause,
    input  wire        do_mret,
    input  wire [ 3:0] irq,
    // Datapath outputs
    output reg  [31:0] mstatus,
    output reg  [31:0] mie,
    output reg  [31:0] mtvec,
    output reg  [31:0] mepc,
    // Debug read (GDB remote stub)
    input  wire [11:0] dbg_csr_idx,
    output reg  [31:0] dbg_csr_val
);

    localparam MIE  = 3;
    localparam MPIE = 7;

    reg [31:0] mcause;
    reg [31:0] mscratch;

    // Combinational read.
    always @(*) begin
        case (csr_addr)
            12'h300: csr_rdata = mstatus;
            12'h304: csr_rdata = mie;
            12'h305: csr_rdata = mtvec;
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = mepc;
            12'h342: csr_rdata = mcause;
            12'h344: csr_rdata = {28'b0, irq};   // mip
            default: csr_rdata = 32'b0;
        endcase
    end

    // Debug read (independent of the CPU instruction stream).
    always @(*) begin
        case (dbg_csr_idx)
            12'h300: dbg_csr_val = mstatus;
            12'h304: dbg_csr_val = mie;
            12'h305: dbg_csr_val = mtvec;
            12'h340: dbg_csr_val = mscratch;
            12'h341: dbg_csr_val = mepc;
            12'h342: dbg_csr_val = mcause;
            12'h344: dbg_csr_val = {28'b0, irq};
            default: dbg_csr_val = 32'b0;
        endcase
    end

    // Sequential writes: hardware traps take priority over software.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mstatus  <= 32'b0;
            mie      <= 32'b0;
            mtvec    <= 32'b0;
            mepc     <= 32'b0;
            mcause   <= 32'b0;
            mscratch <= 32'b0;
        end else if (take_trap) begin
            mepc           <= trap_pc;
            mcause         <= trap_cause;
            mstatus[MPIE]  <= mstatus[MIE];
            mstatus[MIE]   <= 1'b0;
        end else if (do_mret) begin
            mstatus[MIE]   <= mstatus[MPIE];
            mstatus[MPIE]  <= 1'b1;
        end else if (csr_we) begin
            case (csr_addr)
                12'h300: mstatus  <= csr_wdata;
                12'h304: mie      <= csr_wdata;
                12'h305: mtvec    <= csr_wdata;
                12'h340: mscratch <= csr_wdata;
                12'h341: mepc     <= csr_wdata;
                default: ;
            endcase
        end
    end

endmodule