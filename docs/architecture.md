# RV32I CPU — Address Space & Connections

Two build configurations share the same single-cycle core (`rv32i_core`):

| Configuration | Top module    | Peripherals | Build    |
|---------------|---------------|-------------|----------|
| Bare          | `rv32i_bare`  | none        | `make`   |
| SoC           | `rv32i_soc`   | UART, timer, interrupts | `make soc` |

---

## 1. Address space

The CPU issues 32-bit byte addresses (4 GiB space). Address bits `[31:28]`
select the slave on the system bus.

```
0xFFFFFFFF ┌────────────────────┐        0xFFFFFFFF ┌────────────────────┐
           │                    │                   │                    │
           │   UNMAPPED         │                   │    UNMAPPED        │
           │   reads -> 0       │                   │   addr[31:28]=4..F │
           │   writes dropped   │                   │   reads -> 0       │
           │                    │                   │   writes dropped   │
0x00010000 ├────────────────────┤                   │                    │
           │   UNIFIED MEMORY   │        0x30000000 ├────────────────────┤
           │   64 KiB           │                   │    TIMER           │
           │   instr + data     │                   │   addr[31:28]=2    │
           │                    │        0x20000000 ├────────────────────┤
0x00000000 └────────────────────┘                   │    UART            │
                                                    │   addr[31:28]=1    │
                                         0x10000000 ├────────────────────┤
                                                    │    UNIFIED MEMORY  │
                                                    │   addr[31:28]=0    │
                                                    │   (64 KiB RAM)     │
                                                    │                    │
                                         0x00000000 └────────────────────┘
```

### Register maps

```
UART  @ 0x10000000                    TIMER  @ 0x20000000
  +0x00 STATUS (RO)                    +0x00 CTRL   (RW)
         bit 0 = TX_READY                     bit 0 = enable
         bit 1 = RX_AVAIL                     bit 1 = interrupt enable
  +0x04 TX_DATA (WO)                   +0x04 LOAD   (RW)   reload value
         write a byte to transmit            (also loads COUNT, clears pending)
  +0x08 RX_DATA (RO)                   +0x08 COUNT  (RO)   current countdown
         received byte; read                (decrements every cycle when enabled)
         clears RX_AVAIL               +0x0C STATUS (RO)
  +0x0C IRQ_EN  (RW)                         bit 0 = pending; read clears
         bit 0 = RX interrupt enable
         bit 1 = TX interrupt enable

CSR  (machine mode, accessed with csrrw/csrrs/csrrc/csrrwi/csrrsi/csrrci)
  0x300 mstatus   MIE = bit 3 (global enable), MPIE = bit 7
  0x304 mie       per-line interrupt mask  (bits 3:0 = irq[3:0])
  0x305 mtvec     trap vector base
  0x340 mscratch
  0x341 mepc      trap return address
  0x342 mcause    trap cause (interrupt = 0x80000000 | irq index)
  0x344 mip       read-only pending interrupts
```

### Interrupt vector

```
  irq[0] = timer expired
  irq[1] = UART RX data available
  irq[2] = UART TX complete
```

An interrupt is taken when `irq & mie & mstatus.MIE != 0`. The core then
jumps to `mtvec`, saves `mepc = next PC`, `mcause = 0x80000000 | index`, and
clears `MIE`. `mret` restores `MIE` from `MPIE` and returns to `mepc`.

---

## 2. Connections

### Instruction fetch (core ↔ memory)

```
  ┌───────────────┐                     ┌──────────────────┐
  │               │                     │                  │
  │   rv32i_core  │                     │  unified_memory  │
  │               │                     │                  │
  │  inst_addr ───┼────────────────────►│  inst port       │
  │  inst ◄───────┼─────────────────────│                  │
  │               │                     │                  │
  └───────────────┘                     └──────────────────┘
```

### Data access (core → bus → memory/UART/timer)

```
  ┌───────────────┐                     ┌────────────────────────────────────┐
  │               │                     │                                    │
  │   rv32i_core  │                     │             system_bus             │
  │               │                     │                                    │
  │  data_addr ───┼────────────────────►│  master ◄── core data              │
  │  data_wdata ──┼────────────────────►│  addr[31:28]=0 ──► memory          │
  │  data_wen ────┼────────────────────►│  addr[31:28]=1 ──► uart            │
  │  data_read ───┼────────────────────►│  addr[31:28]=2 ──► timer           │
  │  data_rdata ◄─┼─────────────────────│                                    │
  │               │                     │                                    │
  └───────────────┘                     └────────────────────────────────────┘
```

The SoC testbench loops the UART (`tx` wired to `rx`) so the CPU can
transmit bytes and receive them back.

### Interrupt path (peripherals → core)

```
   timer.irq_out ────┐                              
   uart.irq_rx  ─────┼─────►┌──────────────────────┐
   uart.irq_tx  ─────┘      │                      │
                            │  interrupt_controller│
                            │  irq[3:0] = {0,      │
                            │   uart_rx, uart_tx,  │
                            │   timer}             │
                            └──────────┬───────────┘
                                       │            
                                       ▼            
                            ┌──────────────────────┐
                            │       core.irq       │
                            └──────────────────────┘
```

---

## 3. Port connection table

```
┌─────────────────────────────┬──────────────────────────────┐
│ Source                      │ Destination                  │
├─────────────────────────────┼──────────────────────────────┤
│ core.inst_addr (PC)         │ memory.inst_addr             │
│ memory.inst                 │ core.inst                    │
│                             │                              │
│ core.data_addr              │ bus.m_addr                   │
│ core.data_wdata             │ bus.m_wdata                  │
│ core.data_wen               │ bus.m_wen                    │
│ core.data_read              │ bus.m_rd                     │
│ bus.m_rdata                 │ core.data_rdata              │
│                             │                              │
│ bus.mem_addr/wdata/wen      │ memory.data_addr/wdata/wen   │
│ memory.data_rdata           │ bus.mem_rdata                │
│ bus.uart_addr/wdata/wen/rd  │ uart.bus_addr/wdata/wen/rd   │
│ uart.bus_rdata              │ bus.uart_rdata               │
│ bus.timer_addr/wdata/wen/rd │ timer.bus_addr/wdata/wen/rd  │
│ timer.bus_rdata             │ bus.timer_rdata              │
│                             │                              │
│ uart.tx                     │ SoC uart_tx output           │
│ SoC uart_rx input           │ uart.rx  (loopback in tb_soc)│
│ uart.irq_rx / irq_tx        │ interrupt_controller         │
│ timer.irq_out               │ interrupt_controller         │
│ interrupt_controller.irq    │ core.irq                     │
└─────────────────────────────┴──────────────────────────────┘
```

There is also a **debug port** (used by the GDB server, not by programs):
`dbg_hold`, `dbg_pc_we/wval`, `dbg_reg_ridx/rval/we/widx/wval`,
`dbg_csr_idx/val`, and `dbg_peek_addr/data` + `dbg_mem_waddr/wdata/wen`.
It lets the host halt the CPU, read/write any register or memory byte and
override the PC. See `cpu-design.md` §8 and `programming.md` §7b.

## 4. Flow through one cycle

1. **Fetch** — the core presents `pc` on `inst_addr`; `unified_memory`
   returns the instruction combinationally.
2. **Execute** — the datapath decodes, reads registers, computes the ALU
   result and (for loads/stores) the data address.
3. **Access** — the data address goes to `system_bus`, which decodes
   `addr[31:28]` and returns the selected slave's read data (or gates the
   write enables). Peripheral registers accept writes on the clock edge.
4. **Interrupt (SoC)** — if `irq & mie & mstatus.MIE`, the core jumps to
   `mtvec` instead of the next instruction, saving `mepc`/`mcause`.
5. **Writeback** — register-file and memory writes commit on the clock edge;
   the PC advances, and the next cycle begins.
