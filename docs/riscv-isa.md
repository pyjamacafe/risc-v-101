# RISC-V Architecture

This document teaches the RISC-V architecture that this CPU implements. It
is written to be read top to bottom; each section builds on the previous
ones. If you already know RISC-V, skim to the sections marked
"…in this CPU" for the specific details of this implementation.

---

## 1. What is RISC-V?

RISC-V is an **open, free instruction set architecture (ISA)**. Anyone can
build hardware or software for it without paying license fees, which makes
it popular in education, research and industry.

The ISA is **modular**. At its core is a small *base* ISA that every
implementation must provide; optional *extensions* add functionality.

| Extension | Provides                          |
|-----------|-----------------------------------|
| RV32I     | the base 32-bit integer ISA       |
| RV32M     | integer multiply / divide         |
| RV32A     | atomics                          |
| RV32F/D   | single/double-precision floating point |
| RV32C     | compressed 16-bit instructions    |
| Zicsr     | Control and Status Registers (CSRs) and the `mret` instruction |
| Zifencei  | instruction-fetch fence           |

This CPU implements **RV32I + Zicsr** (Zicsr is what makes interrupts
possible).

"RV32" means 32-bit registers and addresses; "I" means the base integer
instruction set.

---

## 2. The programming model

### 2.1 Registers

A 32-bit RISC-V CPU has **32 general-purpose registers**, `x0` … `x31`,
each 32 bits wide, plus a program counter (PC).

```
 x0  ───────────────────────────  x16  a6
 x1  ra  (return address)          x17  a7
 x2  sp  (stack pointer)           x18  s2
 x3  gp  (global pointer)          x19  s3
 x4  tp  (thread pointer)          x20  s4
 x5  t0                            x21  s5
 x6  t1                            x22  s6
 x7  t2                            x23  s7
 x8  s0/fp (saved / frame ptr)     x24  s8
 x9  s1                            x25  s9
 x10 a0 (argument / return)        x26  s10
 x11 a1 (argument / return)        x27  s11
 x12 a2                            x28  t3
 x13 a3                            x29  t4
 x14 a4                            x30  t5
 x15 a5                            x31  t6
```

The two-letter names are the **ABI names** and are what assemblers and
compilers actually use. The important special cases:

- **`zero`/`x0`** is hardwired to 0. Writes to it are discarded — it is a
  very common way to build small constants or to discard a value.
- **`ra`/`x1`** holds the return address for subroutine calls.
- **`sp`/`x2`** is the stack pointer.

### 2.2 Memory

- Byte-addressable.
- **Little-endian**: the least-significant byte of a word lives at the
  lowest address. This CPU's test programs rely on this.
- A *word* is 32 bits (4 bytes) in RV32.

In this CPU, instructions and data share one memory array (the *unified* or
*von Neumann* model), so a program can read and write its own code if it
wants to.

### 2.3 Program counter

The PC holds the address of the instruction being executed. After most
instructions the PC advances by **4** (one word). Branches, jumps and
interrupts change it to another value.

---

## 3. Instruction formats

Every RV32 instruction is exactly **32 bits**. The field at the bottom is
always the **opcode** (bits 6:0). Six formats cover all of RV32I:

```
R-type  (register-register ALU):
  funct7  | rs2  | rs1  | funct3 | rd  | opcode
  [31:25] [24:20][19:15][14:12] [11:7][6:0]

I-type  (immediate ALU, loads, JALR, CSRs):
  imm[11:0] | rs1  | funct3 | rd  | opcode
  [31:20]   [19:15][14:12] [11:7][6:0]

S-type  (stores):
  imm[11:5] | rs2  | rs1  | funct3 | imm[4:0] | opcode
  [31:25]   [24:20][19:15][14:12] [11:7]    [6:0]

B-type  (branches):
  imm[12|10:5] | rs2  | rs1  | funct3 | imm[4:1|11] | opcode
  [31] [30:25] [24:20][19:15][14:12] [11:8] [7]    [6:0]

U-type  (LUI, AUIPC):
  imm[31:12] | rd  | opcode
  [31:12]    [11:7][6:0]

J-type  (JAL):
  imm[20|10:1|11|19:12] | rd  | opcode
  [31]  [30:21] [20] [19:12]  [11:7][6:0]
```

The bits are always in the same place, which makes the decoder tiny: the
register fields (`rs1`, `rs2`, `rd`) never move between formats.

### Immediate encoding

Immediates are the one genuinely fiddly part of RISC-V. Instead of storing
a fixed-width field, each format splices together bits of the instruction:

```
I:  imm = sign_extend( inst[31:20] )
S:  imm = sign_extend( inst[31:25] ++ inst[11:7] )
B:  imm = sign_extend( inst[31] ++ inst[7] ++ inst[30:25] ++ inst[11:8] ) << 1
U:  imm = inst[31:12] << 12
J:  imm = sign_extend( inst[31] ++ inst[19:12] ++ inst[20] ++ inst[30:21] ) << 1
```

Notes:

- I and S immediates are sign-extended to 32 bits.
- B (branch) and J (jump) immediates are **shifted left by one** — they are
  always even numbers, because the PC is always word-aligned.
- U immediates are shifted left by 12 (they build the top 20 bits of a
  constant).

The `imm_gen` module (`rtl/imm_gen.v`) implements exactly this table.

---

## 4. The RV32I instruction set

### 4.1 Register-immediate ALU (I-type, opcode `0010011`)

These compute `rd = rs1 op imm`:

| Instruction | funct3 | Meaning                    |
|-------------|--------|----------------------------|
| `addi`      | 000    | rd = rs1 + imm             |
| `slti`      | 010    | rd = 1 if rs1 < imm (signed) |
| `sltiu`     | 011    | rd = 1 if rs1 < imm (unsigned) |
| `xori`      | 100    | rd = rs1 XOR imm           |
| `ori`       | 110    | rd = rs1 OR imm            |
| `andi`      | 111    | rd = rs1 AND imm           |
| `slli`      | 001    | rd = rs1 << shamt          |
| `srli`      | 101    | rd = rs1 >> shamt (logical) |
| `srai`      | 101    | rd = rs1 >> shamt (arithmetic) |

The shift instructions use `imm[4:0]` as the shift amount (`shamt`).
`srai` is distinguished from `srli` by `funct7 == 0100000` (arithmetic
shift fills the top bits with the sign bit).

### 4.2 Register-register ALU (R-type, opcode `0110011`)

These compute `rd = rs1 op rs2`:

| Instruction | funct3 | funct7    | Meaning                    |
|-------------|--------|-----------|----------------------------|
| `add`       | 000    | 0000000   | rd = rs1 + rs2             |
| `sub`       | 000    | 0100000   | rd = rs1 - rs2             |
| `sll`       | 001    | 0000000   | rd = rs1 << rs2[4:0]       |
| `slt`       | 010    | 0000000   | rd = 1 if rs1 < rs2 (signed) |
| `sltu`      | 011    | 0000000   | rd = 1 if rs1 < rs2 (unsigned) |
| `xor`       | 100    | 0000000   | rd = rs1 XOR rs2           |
| `srl`       | 101    | 0000000   | rd = rs1 >> rs2[4:0] (logical) |
| `sra`       | 101    | 0100000   | rd = rs1 >> rs2[4:0] (arithmetic) |
| `or`        | 110    | 0000000   | rd = rs1 OR rs2            |
| `and`       | 111    | 0000000   | rd = rs1 AND rs2           |

The only difference between `add`/`sub` and `srl`/`sra` is `funct7`.

### 4.3 Loading constants: LUI and AUIPC (U-type)

```
lui   rd, imm20   →  rd = imm20 << 12            (opcode 0110111)
auipc rd, imm20   →  rd = PC + (imm20 << 12)     (opcode 0010111)
```

- `lui` puts the 20-bit immediate in the top bits of `rd`. The low 12 bits
  are zero.
- `auipc` does the same but adds the current PC — useful for position
  independent code.

To load an arbitrary 32-bit constant you combine `lui` with `addi` (the
assembler pseudoinstruction `li` does this for you):

```asm
lui  t0, 0x12345          # t0 = 0x12345000
addi t0, t0, 0x678        # t0 = 0x12345678
```

### 4.4 Loads and stores

Loads (opcode `0000011`, I-type) read memory and put the value in `rd`:

| Instruction | funct3 | What it loads          | Extends          |
|-------------|--------|------------------------|------------------|
| `lb`        | 000    | 1 byte                 | sign             |
| `lh`        | 001    | 2 bytes                | sign             |
| `lw`        | 010    | 4 bytes                | —                |
| `lbu`       | 100    | 1 byte                 | zero             |
| `lhu`       | 101    | 2 bytes                | zero             |

The effective address is `rs1 + imm`.

Stores (opcode `0100011`, S-type) write `rs2` to memory:

| Instruction | funct3 | What it writes  |
|-------------|--------|-----------------|
| `sb`        | 000    | 1 byte  (low byte of rs2) |
| `sh`        | 001    | 2 bytes (low half of rs2) |
| `sw`        | 010    | 4 bytes         |

The effective address is `rs1 + imm`.

Example:

```asm
la   t0, 0x3000            # t0 = address
sw   t1, 0(t0)             # store t1 at [0x3000]
lw   t2, 0(t0)             # t2 = load from [0x3000]
```

### 4.5 Branches (B-type, opcode `1100011`)

Branches compare two registers and jump relative to the PC if the condition
holds. The target address is `PC + imm`.

| Instruction | funct3 | Branch taken when   |
|-------------|--------|---------------------|
| `beq`       | 000    | rs1 == rs2          |
| `bne`       | 001    | rs1 != rs2          |
| `blt`       | 100    | rs1 < rs2  (signed) |
| `bge`       | 101    | rs1 >= rs2 (signed) |
| `bltu`      | 110    | rs1 < rs2  (unsigned) |
| `bgeu`      | 111    | rs1 >= rs2 (unsigned) |

There is no `j` pseudo needed for a branch backwards in a loop:

```asm
loop:
    addi t0, t0, -1
    bne  t0, zero, loop    # repeat until t0 == 0
```

The branch offset is limited to about ±4 KiB.

### 4.6 Jumps

```
jal  rd, label   →  rd = PC + 4 ; PC = label        (opcode 1101111)
jalr rd, rs1, imm → rd = PC + 4 ; PC = (rs1+imm) & ~1  (opcode 1100111)
```

- `jal` (jump and link) saves the return address into `rd` (conventionally
  `ra`) and jumps to a PC-relative target (±1 MiB).
- `jalr` jumps to an absolute address held in a register.
- `jalr x0, ra, 0` returns from a subroutine — this is the `ret` pseudo.

Together they implement subroutines:

```asm
    jal   ra, my_func     # call my_func; ra = return address
    ...
my_func:
    ...
    jalr  x0, ra, 0       # return (ret)
```

### 4.7 System instructions (opcode `1110011`)

Two kinds matter here:

- **`mret`** — return from a machine-mode interrupt/exception handler.
  Its encoding is `0x30200073`.
- **CSR instructions** (Zicsr extension). `csrrw`, `csrrs`, `csrrc` read a
  CSR into `rd` and write `rs1`; the `csrrwi/csrrsi/csrrci` variants use a
  5-bit immediate. `csrr` reads a CSR.

These are what a program uses to configure interrupts (see section 6).

---

## 5. Control and Status Registers (CSRs)

CSRs are special registers addressed by a 12-bit number, accessed only
through the CSR instructions. This CPU implements the small machine-mode
subset needed for interrupts:

| Address | Name      | Purpose |
|---------|-----------|---------|
| `0x300` | `mstatus` | machine status: `MIE` (bit 3) global interrupt enable, `MPIE` (bit 7) saved enable |
| `0x304` | `mie`     | interrupt enable mask, bits 3:0 = one per interrupt line |
| `0x305` | `mtvec`   | trap vector base — where the handler lives |
| `0x340` | `mscratch`| a scratch register for handlers |
| `0x341` | `mepc`    | PC saved when a trap is taken |
| `0x342` | `mcause`  | why the trap happened |
| `0x344` | `mip`     | pending interrupt lines (read-only) |

Example — enable the timer interrupt:

```asm
csrw  mie, 1            # mie = 1 -> enable irq line 0 (timer)
csrw  mstatus, 8        # mstatus = 8 -> set MIE (global enable)
```

And set the handler address:

```asm
la   t0, handler
csrw mtvec, t0
```

---

## 6. Interrupts

### 6.1 What happens on an interrupt

This CPU has three interrupt lines (`irq[0..2]`). An interrupt is *taken*
when:

```
(irq & mie & mstatus.MIE) != 0
```

i.e. the line is requesting, that line is enabled in `mie`, and interrupts
are globally enabled in `mstatus.MIE`. When it happens, the hardware does
all of the following **in the cycle the interrupt is detected**:

1. `mepc` = the PC of the next instruction (so `mret` resumes correctly);
2. `mcause` = `0x80000000 | irq_index` (bit 31 marks "interrupt" vs
   "exception");
3. `mstatus.MPIE` = `mstatus.MIE` (remember the old enable);
4. `mstatus.MIE` = 0 (no nested interrupts);
5. PC = `mtvec` (jump to the handler).

### 6.2 The handler and `mret`

The handler runs with interrupts disabled. When it finishes it executes
`mret`, which:

1. PC = `mepc` (return to where you were interrupted);
2. `mstatus.MIE` = `mstatus.MPIE` (restore the old enable);
3. `mstatus.MPIE` = 1.

A minimal timer-interrupt handler:

```asm
handler:
    la    t0, counter          # count how many interrupts
    lw    t1, 0(t0)
    addi  t1, t1, 1
    sw    t1, 0(t0)

    li    t0, 0x20000000       # clear the timer's pending flag
    lw    t2, 12(t0)           # read timer STATUS -> clears pending

    mret
```

### 6.3 Interrupt-safe programming

Because an interrupt can occur **between any two instructions**, the handler
must not clobber registers that the interrupted code was using, unless the
interrupted code expects that (the usual rule: the handler may freely use
the caller-saved `t` registers but must preserve the callee-saved `s`
registers and `sp`). The SoC test program demonstrates this: the main loop
keeps its loop counter in `s2`/`s3` so the handler's use of `t0`–`t3` does
not corrupt it, and it reloads `t0` after every interrupt.

---

## 7. Assembly essentials

### 7.1 Directives

| Directive           | Meaning                                        |
|---------------------|------------------------------------------------|
| `.section .text`    | code section                                   |
| `.section .data`    | initialized data                               |
| `.globl name`       | make a label visible to the linker             |
| `.word 0`           | emit a 4-byte word (data)                      |
| `.align 2`          | align to 4 bytes                               |

### 7.2 Pseudoinstructions

The assembler turns these into one or more real instructions:

| Pseudo    | Expansion                              |
|-----------|----------------------------------------|
| `li rd, n`| `lui` + `addi` (or just `addi`/`lui`)  |
| `la rd, l`| `auipc` + `addi` (absolute address)    |
| `call l`  | `auipc` + `jalr` (long call)           |
| `ret`     | `jalr x0, ra, 0`                       |
| `nop`     | `addi x0, x0, 0`                       |
| `j l`     | `jal x0, l`                            |
| `beqz r,l`| `beq r, x0, l`                         |
| `mv rd,rs`| `addi rd, rs, 0`                       |
| `not rd,rs`| `xori rd, rs, -1`                     |

`li` and `la` are why the test programs must be **linked** before the binary
is extracted: the PC-relative relocations (`R_RISCV_PCREL_HI20/LO12`) can
only be resolved once the final addresses are known.

### 7.3 The calling convention (summary)

- Arguments in `a0`–`a7`; return value in `a0` (and `a1`).
- Return address in `ra`; `ret` = `jalr x0, ra, 0`.
- Caller-saved ("temporary") registers `t0`–`t6`, `a0`–`a7`, `ra`: a called
  function may change them; the caller must not rely on them after a call.
- Callee-saved registers `s0`–`s11`, `sp`: a called function must preserve
  them (typically by pushing them on the stack).

---

## 8. Checking yourself

- Which register is hardwired to zero?
- How is `li t0, 0x12345678` expanded by the assembler?
- Why are branch and jump immediates shifted left by one?
- What is the difference between `lw` and `lhu`? Between `srli` and `srai`?
- What must happen before an interrupt is taken?
- What does `mret` restore, and where does it return to?

When you are comfortable with these, read `cpu-design.md` to see how the
hardware implements all of this, then `programming.md` to write your own
programs.