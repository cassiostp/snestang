// Primer25K: 21.4844, 85.9375

// set_multicycle_path: https://docs.xilinx.com/r/en-US/ug903-vivado-using-constraints/set_multicycle_path-Syntax

create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
// Scratch rebuild of the SA-1 hardware commit at the PLL it generates
// (ODIV 93/31, 15.5 ns, 3:1). The file this replaced told STA fclk was
// 11.636 ns and mclk was divide-by-4. CLKOUT2 is still PE 19/3 = 225 degrees.
create_clock -name fclk -period 15.5 -waveform {0 7.75} [get_nets {fclk}]
create_generated_clock -name mclk -source [get_nets {fclk}] -divide_by 3 [get_nets {mclk}]

create_clock -name hclk5 -period 2.694 -waveform {0 1.347} [get_nets {hclk5}]
create_generated_clock -name hclk -source [get_nets {hclk5}] -master_clock hclk5 -divide_by 5 [get_nets {hclk}]

// see start of sdram_snes.v for detailed timing of sdram
// SNES to sdram, 3*fclk
set_multicycle_path 3 -setup -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -hold -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
// Except vram?_req for refresh
set_multicycle_path 1 -setup -end -from [get_nets {vram?_req}] -to [get_clocks {fclk}]

// sdram to SNES
set_multicycle_path 3 -setup -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]
set_multicycle_path 2 -hold -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]

// Last constraint takes precedence: PPU to sdram is even longer at 6 fclk cycles
//set_multicycle_path 6 -setup -end -from [get_nets {main/SNES/PPU/BG*}] -to [get_clocks {fclk}]
//set_multicycle_path 5 -hold -end -from [get_nets {main/SNES/PPU/BG*}] -to [get_clocks {fclk}]

// Same pin delays as fix/snes-sdram-io, at this commit's 225 degree clock.
// W9825G6KH-6 CL2: tAC 6.0, tOH 3.0, tCMS/tDS 1.5, tCMH/tDH 0.8.
// Board skew assumed 0.5 ns. No read multicycle: the next fclk is the sample.
create_generated_clock -name sdram_clk -source [get_nets {fclk}] -master_clock fclk -phase 225.000 -divide_by 1 [get_ports {O_sdram_clk}]
# Gowin TA1012: -max and -min are mutually exclusive, so each is its own line.
set_input_delay -clock sdram_clk -max 6.5 [get_ports {IO_sdram_dq*}]
set_input_delay -clock sdram_clk -min 2.5 [get_ports {IO_sdram_dq*}]
set_output_delay -clock sdram_clk -max 2.0 [get_ports {O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n O_sdram_cke}]
set_output_delay -clock sdram_clk -min -0.3 [get_ports {O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n O_sdram_cke}]
set_output_delay -clock sdram_clk -max 2.0 [get_ports {O_sdram_addr* O_sdram_ba* O_sdram_dqm*}]
set_output_delay -clock sdram_clk -min -0.3 [get_ports {O_sdram_addr* O_sdram_ba* O_sdram_dqm*}]
set_output_delay -clock sdram_clk -max 2.0 [get_ports {IO_sdram_dq*}]
set_output_delay -clock sdram_clk -min -0.3 [get_ports {IO_sdram_dq*}]

// false paths
//set_false_path -from [get_regs {main/SNES/smp/CPUO*}] -to [get_regs {sdram/dq_out*}]

