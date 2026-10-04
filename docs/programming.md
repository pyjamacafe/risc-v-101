# Programming the CPU

This guide teaches you how to write, assemble, link, load and run your own
programs on this RISC-V CPU, and how to use the simulation to check what
happened. Read `riscv-isa.md` first if the instructions are new to you.

---

## 1. The toolchain

The project uses the GNU RISC-V toolchain, which runs on the host and
produces a memory image that the Verilog simulator loads.

| Tool                  | Job                                  |
|-----------------------|--------------------------------------|
| `riscv64-elf-as`      | assembles `.S` → object file         |
| `riscv64-elf-ld`      | links the object (resolves `la`)     |
| `riscv64-elf-objcopy` | extracts the raw binary              |
| `xxd`                 | converts the binary to a hex file    |
| `verilator`           | compiles and runs the Verilog        |

### The build flow

```
  test.S ──as──► test.o ──ld──► test.elf ──objcopy──► test.bin ──xxd──► test.hex
                                   │
                                   └── kept as sw/test.elf for GDB
```

Two files come out of the build:

- **`test.elf`** — the linked ELF, kept in `sw/` (`sw/test.elf`,
  `sw/soc_test.elf`). This is what `riscv64-elf-gdb` loads for debugging.
- **`test.hex`** — the byte-by-byte memory image the Verilog testbench
  loads into the unified memory via `$readmemh` (little-endian, one byte
  per line).

The shipped programs are built with `make elf` (→ `sw/test.elf`) and
`make soc-elf` (→ `sw/soc_test.elf`); `make gdb` builds the SoC ELF for
you. For a program of your own:

```
riscv64-elf-as  -march=rv32i_zicsr -mabi=ilp32  test.S -o test.o
riscv64-elf-ld  -m elf32lriscv -T sw/link.ld   test.o -o test.elf
riscv64-elf-objcopy -O binary test.elf test.bin
xxd -p -c 1 test.bin > test.hex
```

Notes:

- `-march=rv32i_zicsr` is required because the SoC test uses CSR
  instructions; the bare test needs only `rv32i`.
- The linker step matters: `la` (address-of-label) expands to
  `auipc`/`addi` with PC-relative relocations that can only be resolved
  once the final addresses are known. `sw/link.ld` keeps everything in a
  flat image starting at address 0.

The `Makefile` wraps all of this, so normally you do not run these commands
by hand.

---

## 2. Make targets

```
make              # bare CPU: assemble test.S, build with Verilator, simulate
make soc          # SoC: assemble soc_test.S, build, simulate
make hex          # just rebuild sw/test.hex
make soc-hex      # just rebuild sw/soc_test.hex
make address-map  # print the address map
make clean        # remove build artifacts and logs
```

After a run, look at:

- `sim.log` / `sim_soc.log` — the per-instruction execution trace;
- `wave.vcd` / `wave_soc.vcd` — waveforms you can open in a viewer such as
  GTKWave;
- the console output, which ends with `TEST PASSED` or `TEST FAILED`.

---

## 3. A first program, line by line

Here is a complete program that sums `1 + 2 + … + N` and stores the result
to memory. Save it as `sw/sum.S`.

```asm
# sum.S — compute 1+2+...+10 and store the result.
    .section .text
    .globl _start

_start:
    li    t0, 10            # N = 10
    li    t1, 0             # accumulator = 0
    li    t2, 1             # loop counter = 1

loop:
    add   t1, t1, t2        # acc += counter
    addi  t2, t2, 1         # counter++
    blt   t2, t0, loop      # repeat while counter < N
    add   t1, t1, t0        # add the final N (loop ran 1..N-1)

    # store result at address 0x5000
    li    t3, 0x5000
    sw    t1, 0(t3)

    # mark success: write 0x600D600D to 0x4000
    li    t4, 0x600D600D
    li    t5, 0x4000
    sw    t4, 0(t5)

halt:
    j     halt              # stop (infinite loop)
```

### Reading it

1. `li t0, 10` loads the constant 10. The assembler picks `addi t0, zero, 10`.
2. The loop accumulates `t1 += t2`, `t2` runs `1..N-1`, then the final
   `add` adds `N` itself, giving `1+2+…+N`.
3. `sw` writes the result to `0x5000` (inside the memory window).
4. Writing the sentinel `0x600D600D` to `0x4000` is how programs tell the
   testbench "I passed". A failing path would write `0xDEADBEEF` instead.
5. `j halt` spins forever so the testbench can detect that the program
   stopped (its PC stops changing).

### Build and run it

For a one-off you can copy `sw/test.S` aside and replace its body, or add a
new Makefile rule. The quickest way:

```sh
riscv64-elf-as  -march=rv32i_zicsr -mabi=ilp32 sw/sum.S -o /tmp/sum.o
riscv64-elf-ld  -m elf32lriscv -T sw/link.ld /tmp/sum.o -o /tmp/sum.elf
riscv64-elf-objcopy -O binary /tmp/sum.elf sw/sum.bin
xxd -p -c 1 sw/sum.bin > sw/sum.hex
```

Then point the testbench at it. The simplest way is to temporarily set
`HEX_FILE` in `tb/tb_rv32i.v` (and `MEM_BYTES`/`INIT_FILE` as needed) and
run `make`. Check the result in `sim.log`:

- the sentinel store: `st[00004000] <- 600d600d wen=1111`
- the result store: `st[00005000] <- 00000037 wen=1111`  (10·11/2 = 55)

If the program fails, `sim.log` will show `deadbeef` at `0x4000`.

---

## 4. Walkthrough of the shipped tests

### 4.1 `sw/test.S` (bare CPU)

This program exercises **every RV32I instruction** and self-checks the
result of each. It is a long list of small steps:

1. **Compute** a bunch of values in registers: `add`, `sub`, `and`, `or`,
   `xor`, `slt`, `sltu`, `sll`, `srl`, the shift-immediate forms
   (`slli`/`srli`/`srai`), and the I-type set (`addi`, `slti`, `xori`,
   `ori`, `andi`), plus `lui` and `auipc`.
2. **Check** each value: `li t0, <expected>` followed by
   `bne t<reg>, t0, fail`. If any check fails, control jumps to `fail`.
3. **Memory**: store and load back words, halfwords and bytes, including
   sign/zero extension and unaligned (odd-address) accesses — this is what
   verifies the byte-enable and extension logic.
4. **Branches**: each of `beq/bne/blt/bge/bltu/bgeu` is exercised both
   taken and not-taken.
5. **Loop**: a count-down loop that must run exactly the right number of
   times.
6. **JAL/JALR**: calls a subroutine and returns; verifies the link register
   `ra` holds the right return address.
7. On success, writes `0x600D600D` to `0x4000`; on failure `0xDEADBEEF`.

Study the pattern `li` + `bne` — it is the workhorse of self-checking code:

```asm
    li    t0, 160
    bne   a0, t0, fail      # a0 must equal 160
```

### 4.2 `sw/soc_test.S` (SoC)

This adds interrupts and peripherals on top of the bare tests:

1. **CSR round-trips**: `csrrw/csrrs/csrrc/csrrwi/csrrsi/csrrci` against
   `mscratch`, verifying the read value, the write, and the set/clear
   semantics.
2. **Interrupt setup**: sets `mtvec` to the handler, programs the timer
   (`LOAD`, then `CTRL = enable | irq_en`), enables the timer line in
   `mie`, and sets `mstatus.MIE`.
3. **Wait for 3 timer interrupts**: the main loop polls a memory counter
   that the handler increments. The handler clears the timer's pending
   flag (by reading `TIMER_STATUS`) and, on the third interrupt, disables
   the timer and all interrupts.
4. **UART loopback**: sends `'H' 'i' '!'` and reads them back over the
   loopback link, verifying TX and RX (the RX buffer is one byte, so it
   sends and receives one byte at a time).
5. Writes the pass/fail sentinel as before.

This program demonstrates the two hard parts of writing interrupt code:

- the handler must be installed (`mtvec`) and enabled (`mie`, `MIE`)
  before interrupts can fire;
- the handler must not clobber state the main loop depends on. It uses
  only the `t` (caller-saved) registers, and the main loop keeps its
  counter in `s2`/`s3` and reloads its pointer every iteration.

---

## 5. Reading the simulation log

Each line of `sim_soc.log` shows one instruction:

```
  #    time        pc       inst      mnemonic  effect
 236  2381000  00000120  17400293      ADDI  x5 <- 00000174
 244  2461000  00000148  30200073      MRET  CF -> 00000098
 657  6591000  000000f8  00552223        SW  st[10000004] <- 00000048 wen=1111
 747  7491000  00000118  00852503        LW  x10 <- 00000048  ld@10000008
```

- `pc` — address of the instruction;
- `inst` — the raw 32-bit encoding;
- `mnemonic` — decoded name;
- `xN <- value` — the register write (register `N`);
- `ld@addr` — a load from that address;
- `st[addr] <- data wen=bbbb` — a store (and which bytes);
- `CF -> addr` — a control-flow change: branch taken, `jal`/`jalr`,
  interrupt to the handler, or `mret` return.

This is your main debugging tool: trace backwards from a `fail` jump to see
which value was wrong.

---

## 6. Writing your own program — checklist

1. **Choose the configuration.** Anything using CSRs, interrupts, UART or
   the timer must run on the SoC build (`make soc`).
2. **Write the assembly** in `sw/`, e.g. `sw/myprog.S`. Start with a label
   `_start`, end with an infinite loop, and remember the pass/fail
   convention (`0x600D600D` / `0xDEADBEEF` at `0x4000`) so the testbench
   reports success.
3. **Build the image** with the four commands in section 1 (or add a
   Makefile rule).
4. **Point the testbench at it.** Edit `tb/tb_rv32i.v` (or `tb/tb_soc.v`):
   set `HEX_FILE` to your hex file. Run `make` (or `make soc`).
5. **Check the log.** Confirm the sentinel store appears and the values
   you expected are present.

Common mistakes:

- writing a constant address that does not fit in a 12-bit immediate —
  use `li` (which expands to `lui`/`addi`) instead of `addi rs, zero, big`;
- forgetting `li`/`la` need the **linker** — always link;
- reading the UART before a byte has arrived (poll `STATUS` bit 1);
- sending several bytes before reading them back (the RX buffer is one
  byte — receive before sending the next);
- enabling interrupts without setting `mtvec`, `mie`, and `mstatus.MIE`;
- having the interrupt handler clobber registers the interrupted code was
  using.

---

## 7. Debugging tips

- **Watch the sentinel.** `deadbeef` at `0x4000` means a check failed.
  Search the log for the `CF -> fail` jump and inspect the instruction
  just before it.
- **Use `objdump`** to see what the assembler really produced:
  `riscv64-elf-objdump -d /tmp/myprog.elf`.
- **Use the waveform.** `wave.vcd` records every signal. Open it in
  GTKWave and zoom into the failing cycle.
- **Make it a self-check.** Every time you compute a value, immediately
  `bne` it against an expected constant and jump to `fail`. This pinpoints
  the first wrong result.
- **Single-step mentally with the log.** Each log line is one cycle, so you
  can follow the register values instruction by instruction.

---

## 7b. Debugging with GDB against the actual RTL

The Verilated simulation includes a **GDB remote-protocol server**, so you
can debug your program on the real CPU model with `riscv64-elf-gdb` —
breakpoints, single-step, continue, and full register/memory access.

### Start the server

In one terminal:

```sh
make gdb              # builds the stub AND sw/soc_test.elf, runs on :3333
# or: GDB_PORT=5555 make gdb
```

The build writes the loadable ELF to `sw/soc_test.elf` (or use
`make soc-elf` for it alone, `make elf` for `sw/test.elf`).

To debug the **bare** configuration instead (core + memory only, no
peripherals), use `make gdb-bare`, then load `sw/bare_test.elf`:

```sh
make gdb-bare        # builds the bare stub AND sw/bare_test.elf, runs on :3333
```

```sh
riscv64-elf-gdb sw/bare_test.elf
(gdb) target remote :3333
(gdb) load
```

In another terminal:

```sh
riscv64-elf-gdb sw/soc_test.elf
(gdb) target remote :3333
(gdb) load            # write the program into the simulated memory
(gdb) info registers  # see x0..x31 and pc
(gdb) break *0x100    # or: break main / break handler
(gdb) continue
(gdb) stepi           # single-step one instruction
(gdb) x/8wx 0x4000    # examine memory
(gdb) set $t0 = 42    # modify a register
(gdb) set {int}0x5000 = 0x1234   # modify memory
(gdb) quit            # detach; the simulator keeps running
```

What works:

- `load` of an ELF (text + data written to the simulated memory);
- hardware-style breakpoints (`break`), checked against the PC every
  cycle;
- `continue`, `stepi` / `nexti` (one clock cycle = one instruction in a
  single-cycle CPU), and Ctrl-C to interrupt a running program;
- reading and writing all 32 registers and `pc` (`info registers`,
  `set $reg`, `print $reg`);
- reading and writing memory (`x/`, `set {int}addr = ...`);
- detach and reconnect without restarting the simulation.

Limitations:

- the machine CSRs (`mstatus`, `mie`, `mtvec`, …) are not exposed to GDB;
- breakpoints stop the whole CPU (no per-core or thread support);
- the simulation runs at whatever speed the host can manage while polling
  GDB, so long `continue` runs are fast but not real-time.

The stub is implemented in `tb/gdb_main.cpp` with a small debug interface
in the RTL (`rv32i_core`, `register_file`, `csr_file`, `memory`, exposed by
`rtl/rv32i_gdb.v`). The bare-configuration server uses `tb/gdb_bare_main.cpp`
and the top module `rtl/rv32i_gdb_bare.v`.

---

## 8. Exercises

1. **Sum of squares.** Compute `1²+2²+…+10²` and store it to memory.
2. **Count set bits.** Write a routine that counts the number of 1 bits in
   a word, using shifts and `andi`.
3. **Reverse a word.** Reverse the byte order of a 32-bit value using
   shifts and `or` (and check it with a stored value).
4. **Fibonacci.** Store the first 12 Fibonacci numbers into an array in
   memory.
5. **Fizz-buzz over UART (SoC).** Loop 1..30; send "Fizz"/"Buzz"/
   "FizzBuzz" over the UART using the send routine from `soc_test.S`.
6. **Timer calibration (SoC).** Use the timer to measure how many cycles a
   loop takes: start the timer, run the loop, read `TIMER_COUNT`.
7. **Toggle the timer from the handler (SoC).** Have the interrupt handler
   flip a memory flag each time it runs and stop after an exact number of
   interrupts (extend `soc_test.S`).
8. **Implement `ecall`.** Currently treated as a no-op; add decode for it
   so it traps to `mtvec` with a `mcause` of 11, then write a handler that
   uses it as a "print" system call.

Hints and worked solutions for exercises 1 and 4 are in the appendix.

---

## Appendix A — Worked solution: sum of squares

```asm
# store 1^2+2^2+...+10^2 (== 385) at 0x5000
    .section .text
    .globl _start
_start:
    li    t0, 10            # N
    li    t1, 0             # total
    li    t2, 1             # i
1:
    mul   t3, t2, t2        # i*i   (note: needs RV32M!)
    add   t1, t1, t3
    addi  t2, t2, 1
    ble   t2, t0, 1b        # while i <= N
    li    t4, 0x5000
    sw    t1, 0(t4)
    li    t5, 0x600D600D
    li    t6, 0x4000
    sw    t5, 0(t6)
halt:
    j     halt
```

`mul` is part of the **M extension**, which this CPU does not implement.
Worked solutions therefore either avoid multiplication (add `i` to a
running square: `(i+1)² = i² + 2i + 1`) or use shifts, so:

```asm
# (i+1)^2 = i^2 + 2*i + 1, computed with adds and shifts
    li    t0, 10
    li    t1, 0             # total
    li    t2, 1             # i
    li    t3, 1             # i^2 (1^2)
loop:
    add   t1, t1, t3        # total += i^2
    beq   t2, t0, done      # last i?
    slli  t4, t2, 1         # 2*i
    addi  t3, t3, 1         # i^2 + 1
    add   t3, t3, t4        # i^2 + 2*i + 1 = (i+1)^2
    addi  t2, t2, 1
    j     loop
done:
    li    t4, 0x5000
    sw    t1, 0(t4)
    li    t5, 0x600D600D
    li    t6, 0x4000
    sw    t5, 0(t6)
halt:
    j     halt
```

Result: `0x5000` holds `0x00000181` (385).

---

## Appendix B — Worked solution: first 12 Fibonacci numbers

```asm
# store the first 12 Fibonacci numbers at 0x5000
    .section .text
    .globl _start
_start:
    li    t0, 0x5000        # array base
    li    t1, 0             # fib(0)
    li    t2, 1             # fib(1)
    li    t3, 10            # loop count (writes a[2]..a[11])
    sw    t1, 0(t0)         # a[0] = 0
    sw    t2, 4(t0)         # a[1] = 1
    addi  t0, t0, 8         # t0 -> a[2]
1:
    add   t5, t1, t2        # next = fib(n-2) + fib(n-1)
    sw    t5, 0(t0)
    mv    t1, t2
    mv    t2, t5
    addi  t0, t0, 4
    addi  t3, t3, -1
    bnez  t3, 1b
    li    t6, 0x600D600D
    li    t0, 0x4000
    sw    t6, 0(t0)
halt:
    j     halt
```

Check: `a[2]` (at `0x5008`) holds `1`, `a[3]` holds `2`, `a[4]` holds `3`,
and so on.