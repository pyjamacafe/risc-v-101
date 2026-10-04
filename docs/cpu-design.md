# How the CPU Works

This document explains the Verilog implementation: the single-cycle idea,
each module's job, and how an instruction travels through the datapath. It
complements the architecture reference in `architecture.md` and the
architecture tutorial in `riscv-isa.md`.

---

## 1. The single-cycle idea

A *single-cycle* CPU finishes every instruction in **one clock period**.
Within that period the hardware does all five classical phases:

```
  fetch  →  decode  →  execute  →  memory  →  writeback
```

There is no pipelining and therefore **no hazards** (no data hazards, no
control hazards, no stall logic) — that is the appeal of this design for
learning. The cost is that the clock period must be long enough for the
slowest path through the combinational logic.

The core structure is:

```
                 +---------------------+
    pc ─────────►│  instruction memory │──► instruction (32-bit)
                 +---------------------+
                           │
                           ▼
                 +---------------------+   registers / ALU / immediate
                 │     decode +        │   compute the result and the
                 │     execute         │   data-memory address
                 +---------------------+
                           │
                           ▼
                 +---------------------+
    alu result ─►│  data memory /      │──► load data (or store write)
                 │  peripherals        │
                 +---------------------+
                           │
                           ▼
                 +---------------------+
                 │  writeback + PC     │   registers updated; PC advances
                 +---------------------+
```

At the rising clock edge, all state (PC, registers, data memory writes,
CSRs) updates at once, and the next cycle begins.

### Sequential vs combinational

Only these things are **sequential** (update on the clock edge):

- the program counter;
- the register file (write port);
- the data-memory write port (stores);
- the CSR registers.

Everything else — reading instructions, reading registers, the ALU, the
branch decision, load-data selection, the next-PC calculation — is
**combinational**: it settles within the cycle. That is why reads of the
unified memory can be used for both instruction fetch and data access in
the same cycle.

---

## 2. Module tour

| File | Module | Job |
|------|--------|-----|
| `rtl/alu.v` | `alu` | 32-bit ALU (add/sub/and/or/xor/slt/sltu/shifts) and comparison flags |
| `rtl/register_file.v` | `register_file` | 32×32 register file, `x0` hardwired |
| `rtl/imm_gen.v` | `imm_gen` | builds I/S/B/U/J immediates |
| `rtl/control.v` | `control` | decodes the instruction into control signals |
| `rtl/memory.v` | `unified_memory` | one byte-addressed array for instructions *and* data |
| `rtl/rv32i_core.v` | `rv32i_core` | the datapath; ties the others together |
| `rtl/csr_file.v` | `csr_file` | machine-mode CSRs and trap/mret logic (SoC) |
| `rtl/system_bus.v` | `system_bus` | address decode + read mux + write routing |
| `rtl/uart.v` | `uart` | memory-mapped serial transmitter/receiver |
| `rtl/timer.v` | `timer` | memory-mapped countdown timer |
| `rtl/interrupt_controller.v` | `interrupt_controller` | aggregates peripheral IRQs |
| `rtl/rv32i_bare.v` | `rv32i_bare` | core + memory (bare config) |
| `rtl/rv32i_soc.v` | `rv32i_soc` | core + memory + bus + peripherals (SoC config) |
| `rtl/rv32i_gdb.v` | `rv32i_gdb` | SoC + debug interface, driven by the GDB server |

---

## 3. The datapath, phase by phase

Follow one instruction, say `add t2, t0, t1` (`0x006283b3`).

### 3.1 Fetch

`pc` is presented on `inst_addr`. `unified_memory` reads four bytes at that
address combinationally and returns `inst`.

### 3.2 Decode

`control` looks at `inst[6:0]` (opcode), `inst[14:12]` (funct3) and
`inst[31:25]` (funct7) and produces the control signals:

| Signal       | For `add t2,t0,t1`         |
|--------------|----------------------------|
| `reg_write`  | 1 (write `rd`)             |
| `alu_control`| `0010` (ADD)               |
| `alu_src_a`  | 0 (use `rs1`)              |
| `alu_src_b`  | 0 (use `rs2`)              |
| `write_src`  | 0 (write back the ALU result) |

`imm_gen` builds the immediate (unused here). The register file reads
`rs1` (=`t0`) and `rs2` (=`t1`) on its two combinational read ports.

### 3.3 Execute

The ALU operand mux selects `A = rd1` and `B = rd2`, and the ALU computes
`result = rd1 + rd2`. The same ALU also produces the `zero`, `lt_s`,
`lt_u` flags used by the branch logic.

For a load or store, the ALU is used to compute the **address**
(`rs1 + imm`). For a branch, it is used as a comparator (subtract for
`beq`/`bne`, signed/unsigned compare for the others).

### 3.4 Memory

The address (the ALU result) goes to the data port:

- **load** — `data_rdata` comes back from the bus/memory and the sign/zero
  extension logic selects the requested byte/half/word;
- **store** — the byte-enable logic (`wen_base`) selects which bytes to
  write and the data is replicated for byte/half stores;
- **SoC** — the address goes through `system_bus`, which decodes
  `addr[31:28]` to pick memory, UART or timer.

### 3.5 Writeback and next PC

`wb_data` selects between the ALU result, the loaded data, the immediate
(`lui`) or the CSR value (`csr` instructions). The register file writes it
to `rd` on the clock edge.

In parallel, the next PC is chosen:

```
next_PC = trap ? mtvec : mret ? mepc : jump/JALR ? target : branch? : PC+4
```

A branch compares `rs1`/`rs2` (via the ALU flags) against the branch type
in `funct3`. All of this is combinational; `pc` updates on the edge.

---

## 4. The unified memory

`rtl/memory.v` holds one byte array. Because instruction fetch and data
access both need to happen in the same cycle, the reads are combinational:

- the **instruction** port reads `mem[PC+3 … PC]`;
- the **data** port reads a word-aligned base selected by `data_addr`,
  using `data_addr[1:0]` to pick the exact byte/halfword;
- the **write** port takes per-byte write enables, so `sb`, `sh` and `sw`
  all work on the same word-aligned base.

The memory is loaded from a `$readmemh` hex file (one byte per line,
little-endian) at simulation start.

This is the classic "instruction and data share one array" (von Neumann)
design. A Harvard machine would use two arrays; a real single-port SRAM
would need to time-share the port, but the combinational-read model keeps
the single-cycle promise.

---

## 5. The system bus

`rtl/system_bus.v` is a simple memory-mapped bus with one master (the core's
data port) and three slaves. The decode is intentionally coarse — top
address bits `[31:28]`:

| `addr[31:28]` | Slave |
|---------------|-------|
| `0000`        | unified memory   |
| `0001`        | UART            |
| `0010`        | timer           |
| others        | unmapped (reads 0, writes dropped) |

Reads are a combinational mux; writes are gated per slave by the write
enables. A read strobe is forwarded so peripherals can act on reads (e.g.
the UART clears its "data available" flag when `RX_DATA` is read).

The full address map and register offsets are in `architecture.md`.

---

## 6. Peripherals

### 6.1 UART (`rtl/uart.v`)

A memory-mapped 8N1 serial port:

- **TX engine** — a state machine shifts out start, 8 data bits (LSB
  first) and stop, one bit per `CLK_DIV` clock cycles. `TX_READY` is set
  when the transmitter is idle.
- **RX engine** — detects a falling start bit, samples each data bit at
  the bit centre and sets `RX_AVAIL` with the received byte. Reading
  `RX_DATA` clears `RX_AVAIL`. The receive buffer is a single byte: if the
  CPU does not read before the next byte finishes, it is overwritten.

Interrupts are level signals gated by `IRQ_EN`:

```
irq_rx = RX_AVAIL & irq_en[0]
irq_tx = TX_DONE_PENDING & irq_en[1]
```

In the SoC testbench the transmitter is looped back to the receiver, so a
program can send a byte and read it back — a full send/receive round trip.

### 6.2 Timer (`rtl/timer.v`)

A countdown timer:

- writing `LOAD` loads the count;
- with `CTRL.enable` set, the count decrements every cycle;
- on reaching zero it sets `pending` and reloads from `LOAD` (periodic);
- `irq_out = pending & irq_en & enable`;
- reading `STATUS` clears `pending`.

### 6.3 Interrupt controller (`rtl/interrupt_controller.v`)

Maps the peripheral IRQs onto the core's vector:

```
irq[0] = timer expired
irq[1] = UART RX data available
irq[2] = UART TX complete
```

Each line passes through a two-flop synchronizer so the core never samples
a metastable input.

---

## 7. The CSR file and interrupts

`rtl/csr_file.v` implements the CSRs and the hardware trap/return updates.
Only present when the core is built with `INTR_EN=1` (the SoC build).

The trap decision, computed combinationally in `rv32i_core.v`:

```
irq_pending = irq & mie[3:0] & {4{mstatus[MIE]}}
take_trap   = |irq_pending        # an enabled interrupt is waiting
```

When `take_trap` is true in a cycle, that same clock edge:

- the in-flight instruction still completes (its register/memory writes
  happen);
- `mepc` is written with the *next* PC (so `mret` resumes correctly);
- `mcause` is written with `0x80000000 | index`;
- `mstatus.MPIE` saves `MIE`, and `MIE` is cleared;
- `pc` is loaded from `mtvec` instead of the normal next PC.

`mret` (decoded by the control unit) does the reverse on the next edge:
`pc = mepc`, `MIE = MPIE`, `MPIE = 1`.

The low-index line wins when several are pending at once.

---

## 8. The debug interface (GDB)

The RTL carries a small *debug port* that the GDB server (`tb/gdb_main.cpp`)
uses to inspect and control the CPU. It is completely separate from the
system bus — GDB talks to the host, not to the program.

| Signal            | Direction | Purpose                                    |
|-------------------|-----------|--------------------------------------------|
| `dbg_hold`        | in        | halt the CPU: no instruction executes, PC freezes |
| `dbg_pc_we/wval`  | in        | override the PC (set `$pc`, `load` entry)  |
| `dbg_reg_ridx/rval` | in/out  | read any register x0..x31                  |
| `dbg_reg_we/widx/wval` | in   | write a register (x0 ignored)              |
| `dbg_csr_idx/val` | in/out    | read machine CSRs (`mstatus`, `mie`, …)    |
| `dbg_peek_addr/data` | in/out | combinational memory read                 |
| `dbg_mem_waddr/wdata/wen` | in | memory write with byte enables           |

How it works:

- While `dbg_hold` is high, the register-file write enable, the data-memory
  write enables and the interrupt trap are all gated off, and the PC keeps
  its value — so the host can safely clock the design (to perform a
  register or memory write) without advancing the program.
- Reads (registers, CSRs, memory) are combinational: the host sets an index
  or address and samples the result, no clock edge needed.
- In the single-cycle machine one clock step executes exactly one
  instruction, which is exactly what GDB's `stepi` wants.
- `rv32i_gdb` wraps `rv32i_soc` and exposes these ports; the C++ harness in
  `tb/gdb_main.cpp` implements the GDB remote protocol on top of them.

See `programming.md` §7b for how to use GDB.

---

## 9. Configurations

The core is parameterized: `rv32i_core #(.INTR_EN(0))` is the bare CPU and
`.INTR_EN(1)` adds the CSR/`mret` decode and the interrupt hardware.

- `rv32i_bare` wraps the core with `INTR_EN=0` plus the unified memory.
- `rv32i_soc` wraps the core with `INTR_EN=1`, the unified memory, the
  system bus, UART, timer and interrupt controller.
- `rv32i_gdb` wraps `rv32i_soc` with the debug interface for the GDB
  server.

Both the bare and SoC configurations share the same single-cycle datapath,
which is why a program that runs on the bare CPU also runs on the SoC (the
SoC test additionally exercises CSRs, interrupts, UART and timer).

---

## 10. What could you change next?

- Add a multiply/divide unit (the M extension).
- Split instruction and data memory (Harvard model).
- Convert to a multi-cycle or pipelined design and add hazard handling.
- Add a UART receive FIFO so multiple bytes can queue.
- Add software-triggered exceptions (`ecall`).
- Add a second bus master and a proper arbitration scheme.
- Expose the machine CSRs to GDB as extra registers in the target
  description.