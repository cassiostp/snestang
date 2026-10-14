// console138k: mclk 21.5054, fclk 64.5161 (snes PLL odiv 93/31, 3:1).
// Primer25K was 21.4844, 85.9375 (4:1); this file describes the console138k
// clocks (one SDC per project, shared with the primer/console60k builds).

// set_multicycle_path: https://docs.xilinx.com/r/en-US/ug903-vivado-using-constraints/set_multicycle_path-Syntax

create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name fclk -period 15.5 -waveform {0 7.75} [get_nets {fclk}]
create_generated_clock -name mclk -source [get_nets {fclk}] -divide_by 3 [get_nets {mclk}]

create_clock -name hclk5 -period 2.694 -waveform {0 1.347} [get_nets {hclk5}]
create_generated_clock -name hclk -source [get_nets {hclk5}] -master_clock hclk5 -divide_by 5 [get_nets {hclk}]

// see start of sdram_cl2_2ch.v for detailed timing of sdram
// SNES to sdram, 3*fclk
set_multicycle_path 3 -setup -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -hold -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
// Except vram?_req for refresh
set_multicycle_path 1 -setup -end -from [get_nets {vram?_req}] -to [get_clocks {fclk}]

// sdram to SNES, 3*fclk
set_multicycle_path 3 -setup -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]
set_multicycle_path 2 -hold -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]

// Last constraint takes precedence: PPU to sdram is even longer at 6 fclk cycles
//set_multicycle_path 6 -setup -end -from [get_nets {main/SNES/PPU/BG*}] -to [get_clocks {fclk}]
//set_multicycle_path 5 -hold -end -from [get_nets {main/SNES/PPU/BG*}] -to [get_clocks {fclk}]

// false paths
//set_false_path -from [get_regs {main/SNES/smp/CPUO*}] -to [get_regs {sdram/dq_out*}]

