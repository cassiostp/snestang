`timescale 1ns/1ps
module tb_capture_restore;
reg clk=0, mclk=0;
always #5 clk=~clk;
always #15 mclk=~mclk;
reg resetn=0, block=0;
reg [1:0] phase=0;
always @(posedge mclk) phase<=phase+1'b1;
wire clkref=phase==0;
reg cpu_req=0, cpu_port=0, bs_req=0, ar_req=0;
reg [12:0] ra=0;
reg [7:0] rd=0;
reg rw=0;
reg [15:0] pattern=16'h2468;
always @(negedge clk) pattern<=pattern+16'h1357;
wire [15:0] dq, dq_ref;
assign dq=pattern;
assign dq_ref=pattern;
wire [15:0] raw0,raw1,rawa,q0,q1,qa,r0,r1,ar;
wire [7:0] rawb,qb,br,reg_q,reg_ref;
wire ca,ba,aa,ca_ref,ba_ref,aa_ref;
wire busy,busy_ref;

sdram_snes dut(
 .clk(clk),.mclk(mclk),.clkref(clkref),.resetn(resetn),.busy(busy),
 .SDRAM_DQ(dq),.SDRAM_A(),.SDRAM_DQM(),.SDRAM_BA(),
 .SDRAM_nCS(),.SDRAM_nWE(),.SDRAM_nRAS(),.SDRAM_nCAS(),.SDRAM_CKE(),
 .cpu_addr(22'b0),.cpu_din(16'b0),.cpu_port(cpu_port),.cpu_req(cpu_req),
 .cpu_we(1'b0),.cpu_ds(2'b11),.cpu_req_ack(ca),.cpu_port0(raw0),.cpu_port1(raw1),
 .cpu2_addr(22'b0),.cpu2_req(1'b0),.cpu2_dout(),.cpu2_req_ack(),
 .bsram_addr(20'b0),.bsram_din(8'b0),.bsram_req(bs_req),.bsram_we(1'b0),
 .bsram_dout(rawb),.bsram_req_ack(ba),
 .aram_addr(16'b0),.aram_din(16'b0),.aram_req(ar_req),.aram_we(1'b0),
 .aram_16(1'b1),.aram_dout(rawa),.aram_req_ack(aa),
 .rv_addr(22'b0),.rv_din(16'b0),.rv_req(1'b0),.rv_we(1'b0),.rv_ds(2'b0),.rv_dout(),.rv_req_ack(),
 .total_refresh(),.ss_addr(25'b0),.ss_din(8'b0),.ss_req(1'b0),.ss_we(1'b0),.ss_ack(),.ss_q(),
 .ss_block(block),.ss_reg_a(ra),.ss_reg_d(rd),.ss_reg_we(rw),.ss_reg_q(reg_q),.ss_phase(),
 .ss_cpu_port0(q0),.ss_cpu_port1(q1),.ss_aram_dout(qa),.ss_bsram_dout(qb));
sdram_ss_reference reference(
 .clk(clk),.mclk(mclk),.clkref(clkref),.resetn(resetn),.busy(busy_ref),
 .SDRAM_DQ(dq_ref),.SDRAM_A(),.SDRAM_DQM(),.SDRAM_BA(),
 .SDRAM_nCS(),.SDRAM_nWE(),.SDRAM_nRAS(),.SDRAM_nCAS(),.SDRAM_CKE(),
 .cpu_addr(22'b0),.cpu_din(16'b0),.cpu_port(cpu_port),.cpu_req(cpu_req),
 .cpu_we(1'b0),.cpu_ds(2'b11),.cpu_req_ack(ca_ref),.cpu_port0(r0),.cpu_port1(r1),
 .cpu2_addr(22'b0),.cpu2_req(1'b0),.cpu2_dout(),.cpu2_req_ack(),
 .bsram_addr(20'b0),.bsram_din(8'b0),.bsram_req(bs_req),.bsram_we(1'b0),
 .bsram_dout(br),.bsram_req_ack(ba_ref),
 .aram_addr(16'b0),.aram_din(16'b0),.aram_req(ar_req),.aram_we(1'b0),
 .aram_16(1'b1),.aram_dout(ar),.aram_req_ack(aa_ref),
 .rv_addr(22'b0),.rv_din(16'b0),.rv_req(1'b0),.rv_we(1'b0),.rv_ds(2'b0),.rv_dout(),.rv_req_ack(),
 .total_refresh(),.ss_addr(25'b0),.ss_din(8'b0),.ss_req(1'b0),.ss_we(1'b0),.ss_ack(),.ss_q(),
 .ss_block(block),.ss_reg_a(ra),.ss_reg_d(rd),.ss_reg_we(rw),.ss_reg_q(reg_ref),.ss_phase());

reg check=0;
integer samples=0;
always @(posedge mclk or negedge mclk) if(check && !block) begin
 if ({q0,q1,qa,qb,ca,ba,aa} !== {r0,r1,ar,br,ca_ref,ba_ref,aa_ref})
  $fatal(1,"mclk consumer diverged at sample %0d",samples);
 samples=samples+1;
end
task cycles(input integer n);begin repeat(n) @(negedge mclk);end endtask
task access(input integer lane);begin
 @(negedge mclk);
 case(lane)
  0,1:begin cpu_port=lane;cpu_req=~cpu_req;wait(ca==cpu_req);end
  2:begin bs_req=~bs_req;wait(ba==bs_req);end
  3:begin ar_req=~ar_req;wait(aa==ar_req);end
 endcase
 cycles(6);
end endtask
reg [55:0] before_raw;
integer round,i;
initial begin
 repeat(5) @(negedge mclk); resetn=1;
 wait(busy===0 && busy_ref===0);cycles(20);
 // Icarus leaves the production power-up ack flops unknown; the state
 // client's existing block/parity adoption initializes both controllers.
 block=1;cycles(4);block=0;cycles(4);
 access(0);access(1);access(2);access(3);check=1;
 for(round=0;round<8;round=round+1)begin
  cycles(round+1);block=1;cycles(32);
  before_raw={raw0,raw1,rawa,rawb};
  for(i=0;i<7;i=i+1)begin
   @(negedge mclk);ra=13'h1b40+i;rd=8'h81+i+round;rw=1;
   @(negedge mclk);rw=0;cycles(2);
   if(reg_q!==reg_ref)$fatal(1,"image byte mismatch %h",ra);
  end
  if({raw0,raw1,rawa,rawb}!==before_raw)$fatal(1,"restore changed a raw DQ capture");
  cycles(32);block=0;
  access(round%4);access((round+1)%4);access((round+2)%4);access((round+3)%4);
 end
 cycles(100);
 $display("PASS: seven restored bytes, raw captures unchanged, %0d mclk consumer samples",samples);
 $finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
