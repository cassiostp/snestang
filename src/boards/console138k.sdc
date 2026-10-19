// console138k and mega138k: mclk 21.5054, fclk 64.5161 (snes PLL odiv 93/31, 3:1).
// The 4:1 boards (primer25k, console60k, nano20k, mega60k) keep src/snestang.sdc;
// Gowin reads only one SDC per project, so this is a full copy, not an addition.
//
// Launch and capture edges are the controller's pre-edge cycle[] (sdram_cl2_2ch.v),
// locked so cycle[4] is the fclk edge that sees clkref rise. clkref (DOT_CLK_CE) is
// high for one mclk out of every four, and the rotation is two mclk, so once locked
// the resync is a no-op. Rising edges of mclk and fclk are aligned (PLL phase 0).
//   cycle[0] fires on an mclk edge. It latches channel-0 requests and launches
//     port[0]. The next mclk is 3 fclk later: 46.5 ns.
//   cycle[1] fires 1 fclk after an mclk. It launches aram_dout and the channel-0
//     acks. The next mclk is 2 fclk later: 31.0 ns.
//   cycle[2] fires 2 fclk after an mclk. It latches the ARAM request. The worst
//     mclk launch of that request is 2 fclk earlier: 31.0 ns.
//   cycle[4] fires 1 fclk after an mclk. It launches cpu_port*, cpu2_dout,
//     cpu2_req_ack, bsram_dout_reg, rv_dout. The next mclk is 2 fclk later: 31.0 ns.
// sim/sdram_port samples the cycle bit one fclk before the latch (it reads the
// rotated value). Its "min age 2" is this 3-fclk request window, and its
// "min age 1" is this 2-fclk ARAM window.
// Last matching constraint wins.

// set_multicycle_path: https://docs.xilinx.com/r/en-US/ug903-vivado-using-constraints/set_multicycle_path-Syntax

create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name fclk -period 15.5 -waveform {0 7.75} [get_nets {fclk}]
create_generated_clock -name mclk -source [get_nets {fclk}] -divide_by 3 [get_nets {mclk}]

create_clock -name hclk5 -period 2.694 -waveform {0 1.347} [get_nets {hclk5}]
create_generated_clock -name hclk -source [get_nets {hclk5}] -master_clock hclk5 -divide_by 5 [get_nets {hclk}]

// SNES to sdram. Channel 0 is latched at cycle[0], 3 fclk after the worst mclk.
set_multicycle_path 3 -setup -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -hold -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
// Except vram?_req for refresh (no VRAM port on this controller; matches nothing)
set_multicycle_path 1 -setup -end -from [get_nets {vram?_req}] -to [get_clocks {fclk}]
// ARAM is latched at cycle[2], 2 fclk after the worst mclk. Must stay tighter
// than the channel-0 exception above or these nets inherit 46.5 ns.
set_multicycle_path 2 -setup -end -from [get_nets {aram_req}] -to [get_clocks {fclk}]
set_multicycle_path 1 -hold -end -from [get_nets {aram_req}] -to [get_clocks {fclk}]
set_multicycle_path 2 -setup -end -from [get_nets {aram_addr_sd*}] -to [get_clocks {fclk}]
set_multicycle_path 1 -hold -end -from [get_nets {aram_addr_sd*}] -to [get_clocks {fclk}]
set_multicycle_path 2 -setup -end -from [get_nets {aram_din_sd*}] -to [get_clocks {fclk}]
set_multicycle_path 1 -hold -end -from [get_nets {aram_din_sd*}] -to [get_clocks {fclk}]
set_multicycle_path 2 -setup -end -from [get_nets {aram_we_sd}] -to [get_clocks {fclk}]
set_multicycle_path 1 -hold -end -from [get_nets {aram_we_sd}] -to [get_clocks {fclk}]

// sdram to SNES. cycle[0] launches (port[0], the channel-0 latches) meet the
// next mclk 3 fclk later. This is the window of the port[0] -> CPU/SA-1 cone.
set_multicycle_path 3 -setup -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]
set_multicycle_path 2 -hold -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]

// cycle[1] and cycle[4] data and acks meet the next mclk 2 fclk later.
// Listed after the general exception so they override it.
set_multicycle_path 2 -setup -start -from [get_regs {sdram/aram_dout*}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_regs {sdram/aram_dout*}] -to [get_clocks {mclk}]
// cpu_port0/1: the first mclk after the capture (2 fclk) is never the
// S-CPU's functional sample. The P65C816 consumes A/B-bus read data
// only at SYSCLKF_CE, the last edge of the presenting 6/8/12-mclk bus
// cycle (cpu.v: P65C816 CE = INT_CLKF_CE; its registers update only
// under CE). sim/sdram_port/run_stable.sh measures the word's age at
// that sample: minimum 5 fclk (77.5 ns) over both rotation phases and
// all scenarios. Scope the wider budget to exactly those proven
// endpoints: cpu_port* keeps the 2-fclk window to everything else
// (including the every-mclk BUSA_DO_buf/BUSB_DO_buf pipeline registers
// in SNES.v, whose value at SYSCLKF_CE was captured one mclk earlier,
// 2 fclk after the SDRAM capture in the worst phase), and only the
// P65C816 register hierarchy gets 3 fclk (46.5 ns, inside the proven
// 77.5 ns). Listed after the 2-fclk lines so they take precedence
// for those endpoints.
set_multicycle_path 2 -setup -start -from [get_regs {sdram/cpu_port0*}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_regs {sdram/cpu_port0*}] -to [get_clocks {mclk}]
set_multicycle_path 2 -setup -start -from [get_regs {sdram/cpu_port1*}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_regs {sdram/cpu_port1*}] -to [get_clocks {mclk}]
set_multicycle_path 3 -setup -start -from [get_regs {sdram/cpu_port0*}] -to [get_regs {main/SNES/CPU/P65C816/* main/SNES/CPU/P65C816/AddrGen/*}]
set_multicycle_path 2 -hold -start -from [get_regs {sdram/cpu_port0*}] -to [get_regs {main/SNES/CPU/P65C816/* main/SNES/CPU/P65C816/AddrGen/*}]
set_multicycle_path 3 -setup -start -from [get_regs {sdram/cpu_port1*}] -to [get_regs {main/SNES/CPU/P65C816/* main/SNES/CPU/P65C816/AddrGen/*}]
set_multicycle_path 2 -hold -start -from [get_regs {sdram/cpu_port1*}] -to [get_regs {main/SNES/CPU/P65C816/* main/SNES/CPU/P65C816/AddrGen/*}]
set_multicycle_path 2 -setup -start -from [get_regs {sdram/cpu2_dout*}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_regs {sdram/cpu2_dout*}] -to [get_clocks {mclk}]
set_multicycle_path 2 -setup -start -from [get_regs {sdram/cpu2_req_ack*}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_regs {sdram/cpu2_req_ack*}] -to [get_clocks {mclk}]
set_multicycle_path 2 -setup -start -from [get_regs {sdram/bsram_dout_reg*}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_regs {sdram/bsram_dout_reg*}] -to [get_clocks {mclk}]
// The SA-1 is clocked only while sa1_mode is set (snestang_top.v .active),
// and in that mode BSRAM_Q is the BW-RAM, not bsram_dout. The cone from
// bsram_dout_reg into the SA-1 still fails a 31 ns check by a few tenths;
// the S-CPU cone from the same register meets 31 ns. Give the SA-1 side
// the following mclk (46.5 ns).
set_multicycle_path 3 -setup -start -from [get_regs {sdram/bsram_dout_reg*}] -to [get_regs {main/SA1Map/SA1/P65C816_SA1/AddrGen_SA1/PCr*}]
set_multicycle_path 2 -hold -start -from [get_regs {sdram/bsram_dout_reg*}] -to [get_regs {main/SA1Map/SA1/P65C816_SA1/AddrGen_SA1/PCr*}]
set_multicycle_path 2 -setup -start -from [get_regs {sdram/bsram_req_ack*}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_regs {sdram/bsram_req_ack*}] -to [get_clocks {mclk}]
// rv_dout / rv_req_ack are swept when the softcore is tied off (MCU_BL616).
// Gowin errors (TA2003) if get_regs matches nothing, so they are not listed.

// Last constraint takes precedence: PPU to sdram is even longer at 6 fclk cycles
//set_multicycle_path 6 -setup -end -from [get_nets {main/SNES/PPU/BG*}] -to [get_clocks {fclk}]
//set_multicycle_path 5 -hold -end -from [get_nets {main/SNES/PPU/BG*}] -to [get_clocks {fclk}]

// SDRAM pin timing. O_sdram_clk is PLL CLKOUT2 at PE 18/3:
// (18+3/8)/31*360 = 213.387 degrees = 9.1875 ns behind fclk. The controller
// launches CAS on fclk and samples dq_in 3 fclk (46.5 ns) later. The chip
// launches CL2 data on the sdram edge 2 cycles (31.0 ns) after it takes
// CAS, so the word is 6.3125 ns old at the sample. The phase is
// 0.25 ns later than the 17/7 it replaces: with the capture registers
// bound next to their pins (console138k_sdram.cst), the read window has
// >1 ns of margin to give, and the pin outputs gain it 1:1 (their
// slack is phase minus the fclk insertion to the IOB, which placement
// alone was leaving at +0.07 ns). The default setup check
// (the next fclk after that sdram edge) is that sample. Do not add a
// multicycle: it would time a later edge than the one the controller uses.
//
// W9825G6KH-6 at CL2: tAC max 6.0, tOH min 3.0, tCMS and tDS 1.5,
// tCMH and tDH 0.8. Board skew is taken as 0.5 ns each way. That number
// is an assumption, not a measurement of this board.
create_generated_clock -name sdram_clk -source [get_nets {fclk}] -master_clock fclk -phase 213.387 -divide_by 1 [get_ports {O_sdram_clk}]
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

// AUDIT ONLY (exp/sdramrob-audit): enumerate pin paths and SDRAM-lane
// endpoints beyond the default worst-25 report. No constraint change.
report_timing -setup -from [get_ports {IO_sdram_dq*}] -max_paths 100 -max_common_paths 20
report_timing -setup -to [get_ports {IO_sdram_dq* O_sdram_addr* O_sdram_ba* O_sdram_dqm* O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n O_sdram_cke}] -max_paths 100 -max_common_paths 20
report_timing -hold -from [get_ports {IO_sdram_dq*}] -max_paths 50 -max_common_paths 10
report_timing -hold -to [get_ports {IO_sdram_dq* O_sdram_addr* O_sdram_ba* O_sdram_dqm* O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n O_sdram_cke}] -max_paths 50 -max_common_paths 10
report_timing -setup -from [get_regs {sdram/cpu_port0* sdram/cpu_port1*}] -max_paths 200 -max_common_paths 50
report_timing -setup -from [get_regs {sdram/bsram_dout_reg*}] -max_paths 100 -max_common_paths 50
report_timing -setup -from [get_regs {sdram/dq_oen*}] -max_paths 50 -max_common_paths 20
report_timing -setup -from [get_regs {sdram/cpu_port0* sdram/cpu_port1*}] -to [get_regs {main/SNES/CPU/P65C816/* main/SNES/CPU/P65C816/AddrGen/*}] -max_paths 500 -max_common_paths 500
