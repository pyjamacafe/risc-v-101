# Bare-configuration GDB test program (RV32I, no CSRs/peripherals).
#
# Computes 1+2+...+10 and stores the result at 0x5000, writes the pass
# sentinel 0x600D600D at 0x4000, then halts. Kept deliberately small and
# control-flow rich so it is pleasant to single-step with GDB.

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
    j     halt
