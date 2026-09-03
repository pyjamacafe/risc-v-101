`timescale 1ns/1ps
// Single-cycle RV32I core with unified (von Neumann) instruction/data memory.
//
// Every instruction completes in one clock cycle. The unified memory module
// provides combinational read ports so the instruction fetch and data access
// both happen within the same cycle, and a single write port for stores.

module rv32i_core #(
    parameter MEM_BYTES = 16384,
    parameter INIT_FILE = ""
) (
    input  wire        clk,
    input  wire        rst,
    // Debug / observation ports
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_inst,
    input  wire [31:0] dbg_peek_addr,
    output wire [31:0] dbg_peek_data,
    // Detailed trace ports (used by the testbench for execution logging)
    output wire [ 4:0] dbg_rd,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_reg_write,
    output wire [31:0] dbg_data_addr,
    output wire [ 3:0] dbg_st_wen,
    output wire [31:0] dbg_st_data,
    output wire [31:0] dbg_pc_next
);

    // ---- Internal wires ----
    wire [31:0] inst;          // fetched instruction
    wire [31:0] rd1, rd2;      // register file reads
    wire [31:0] imm;           // generated immediate
    wire [31:0] alu_a, alu_b;  // ALU operands
    wire [31:0] alu_result;
    wire        alu_zero, lt_s, lt_u;
    wire [31:0] data_rdata;    // memory read data
    wire [ 3:0] st_wen;        // store byte write enables
    wire [31:0] mem_data;      // sign/zero extended load data
    wire [31:0] wb_data;       // register file write data
    reg  [31:0] pc_next;
    reg  [31:0] pc;

    // ---- Control signals ----
    wire        reg_write, mem_write, branch;
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

    // ---- Next PC ----
    wire [31:0] pc_plus4     = pc + 32'd4;
    wire [31:0] branch_target = pc + imm;
    wire [31:0] jalr_target   = (rd1 + imm) & 32'hFFFFFFFE;

    always @(*) begin
        case (jump)
            2'b01 : pc_next = branch_target;             // JAL
            2'b10 : pc_next = jalr_target;               // JALR
            default: pc_next = branch_taken ? branch_target : pc_plus4;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            pc <= 32'b0;
        else
            pc <= pc_next;
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

    wire [3:0] wen_byte = 4'b0001 << alu_result[1:0];
    wire [3:0] wen_half = alu_result[1] ? 4'b1100 : 4'b0011;
    wire [3:0] wen_base = (mem_size == 2'b00) ? wen_byte :
                          (mem_size == 2'b01) ? wen_half : 4'b1111;
    assign st_wen = (mem_write & ~rst) ? wen_base : 4'b0000;

    // No register or memory writes while reset is asserted.
    wire wb_we = reg_write & ~rst;

    // ---- Load data sign/zero extension ----
    wire [7:0]  lb_data = data_rdata[alu_result[1:0] * 8 +: 8];
    wire [15:0] lh_data = data_rdata[alu_result[1] * 16 +: 16];
    assign mem_data =
        (mem_size == 2'b00) ? (mem_sign ? {{24{lb_data[7]}}, lb_data}
                                        : {24'b0, lb_data}) :
        (mem_size == 2'b01) ? (mem_sign ? {{16{lh_data[15]}}, lh_data}
                                        : {16'b0, lh_data}) :
        data_rdata;

    // ---- Register writeback mux ----
    assign wb_data = (write_src == 2'b00) ? alu_result :
                     (write_src == 2'b01) ? mem_data : imm;

    // ---- Debug outputs ----
    assign dbg_pc        = pc;
    assign dbg_inst      = inst;
    assign dbg_rd        = inst[11:7];
    assign dbg_wb_data   = wb_data;
    assign dbg_reg_write = wb_we;
    assign dbg_data_addr = alu_result;
    assign dbg_st_wen    = st_wen;
    assign dbg_st_data   = st_data;
    assign dbg_pc_next   = pc_next;

    // ---- Sub-modules ----
    control u_ctrl (
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
        .mem_sign    (mem_sign)
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

    unified_memory #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE (INIT_FILE)
    ) u_mem (
        .clk         (clk),
        .inst_addr   (pc),
        .inst        (inst),
        .data_addr   (alu_result),
        .data_wdata  (st_data),
        .data_wen    (st_wen),
        .data_rdata  (data_rdata),
        .dbg_addr    (dbg_peek_addr),
        .dbg_data    (dbg_peek_data)
    );

endmodule