# Self-checking RV32I test program.
#
# Exercises every RV32I instruction class: R/I/U/S/B/J formats, all ALU
# operations, all load/store sizes, branches, JAL/JALR.
#
# On success it stores 0x600D600D at address 0x4000.
# On failure  it stores 0xDEADBEEF at address 0x4000 and the failing PC at
#              0x4004, then halts in an infinite loop.

    .section .text
    .globl _start
_start:
    # ------------------------------------------------------------------
    # Computation section
    # ------------------------------------------------------------------
    addi  t0, x0, 10            # t0 = 10
    addi  t1, x0, 4             # t1 = 4
    add   t2, t0, t1            # t2 = 14
    sub   t3, t0, t1            # t3 = 6
    and   t4, t0, t1            # t4 = 0
    or    t5, t0, t1            # t5 = 14
    xor   t6, t0, t1            # t6 = 14
    slt   s1, t1, t0            # s1 = 1  (unchecked)
    sltu  s2, t1, t0            # s2 = 1
    sll   a0, t0, t1            # a0 = 10 << 4  = 160
    srl   a1, a0, t1            # a1 = 160 >> 4 = 10
    addi  a3, x0, -16           # a3 = -16
    srai  a4, a3, 2             # a4 = -16 >> 2 (arith) = -4
    srli  a5, a3, 2             # a5 = -16 >> 2 (logic) = 0x3FFFFFFC
    slli  s3, t0, 2             # s3 = 40
    srli  s4, s3, 1             # s4 = 20

    addi  s0, x0, 100           # s0 = 100
    slti  a7, s0, 200           # a7 = 1
    xori  s5, s0, -1            # s5 = ~100 = -101
    ori   s6, s0, 15            # s6 = 111
    andi  s7, s0, 15            # s7 = 4
    lui   s0, 0x12345           # s0 = 0x12345000
    auipc s1, 0x0               # s1 = PC (unchecked)

    # ------------------------------------------------------------------
    # Arithmetic checks
    # ------------------------------------------------------------------
    li    t0, 14
    bne   t2, t0, fail          # add
    li    t0, 6
    bne   t3, t0, fail          # sub
    li    t0, 0
    bne   t4, t0, fail          # and
    li    t0, 14
    bne   t5, t0, fail          # or
    li    t0, 14
    bne   t6, t0, fail          # xor
    li    t0, 160
    bne   a0, t0, fail          # sll
    li    t0, 10
    bne   a1, t0, fail          # srl
    li    t0, -4
    bne   a4, t0, fail          # srai
    li    t0, 0x3FFFFFFC
    bne   a5, t0, fail          # srli
    li    t0, 40
    bne   s3, t0, fail          # slli
    li    t0, 20
    bne   s4, t0, fail          # srli
    li    t0, 1
    bne   a7, t0, fail          # slti
    li    t0, -101
    bne   s5, t0, fail          # xori
    li    t0, 111
    bne   s6, t0, fail          # ori
    li    t0, 4
    bne   s7, t0, fail          # andi
    li    t0, 0x12345000
    bne   s0, t0, fail          # lui

    # ------------------------------------------------------------------
    # Memory section (data region at 0x3000, clear of the code)
    # ------------------------------------------------------------------
    lui   a6, 0x3               # a6 = 0x3000
    sw    t2, 0(a6)             # mem[0x3000] = 14
    lw    s2, 0(a6)             # s2 = 14
    addi  t5, x0, -2            # t5 = -2 (0xFFFE)
    sh    t5, 4(a6)             # mem[0x3004] = 0xFFFE
    lh    s3, 4(a6)             # s3 = -2 (sign extended)
    lhu   s3, 4(a6)             # s3 = 0xFFFE = 65534
    sb    t1, 6(a6)             # mem[0x3006] = 4
    lb    s4, 6(a6)             # s4 = 4
    lbu   s5, 6(a6)             # s5 = 4
    sb    t5, 8(a6)             # mem[0x3008] = 0xFE
    lb    s6, 8(a6)             # s6 = 0xFFFFFFFE = -2 (sign extended)
    lbu   s7, 8(a6)             # s7 = 254

    # Memory checks
    li    t0, 14
    bne   s2, t0, fail          # lw
    li    t0, 65534             # 0xFFFE
    bne   s3, t0, fail          # lhu
    li    t0, 4
    bne   s4, t0, fail          # lb
    li    t0, 4
    bne   s5, t0, fail          # lbu
    li    t0, -2
    bne   s6, t0, fail          # lb sign extension
    li    t0, 254
    bne   s7, t0, fail          # lbu zero extension

    # Adjacent byte stores at distinct addresses (catches unaligned base
    # misalignment between the byte-enable logic and the memory).
    li    t5, -1
    sb    t5, 10(a6)            # mem[0x300A] = 0xFF
    li    t5, 0x12
    sb    t5, 11(a6)            # mem[0x300B] = 0x12
    lbu   t0, 10(a6)
    li    t3, 255
    bne   t0, t3, fail          # mem[0x300A] must be 0xFF
    lbu   t0, 11(a6)
    li    t3, 0x12
    bne   t0, t3, fail          # mem[0x300B] must be 0x12

    # Halfword store/load at an odd halfword address (addr[1] = 1).
    addi  t5, x0, -256          # 0xFFFFFF00
    sh    t5, 14(a6)            # mem[0x300E..F] = 0xFF00
    lh    t0, 14(a6)
    li    t3, -256
    bne   t0, t3, fail          # lh sign extension (odd halfword)
    lhu   t0, 14(a6)
    li    t3, 65280             # 0xFF00
    bne   t0, t3, fail          # lhu zero extension (odd halfword)

    # ------------------------------------------------------------------
    # Branch tests
    # ------------------------------------------------------------------
    beq   x0, x0, l_beq_taken   # taken
    j     fail                  # skipped if BEQ works
l_beq_taken:
    bne   x0, x0, l_beq_nt      # not taken
    j     l_beq_nt2
l_beq_nt:
    j     fail
l_beq_nt2:

    li    t2, 5
    li    t3, 3
    bltu  t3, t2, l_bltu        # 3 < 5 (unsigned)
    j     fail
l_bltu:
    bgeu  t2, t3, l_bgeu        # 5 >= 3 (unsigned)
    j     fail
l_bgeu:
    blt   t3, t2, l_blt         # 3 < 5 (signed)
    j     fail
l_blt:
    bge   t2, t3, l_bge         # 5 >= 3 (signed)
    j     fail
l_bge:
    bltu  t2, t2, fail          # 5 < 5 false -> fall through
    bgeu  t3, t3, l_bgeu2       # 3 >= 3 true
    j     fail
l_bgeu2:
    blt   t2, t3, fail          # 5 < 3 false -> fall through
    bge   t3, t2, fail          # 3 >= 5 false -> fall through

    # ------------------------------------------------------------------
    # Counter loop (BLT)
    # ------------------------------------------------------------------
    li    t0, 0
l_loop:
    addi  t0, t0, 1
    blt   t0, t1, l_loop        # repeat while t0 < 4  (t1 == 4)
    li    t1, 4
    bne   t0, t1, fail          # t0 must be 4

    # ------------------------------------------------------------------
    # JAL / JALR
    # ------------------------------------------------------------------
    jal   ra, l_subr
l_after_call:
    li    t0, 0x1FC             # address of l_after_call
    bne   ra, t0, fail          # JAL must link ra = pc+4
    j     l_done
l_subr:
    addi  t1, t1, 1             # t1 = 5
    jalr  x0, ra, 0             # return via JALR
l_done:
    li    t0, 5
    bne   t1, t0, fail          # t1 must be 5

    # ------------------------------------------------------------------
    # Success
    # ------------------------------------------------------------------
    li    s10, 0x600D600D
    j     l_record
fail:
    li    s10, 0xDEADBEEF
    auipc t0, 0x0               # approximate failing PC
    lui   s11, 0x4
    addi  s11, s11, 4
    sw    t0, 0(s11)            # store at 0x4004
l_record:
    lui   s11, 0x4              # s11 = 0x4000
    sw    s10, 0(s11)           # store status
l_halt:
    j     l_halt                # infinite loop
