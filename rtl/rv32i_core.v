`timescale 1ns/1ps
// Single-cycle RV32I core.
//
// The core no longer contains the memory: it exposes instruction-fetch and
// data-access ports so that the memory (and optionally a system bus with
// peripherals) can be attached externally.
//
// INTR_EN parameter:
//   0 : bare core, identical to the original single-cycle datapath.
//   1 : adds the Zicsr instructions (csrrw/csrrs/csrrc and immediate forms),
//       the mret instruction, and a minimal machine-mode interrupt mechanism:
//         - mstatus  (0x300): MIE bit 3, MPIE bit 7
//         - mie      (0x304): per-line interrupt enable mask (bits 3:0)
//         - mtvec    (0x305): trap vector base (direct mode)
//         - mscratch (0x340)
//         - mepc     (0x341): trap return address
//         - mcause   (0x342): trap cause (interrupt = 0x80000000 | irq index)
//         - mip      (0x344): read-only pending interrupts (from irq input)
//       When an enabled interrupt is pending, the in-flight instruction
//       completes, mepc/mcause are written, MIE is cleared and the PC jumps
//       to mtvec.  mret restores MIE from MPIE and jumps to mepc.

module rv32i_core #(
    parameter INTR_EN = 0
) (
    input  wire        clk,
    input  wire        rst,
    // Instruction fetch (from external unified memory)
    output wire [31:0] inst_addr,
    input  wire [31:0] inst,
    // Data access (to system bus / memory)
    output wire [31:0] data_addr,
    output wire [31:0] data_wdata,
    output wire [ 3:0] data_wen,
    output wire        data_read,
    input  wire [31:0] data_rdata,
    // Interrupt request lines (only used when INTR_EN = 1)
    input  wire [ 3:0] irq,
    // Debug / trace ports
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_inst,
    output wire [ 4:0] dbg_rd,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_reg_write,
    output wire [31:0] dbg_data_addr,
    output wire [ 3:0] dbg_st_wen,
    output wire [31:0] dbg_st_data,
    output wire [31:0] dbg_pc_next
);

    // ---- Internal wires ----
    wire [31:0] rd1, rd2;      // register file reads
    wire [31:0] imm;           // generated immediate
    wire [31:0] alu_a, alu_b;  // ALU operands
    wire [31:0] alu_result;
    wire        alu_zero, lt_s, lt_u;
    wire [31:0] mem_data;      // sign/zero extended load data
    wire [31:0] wb_data;       // register file write data
    reg  [31:0] pc_next_norm;  // normal next PC (no trap / mret)
    reg  [31:0] pc;

    // ---- Control signals ----
    wire        reg_write, mem_write, mem_read, branch;
    wire [ 1:0] jump, write_src, alu_src_b, mem_size;
    wire        alu_src_a, mem_sign;
    wire [ 3:0] alu_control;
    wire [ 2:0] imm_sel;

    // ---- Branch condition ----
    wire [2:0] f3 = inst[14:12];
    wire branch_cond =
        (f3[2:1] == 2'b00) ? (f3[0] ? ~alu_zero :  alu_zero) :  // BNE/BEQ
        (f3[2:1] == 2'b10) ? (f3[0] ? ~lt_s     :  lt_s)     :  // BGE/BLT
                             (f3[0] ? ~lt_u     :  lt_u);       // BGEU/BLTU
    wire branch_taken = branch & branch_cond;

    // ---- Next PC (normal path: sequential / branch / JAL / JALR) ----
    wire [31:0] pc_plus4      = pc + 32'd4;
    wire [31:0] branch_target = pc + imm;
    wire [31:0] jalr_target   = (rd1 + imm) & 32'hFFFFFFFE;

    always @(*) begin
        case (jump)
            2'b01 : pc_next_norm = branch_target;             // JAL
            2'b10 : pc_next_norm = jalr_target;               // JALR
            default: pc_next_norm = branch_taken ? branch_target : pc_plus4;
        endcase
    end

    // ---- Interrupt / CSR support (optional) ----
    wire        is_mret;                 // from control
    wire        csr_we;
    wire [ 1:0] csr_rmode;
    wire        csr_imm;
    wire [31:0] csr_rdata;        // CSR read value (writeback source)
    wire [31:0] mtvec, mepc;      // trap vector / return address
    wire        take_trap;        // an enabled interrupt is pending

    generate
        if (INTR_EN) begin : intr_support
            wire [31:0] mstatus, mie;
            wire [31:0] csr_rsrc;
            wire [31:0] csr_wdata;
            wire [ 3:0] irq_pending;
            reg  [ 3:0] irq_idx;
            wire [31:0] trap_cause;

            // Interrupt pending: requested AND enabled AND globally enabled.
            assign irq_pending = irq & mie[3:0] & {4{mstatus[3]}};
            assign take_trap   = |irq_pending;

            // Lowest-index pending line wins.
            always @(*) begin
                if      (irq_pending[0]) irq_idx = 4'd0;
                else if (irq_pending[1]) irq_idx = 4'd1;
                else if (irq_pending[2]) irq_idx = 4'd2;
                else                     irq_idx = 4'd3;
            end
            assign trap_cause = {1'b1, 27'b0, irq_idx};   // interrupt cause

            // CSR read-modify-write operand.
            assign csr_rsrc  = csr_imm ? {27'b0, inst[19:15]} : rd1;
            assign csr_wdata = (csr_rmode == 2'b00) ? csr_rsrc :
                               (csr_rmode == 2'b01) ? (csr_rdata | csr_rsrc) :
                                                      (csr_rdata & ~csr_rsrc);

            csr_file u_csr (
                .clk         (clk),
                .rst         (rst),
                .csr_addr    (inst[31:20]),
                .csr_we      (csr_we),
                .csr_wdata   (csr_wdata),
                .csr_rdata   (csr_rdata),
                .take_trap   (take_trap),
                .trap_pc     (pc_next_norm),
                .trap_cause  (trap_cause),
                .do_mret     (is_mret),
                .mstatus     (mstatus),
                .mie         (mie),
                .mtvec       (mtvec),
                .mepc        (mepc),
                .irq         (irq)
            );
        end else begin : no_intr
            assign take_trap   = 1'b0;
            assign is_mret     = 1'b0;
            assign csr_rdata   = 32'b0;
            assign mtvec       = 32'b0;
            assign mepc        = 32'b0;
        end
    endgenerate

    // Final PC: trap > mret > normal.
    wire [31:0] pc_target = take_trap ? mtvec :
                            is_mret   ? mepc : pc_next_norm;

    always @(posedge clk or posedge rst) begin
        if (rst)
            pc <= 32'b0;
        else
            pc <= pc_target;
    end

    // ---- ALU operands ----
    assign alu_a = alu_src_a ? pc : rd1;
    assign alu_b = (alu_src_b == 2'b00) ? rd2 :
                   (alu_src_b == 2'b01) ? imm : 32'd4;

    // ---- Store data and byte write enables ----
    wire [31:0] st_repl  = {4{rd2[7:0]}};                  // SB
    wire [31:0] st_half  = {rd2[15:0], rd2[15:0]};        // SH
    wire [31:0] st_data  = (mem_size == 2'b00) ? st_repl :
                           (mem_size == 2'b01) ? st_half : rd2;

    wire [3:0] wen_byte = 4'b0001 << data_addr[1:0];
    wire [3:0] wen_half = data_addr[1] ? 4'b1100 : 4'b0011;
    wire [3:0] wen_base = (mem_size == 2'b00) ? wen_byte :
                          (mem_size == 2'b01) ? wen_half : 4'b1111;
    assign data_wen = (mem_write & ~rst) ? wen_base : 4'b0000;

    // ---- Load data sign/zero extension ----
    wire [7:0]  lb_data = data_rdata[data_addr[1:0] * 8 +: 8];
    wire [15:0] lh_data = data_rdata[data_addr[1] * 16 +: 16];
    assign mem_data =
        (mem_size == 2'b00) ? (mem_sign ? {{24{lb_data[7]}}, lb_data}
                                        : {24'b0, lb_data}) :
        (mem_size == 2'b01) ? (mem_sign ? {{16{lh_data[15]}}, lh_data}
                                        : {16'b0, lh_data}) :
        data_rdata;

    // ---- Register writeback mux (alu / memory / immediate / csr) ----
    assign wb_data = (write_src == 2'b00) ? alu_result :
                     (write_src == 2'b01) ? mem_data :
                     (write_src == 2'b10) ? imm : csr_rdata;

    // No register writes while reset is asserted.
    wire wb_we = reg_write & ~rst;

    // ---- Outputs ----
    assign inst_addr      = pc;
    assign data_addr      = alu_result;
    assign data_wdata     = st_data;
    assign data_read      = mem_read;

    assign dbg_pc         = pc;
    assign dbg_inst       = inst;
    assign dbg_rd         = inst[11:7];
    assign dbg_wb_data    = wb_data;
    assign dbg_reg_write  = wb_we;
    assign dbg_data_addr  = data_addr;
    assign dbg_st_wen     = data_wen;
    assign dbg_st_data    = st_data;
    assign dbg_pc_next    = pc_target;

    // ---- Sub-modules ----
    control #(
        .INTR_EN (INTR_EN)
    ) u_ctrl (
        .inst        (inst),
        .reg_write   (reg_write),
        .mem_write   (mem_write),
        .branch      (branch),
        .jump        (jump),
        .write_src   (write_src),
        .alu_src_a   (alu_src_a),
        .alu_src_b   (alu_src_b),
        .alu_control (alu_control),
        .imm_sel     (imm_sel),
        .mem_size    (mem_size),
        .mem_sign    (mem_sign),
        .csr_we      (csr_we),
        .csr_rmode   (csr_rmode),
        .csr_imm     (csr_imm),
        .is_mret     (is_mret),
        .mem_read    (mem_read)
    );

    register_file u_regfile (
        .clk   (clk),
        .we    (wb_we),
        .rs1   (inst[19:15]),
        .rs2   (inst[24:20]),
        .rd    (inst[11:7]),
        .wdata (wb_data),
        .rd1   (rd1),
        .rd2   (rd2)
    );

    imm_gen u_immgen (
        .inst    (inst),
        .imm_sel (imm_sel),
        .imm     (imm)
    );

    alu u_alu (
        .a           (alu_a),
        .b           (alu_b),
        .alu_control (alu_control),
        .result      (alu_result),
        .zero        (alu_zero),
        .lt_s        (lt_s),
        .lt_u        (lt_u)
    );

endmodule