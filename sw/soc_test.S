# Self-checking SoC test program: CSR instructions, interrupts (timer),
# UART loopback.
#
# Address map used:
#   main memory   0x00000000
#   UART         0x10000000   (status/tx/rx/irqen)
#   timer        0x20000000   (ctrl/load/count/status)
#
# On success stores 0x600D600D at 0x4000, on failure 0xDEADBEEF.

    .section .text
    .globl _start
_start:
    # ------------------------------------------------------------------
    # Interrupt vector setup
    # ------------------------------------------------------------------
    la    t0, handler
    csrw  mtvec, t0

    # ------------------------------------------------------------------
    # CSR instruction round-trip tests
    # ------------------------------------------------------------------
    li    t1, 0xDEADBEEF
    csrrw t2, mscratch, t1        # t2 = 0 (old), mscratch = 0xDEADBEEF
    bne   t2, zero, fail
    csrrs t3, mscratch, zero      # t3 = 0xDEADBEEF, no write
    bne   t3, t1, fail
    csrrc t4, mscratch, t1        # t4 = 0xDEADBEEF, mscratch = 0
    bne   t4, t1, fail
    csrr  t5, mscratch            # t5 = 0
    bne   t5, zero, fail
    csrrwi t6, mscratch, 0xA      # mscratch = 0xA, t6 = 0
    bne   t6, zero, fail
    csrrsi s0, mscratch, 5        # mscratch = 0xF, s0 = 0xA
    li    t0, 0xA
    bne   s0, t0, fail
    csrr  t0, mscratch
    li    t1, 0xF
    bne   t0, t1, fail
    csrrci s1, mscratch, 0x3      # mscratch = 0xC, s1 = 0xF
    li    t0, 0xF
    bne   s1, t0, fail
    csrr  t0, mscratch
    li    t1, 0xC
    bne   t0, t1, fail

    # ------------------------------------------------------------------
    # Timer: count down, request 3 interrupts
    # ------------------------------------------------------------------
    li    t0, 0x20000000
    li    t1, 200
    sw    t1, 4(t0)               # TIMER_LOAD = 200
    li    t1, 3
    sw    t1, 0(t0)               # TIMER_CTRL = enable | irq_en
    li    t0, 1
    csrw  mie, t0                 # enable timer interrupt
    li    t0, 8
    csrw  mstatus, t0             # enable interrupts globally (MIE)

    li    s2, 0
    li    s3, 3                   # want 3 interrupts
    # The handler uses only t-registers, so s2 (counter) survives
    # interrupts; reload t0 every iteration because the handler clobbers it.
l_wait_irq:
    la    t0, irq_counter
    lw    s2, 0(t0)
    blt   s2, s3, l_wait_irq      # loop until 3 timer interrupts
    li    t0, 3
    bne   s2, t0, fail            # exactly 3 handled

    # ------------------------------------------------------------------
    # UART loopback: send a byte, receive it back (one at a time --
    # the RX buffer holds a single byte), verify it.
    # ------------------------------------------------------------------
    li    a0, 0x10000000
    li    t0, 0x48               # 'H'
    jal   ra, uart_send
    jal   ra, uart_recv          # returns byte in a0 (clobbers base)
    li    t1, 0x48
    bne   a0, t1, fail
    li    a0, 0x10000000
    li    t0, 0x69               # 'i'
    jal   ra, uart_send
    jal   ra, uart_recv
    li    t1, 0x69
    bne   a0, t1, fail
    li    a0, 0x10000000
    li    t0, 0x21               # '!'
    jal   ra, uart_send
    jal   ra, uart_recv
    li    t1, 0x21
    bne   a0, t1, fail

    j     pass

    # ------------------------------------------------------------------
    # UART subroutines (a0 = uart base, t0 = byte)
    # ------------------------------------------------------------------
uart_send:
    sw    t0, 4(a0)               # write TX_DATA
1:
    lw    t1, 0(a0)               # STATUS
    andi  t1, t1, 1               # TX_READY
    beqz  t1, 1b
    ret

uart_recv:
1:
    lw    t1, 0(a0)               # STATUS
    andi  t1, t1, 2               # RX_AVAIL
    beqz  t1, 1b
    lw    a0, 8(a0)               # RX_DATA (clears RX_AVAIL)
    ret

    # ------------------------------------------------------------------
    # Interrupt handler: count timer interrupts, stop after the 3rd
    # ------------------------------------------------------------------
handler:
    la    t0, irq_counter
    lw    t1, 0(t0)
    addi  t1, t1, 1
    sw    t1, 0(t0)
    li    t0, 0x20000000
    lw    t2, 12(t0)              # read TIMER_STATUS -> clears pending
    li    t3, 3
    bne   t1, t3, 1f
    sw    zero, 0(t0)             # disable timer
    csrw  mie, zero               # and all interrupts
1:
    mret

    # ------------------------------------------------------------------
    # Result
    # ------------------------------------------------------------------
pass:
    li    t0, 0x600D600D
    li    t1, 0x4000
    sw    t0, 0(t1)
    j     .
fail:
    li    t0, 0xDEADBEEF
    li    t1, 0x4000
    sw    t0, 0(t1)
    j     .

    .section .data
    .align 2
irq_counter:
    .word 0
