# RISC-V CPU — Learning Guide

A single-cycle RV32I CPU written in Verilog, with a self-checking assembler
testbench, a detailed simulation log, and an optional SoC (system bus, UART,
timer, interrupts).

This repository is both a **working CPU** and a **teaching tool**. The
documents in this folder take you from "what is RISC-V" to "write, assemble,
link, load and run your own program", and then "how the hardware actually
executes it".

---

## Reading order

| Document | What you learn |
|----------|----------------|
| `riscv-isa.md`    | The RISC-V architecture: registers, instruction formats, the full RV32I instruction set, CSRs and interrupts, assembly basics. |
| `cpu-design.md`   | How a single-cycle datapath works and how this CPU is built, module by module. |
| `programming.md`  | How to write programs for it: toolchain, build system, worked examples, reading the simulation logs, and exercises. |
| `architecture.md` | Quick reference: address map, register maps, and the connection diagrams. |

### Diagrams

Ready-to-use PNG images are in `diagrams/`:

| Diagram | File | Shows |
|---------|------|-------|
| System architecture | `diagrams/system_architecture.png` | the whole system end-to-end: host toolchain → Verilator simulation (testbench + SoC) → logs/waveform/result |
| Single-cycle datapath | `diagrams/cpu_datapath.png` | PC → instruction memory → registers/ALU → writeback, plus control and CSR paths |
| SoC block diagram | `diagrams/soc.png` | core, memory, system bus, UART, timer, interrupt controller and their connections |
| Interrupt flow | `diagrams/interrupt_flow.png` | from an asserted IRQ through the trap, handler and `mret` |
| Address map | `diagrams/address_map.png` | the memory map and the machine CSRs |

---

## Quick start

Prerequisites:

- A RISC-V GNU toolchain (`riscv64-elf-as`, `riscv64-elf-ld`,
  `riscv64-elf-objcopy`)
- Verilator 5.x

Build and simulate:

```sh
make            # bare CPU: core + unified memory
make soc        # SoC: core + system bus + UART + timer + interrupts
make gdb        # build and run the GDB debug server (see below)
make elf        # assemble + link sw/test.elf
make soc-elf    # assemble + link sw/soc_test.elf (the GDB-loadable image)
make address-map  # print the memory map
make clean
```

Each build assembles and links its test program into both a **hex** memory
image (loaded by the Verilog testbenches) and an **ELF** (`sw/test.elf`,
`sw/soc_test.elf`) that `riscv64-elf-gdb` can load when debugging.

Expected result: `TEST PASSED` for both configurations, and zero Verilator
warnings.

### Debugging with GDB

The simulation includes a GDB server so you can debug your program on the
real RTL model with `riscv64-elf-gdb` (breakpoints, single-step, continue,
registers and memory). The full workflow is in `programming.md` §7b
"Debugging with GDB against the actual RTL".

Terminal 1 — start the server:

```sh
make gdb                       # builds the stub + sw/soc_test.elf, runs on :3333
```

Terminal 2 — attach and debug:

```sh
riscv64-elf-gdb sw/soc_test.elf   # ELF built by make gdb / make soc-elf
(gdb) target remote :3333
(gdb) load                    # write the program into simulated memory
(gdb) break main
(gdb) continue
(gdb) stepi
(gdb) info registers
(gdb) x/8wx 0x4000
(gdb) quit                    # detaches; the simulator keeps running
```

Use `GDB_PORT=4444 make gdb` to pick a different port.

### What the simulation produces

| Artifact           | Contents                                        |
|--------------------|-------------------------------------------------|
| `sim.log`          | detailed per-instruction trace (bare CPU)       |
| `sim_soc.log`      | detailed per-instruction trace (SoC)            |
| `wave.vcd`         | bare-CPU waveform                               |
| `wave_soc.vcd`     | SoC waveform                                    |
| `sw/test.hex`      | memory image for the bare CPU test              |
| `sw/soc_test.hex`  | memory image for the SoC test                   |
| `sw/test.elf`      | bare CPU test ELF (load in gdb)                 |
| `sw/soc_test.elf`  | SoC test ELF (load in gdb)                      |

---

## Repository layout

```
rtl/                 Verilog source (see cpu-design.md)
  alu.v              ALU
  register_file.v    32 x 32 register file
  imm_gen.v          immediate generator
  control.v          instruction decoder
  memory.v           unified instruction/data memory
  rv32i_core.v       single-cycle datapath (optional CSR + interrupts)
  csr_file.v         machine-mode CSRs (mstatus, mie, mtvec, ...)
  rv32i_bare.v       bare configuration: core + memory
  system_bus.v       address-decode bus
  uart.v             memory-mapped UART
  timer.v            memory-mapped countdown timer
  interrupt_controller.v   aggregates peripheral IRQs
  rv32i_soc.v        SoC configuration: core + memory + bus + peripherals
  rv32i_gdb.v        GDB top: SoC + debug interface for the C++ harness
sw/                  assembly test programs
  test.S             self-checking RV32I test (bare)
  soc_test.S         self-checking SoC test (CSR, interrupts, UART, timer)
  link.ld            flat linker script
  test.elf / test.hex      built by "make elf" / "make" (gdb image + memory image)
  soc_test.elf / soc_test.hex  built by "make soc-elf" / "make soc"
tb/                  Verilog testbenches and the GDB server
  tb_rv32i.v         bare-CPU testbench (detailed log)
  tb_soc.v           SoC testbench (detailed log)
  riscv_decode.vh    shared mnemonic decoder for the logs
  gdb_main.cpp       GDB remote-protocol server (built by "make gdb")
```

---

## Key facts up front

- **ISA:** RV32I (base integer) plus the Zicsr extension (CSR instructions
  and `mret`), used for interrupt handling.
- **Design:** single-cycle — every instruction completes in exactly one
  clock cycle. There are no pipelines and no hazards.
- **Memory:** one unified byte-addressed array holds both instructions and
  data (von Neumann model). Instruction fetch and data access both happen
  in the same cycle through combinational read ports.
- **Configurations:** the same core is used with `INTR_EN=0` (bare) or
  `INTR_EN=1` (SoC, adds CSRs, `mret` and the interrupt mechanism).

Read on in `riscv-isa.md` to start learning the architecture.