# Single-cycle RV32I CPU - build and simulation
#
# Targets:
#   make            - assemble test program and run Verilator simulation
#   make hex        - assemble sw/test.S into sw/test.hex (memory image)
#   make sim        - compile and run the Verilator simulation
#   make clean      - remove build artifacts

AS       = riscv64-elf-as
OBJCOPY  = riscv64-elf-objcopy
VERILATOR = verilator

RTL = rtl/alu.v rtl/register_file.v rtl/imm_gen.v \
      rtl/control.v rtl/memory.v rtl/rv32i_core.v
TB  = tb/tb_rv32i.v

.PHONY: all hex sim clean

all: sim

hex: sw/test.hex

sw/test.hex: sw/test.S
	$(AS) -march=rv32i -mabi=ilp32 $< -o /tmp/riscv_test.o
	$(OBJCOPY) -O binary /tmp/riscv_test.o sw/test.bin
	xxd -p -c 1 sw/test.bin > $@

sim: hex
	$(VERILATOR) --binary --timing --trace -j 2 \
		--top-module tb_rv32i -o sim_rv32i \
		$(RTL) $(TB)
	./obj_dir/sim_rv32i

clean:
	rm -rf obj_dir wave.vcd