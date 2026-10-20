`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg resetn=0,loading=0,header_finished=0,strb=0;
reg [22:0] a=0;reg [7:0] d=0;
wire [23:0] mask;
gsu_ram_mask_from_rom dut(clk,resetn,loading,header_finished,a,d,strb,mask);
reg [23:0] ca=0;wire [19:0] mapped;
GSUMap cart(.MCLK(clk),.RST_N(resetn),.ENABLE(1'b1),.CA(ca),.DI(8'b0),.CPURD_N(1'b1),.CPUWR_N(1'b1),.PA(8'b0),.PARD_N(1'b1),.PAWR_N(1'b1),.ROMSEL_N(1'b1),.RAMSEL_N(1'b1),.SYSCLKF_CE(1'b0),.SYSCLKR_CE(1'b0),.REFRESH(1'b0),.ROM_Q(16'b0),.ROM_WAIT(1'b0),.RAM_WAIT(1'b0),.BSRAM_Q(8'b0),.MAP_CTRL(8'h70),.ROM_MASK(24'hffffff),.BSRAM_MASK(mask),.TURBO(1'b0),.BSRAM_ADDR(mapped));
task send(input [22:0] addr,input [7:0] value);
 begin @(negedge clk);a=addr;d=value;strb=1;@(negedge clk);strb=0;end
endtask
task cart_header(input [3:0] expansion,input [3:0] save,input [7:0] company,input [23:0] expected);
 begin
  @(negedge clk);loading=1;header_finished=0;
  repeat(4)@(negedge clk);header_finished=1;
  send(23'h007fbd,{4'h0,expansion});send(23'h007fd8,{4'h0,save});send(23'h007fda,company);
  if(mask!==expected)$fatal(1,"mask exp=%d save=%d company=%h got=%h expected=%h",expansion,save,company,mask,expected);
  loading=0;header_finished=0;repeat(3)@(negedge clk);
  if(mask!==expected)$fatal(1,"mask lost after load");
  ca=24'h71abcd;#1;
  if(mapped!== (20'h1abcd & expected[19:0]))$fatal(1,"GSU address did not mirror");
 end
endtask
initial begin
 repeat(3)@(negedge clk);resetn=1;
 cart_header(4'hf,0,8'h01,24'h007fff); // legacy Star Fox: ignore non-extended bytes
 cart_header(5,0,8'h33,24'h007fff); // Yoshi expansion RAM
 cart_header(6,0,8'h33,24'h00ffff); // 64 KiB expansion carts
 cart_header(0,6,8'h33,24'h00ffff); // RAM specified by the ordinary size byte
 cart_header(5,6,8'h33,24'h00ffff); // retain the larger physical RAM requirement
 cart_header(7,0,8'h33,24'h01ffff); // upper-bank SDRAM fallback remains addressable
 cart_header(0,0,8'h33,24'h007fff); // missing expansion size falls back to legacy size
 $display("PASS: seven GSU header/mapping cases, 32/64/128 KiB and reload retention");$finish;
end
endmodule

module GSU(input CLK,RST_N,ENABLE,input[23:0] ADDR,output[7:0] DO,input[7:0] DI,input RD_N,WR_N,SYSCLKF_CE,SYSCLKR_CE,output IRQ_N,output[20:0]ROM_A,input[7:0]ROM_DI,output ROM_REQ,input ROM_WAIT,output ROM_RD_N,output[16:0]RAM_A,input[7:0]RAM_DI,output[7:0]RAM_DO,output RAM_WE_N,RAM_CE_N,RAM_REQ,input RAM_WAIT,TURBO);
assign RAM_A=ADDR[16:0];
endmodule
