# Single-cycle RV32I CPU - build and simulation
#
# Targets:
#   make            - build and run the bare configuration (core + memory)
#   make soc        - build and run the SoC configuration (core + system bus
#                     + UART + timer + interrupts)
#   make hex        - assemble sw/test.S into sw/test.hex
#   make soc-hex    - assemble sw/soc_test.S into sw/soc_test.hex
#   make elf        - assemble+link sw/test.elf (for gdb)
#   make soc-elf    - assemble+link sw/soc_test.elf (for gdb)
#   make gdb        - build and run the GDB debug server on port 3333
#   make address-map - report the address space used by each configuration
#   make clean      - remove build artifacts

AS        = riscv64-elf-as
LD        = riscv64-elf-ld
OBJCOPY   = riscv64-elf-objcopy
VERILATOR = verilator

RTL = rtl/alu.v rtl/register_file.v rtl/imm_gen.v rtl/control.v \
      rtl/memory.v rtl/csr_file.v rtl/rv32i_core.v rtl/rv32i_bare.v \
      rtl/system_bus.v rtl/uart.v rtl/timer.v rtl/interrupt_controller.v \
      rtl/rv32i_soc.v

.PHONY: all bare soc hex soc-hex elf soc-elf address-map gdb clean

all: hex soc-hex bare soc

bare: hex
	$(VERILATOR) --binary --timing --trace -j 2 +incdir+tb \
		--top-module tb_rv32i -o sim_rv32i \
		$(RTL) tb/tb_rv32i.v
	./obj_dir/sim_rv32i

soc: soc-hex
	$(VERILATOR) --binary --timing --trace -j 2 +incdir+tb \
		--top-module tb_soc -o sim_soc \
		$(RTL) tb/tb_soc.v
	./obj_dir/sim_soc

# Build the GDB debug server and start it on port 3333 (or $$GDB_PORT).
# The ELF (sw/soc_test.elf) is built first so it can be loaded in gdb:
#   riscv64-elf-gdb sw/soc_test.elf   ->   target remote :3333
gdb: sw/soc_test.elf
	$(VERILATOR) --cc --build --exe -j 2 +incdir+tb \
		--top-module rv32i_gdb -o rv32i_gdb --Mdir obj_gdb \
		$(RTL) rtl/rv32i_gdb.v tb/gdb_main.cpp
	./obj_gdb/rv32i_gdb $${GDB_PORT:-3333}

# Assemble + link (the linker resolves PC-relative la/auipc relocations).
# The ELF is kept in sw/ so it can be loaded with gdb; the hex image is
# what the Verilog testbenches load via $readmemh.
sw/test.elf sw/test.hex: sw/test.S sw/link.ld
	$(AS) -march=rv32i_zicsr -mabi=ilp32 sw/test.S -o /tmp/riscv_test.o
	$(LD) -m elf32lriscv -T sw/link.ld /tmp/riscv_test.o -o sw/test.elf
	$(OBJCOPY) -O binary sw/test.elf sw/test.bin
	xxd -p -c 1 sw/test.bin > sw/test.hex

sw/soc_test.elf sw/soc_test.hex: sw/soc_test.S sw/link.ld
	$(AS) -march=rv32i_zicsr -mabi=ilp32 sw/soc_test.S -o /tmp/riscv_soc_test.o
	$(LD) -m elf32lriscv -T sw/link.ld /tmp/riscv_soc_test.o -o sw/soc_test.elf
	$(OBJCOPY) -O binary sw/soc_test.elf sw/soc_test.bin
	xxd -p -c 1 sw/soc_test.bin > sw/soc_test.hex

hex: sw/test.hex
soc-hex: sw/soc_test.hex
elf: sw/test.elf
soc-elf: sw/soc_test.elf

address-map:
	@echo "============================================================"
	@echo " Address space used"
	@echo "============================================================"
	@echo " Bare configuration (rv32i_bare):"
	@echo "   0x00000000 - 0x0000FFFF   main memory (unified, 64 KiB)"
	@echo ""
	@echo " SoC configuration (rv32i_soc):"
	@echo "   0x00000000 - 0x0FFFFFFF   main memory (unified; 64 KiB implemented)"
	@echo "   0x10000000 - 0x1FFFFFFF   UART   (0x00 status, 0x04 tx, 0x08 rx, 0x0C irq_en)"
	@echo "   0x20000000 - 0x2FFFFFFF   timer  (0x00 ctrl, 0x04 load, 0x08 count, 0x0C status)"
	@echo "   0x30000000 - 0xFFFFFFFF   unmapped (reads 0, writes dropped)"
	@echo "   interrupts: irq[0]=timer, irq[1]=uart_rx, irq[2]=uart_tx"

clean:
	rm -rf obj_dir obj_gdb wave.vcd wave_soc.vcd sim.log sim_soc.log sw/*.hex sw/*.bin sw/*.elf
