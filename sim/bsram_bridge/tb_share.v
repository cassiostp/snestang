`timescale 1ns/1ps
// 138K path: the GSU mirror is the low 64 KiB of bwram_256k (CHIP_SA1).
// Checks the one-cycle read, that low-bank reads do not issue SDRAM, that
// the upper bank still does, and that an SA-1 access uses the full address
// of the same RAM.
module tb_share;
reg clk=0;
always #5 clk=~clk;
reg gsu=0, sa1=0, owner=0;
reg [7:0] mapper=0, din=0, sd=0;
reg [19:0] addr=0;
reg ce=1, rd=1, we=1;
reg [17:0] sa=0;
reg sw=0, sr=0;
wire [7:0] q;
reg ack=0;
reg [7:0] dout=0;
reg bs_save_allow=1;
bridge dut(clk,gsu,sa1,owner,mapper,addr,din,ce,rd,we,sa,sd,sw,sr,ack,dout,q,bs_save_allow);
reg [7:0] mem[0:131071];
integer delay=0, requests=0;
always @(posedge clk) begin
 if(dut.bs_req_tog!=ack) begin
  if(delay==3) begin
   if(dut.bs_we_r) mem[dut.bs_addr_r]<=dut.bs_din_r;
   else dout<=mem[dut.bs_addr_r];
   ack<=dut.bs_req_tog; delay<=0; requests<=requests+1;
  end else delay<=delay+1;
 end
end
task idle;
 begin @(negedge clk); ce=1;rd=1;we=1;repeat(24) @(negedge clk);end
endtask
task write_byte(input [19:0] a,input [7:0] d);
 begin @(negedge clk);addr=a;din=d;ce=0;we=0;rd=1;repeat(4) @(negedge clk);idle;end
endtask
task read_byte(input [19:0] a,input [7:0] expected);
 begin @(negedge clk);addr=a;ce=0;we=1;rd=0;repeat(24) @(negedge clk);
 if(q!==expected)$fatal(1,"read %h got %h expected %h",a,q,expected);idle;end
endtask
task save_byte(input [17:0] a,input [7:0] d);
 begin @(negedge clk);sa=a;sd=d;sw=~sw;repeat(32) @(negedge clk);
 if(dut.sv_ack_r!==sw)$fatal(1,"save write did not ack");end
endtask
integer prev_req;
initial begin
 integer i;
 for(i=0;i<131072;i=i+1) mem[i]=(i^(i>>8));
 repeat(8)@(negedge clk);
 gsu=1; sa1=0; mapper=8'h70;
 write_byte(20'h00020,8'ha5);
 prev_req=requests;
 read_byte(20'h00020,8'ha5);
 if(requests!=prev_req)$fatal(1,"mirrored GSU read issued SDRAM");
 write_byte(20'h00022,8'he7);
 @(negedge clk); owner=1; addr=20'h00022; ce=0; we=1; rd=1;
 @(negedge clk);
 if(q!==8'he7)$fatal(1,"GSU minimum-cycle read is late, got %h",q);
 idle; owner=0;
 prev_req=requests;
 write_byte(20'h10020,8'hb6);
 read_byte(20'h10020,8'hb6);
 if(requests==prev_req)$fatal(1,"upper-bank GSU read did not issue SDRAM");
 save_byte(18'h00020,8'hc7);
 read_byte(20'h00020,8'hc7);
 // SA-1 uses the whole BW-RAM. A high address must not alias the mirror window.
 gsu=0; sa1=1; mapper=8'h60;
 write_byte(20'h00021,8'h51);
 read_byte(20'h00021,8'h51);
 write_byte(20'h10021,8'h61);
 read_byte(20'h10021,8'h61);
 read_byte(20'h00021,8'h51);
 // The low window is the same RAM the GSU mirror reads.
 gsu=1; sa1=0; mapper=8'h70;
 read_byte(20'h00021,8'h51);
 read_byte(20'h00020,8'hc7);
 $display("PASS: shared GSU mirror and SA-1 BW-RAM");
 $finish;
end
initial begin #500000; $fatal(1,"timeout"); end
endmodule
