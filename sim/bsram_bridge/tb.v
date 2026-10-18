`timescale 1ns/1ps
module tb;
reg clk=0;
always #5 clk=~clk;
reg gsu=0, sa1=0, owner=0;
reg [7:0] mapper=0, din=0, sd=0;
reg [19:0] addr=0;
reg ce=1, rd=1, we=1;
reg [17:0] sa=0;
reg sw=0,sr=0;
wire [7:0] q, qb;
reg ack=0, ackb=0;
reg [7:0] dout=0,doutb=0;
bridge dut(clk,gsu,sa1,owner,mapper,addr,din,ce,rd,we,sa,sd,sw,sr,ack,dout,q);
bridge_base base(clk,gsu,sa1,owner,mapper,addr,din,ce,rd,we,sa,sd,sw,sr,ackb,doutb,qb);
reg [7:0] mem[0:131071], memb[0:131071];
integer delay=0,delayb=0,checks=0,requests=0;
reg compare=1;
always @(posedge clk) begin
 if(dut.bs_req_tog!=ack) begin
  if(delay==3) begin
   if(dut.bs_we_r) mem[dut.bs_addr_r]<=dut.bs_din_r;
   else dout<=mem[dut.bs_addr_r];
   ack<=dut.bs_req_tog; delay<=0; requests<=requests+1;
  end else delay<=delay+1;
 end
 if(base.bs_req_tog!=ackb) begin
  if(delayb==3) begin
   if(base.bs_we_r) memb[base.bs_addr_r]<=base.bs_din_r;
   else doutb<=memb[base.bs_addr_r];
   ackb<=base.bs_req_tog; delayb<=0;
  end else delayb<=delayb+1;
 end
end
always @(negedge clk) if(compare) begin
 checks=checks+1;
 if ({q,dut.bs_req_tog,dut.bs_addr_r,dut.bs_din_r,dut.bs_we_r,dut.sv_ack_r,dut.sv_rack_r,dut.sv_q_r,dut.bs_fifo_full,dut.bs_fifo_empty}
 !== {qb,base.bs_req_tog,base.bs_addr_r,base.bs_din_r,base.bs_we_r,base.sv_ack_r,base.sv_rack_r,base.sv_q_r,base.bs_fifo_full,base.bs_fifo_empty})
  $fatal(1,"non-GSU bridge differs at check %0d mapper=%h",checks,mapper);
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
task save_read(input [17:0] a,input [7:0] expected);
 begin @(negedge clk);sa=a;sr=~sr;repeat(32) @(negedge clk);
 if(dut.sv_rack_r!==sr || dut.sv_q_r!==expected)$fatal(1,"save read mismatch");end
endtask
task gsu_read(input [19:0] a,input [7:0] expected);
 begin @(negedge clk);owner=1;addr=a;ce=0;we=1;rd=1;
 repeat(24) @(negedge clk);
 if(q!==expected)$fatal(1,"GSU-owned read mismatch at %h",a);
 idle;owner=0;end
endtask
integer i,j,prev_req;
initial begin
 for(i=0;i<131072;i=i+1)begin mem[i]=(i^(i>>8));memb[i]=(i^(i>>8));end
 repeat(8)@(negedge clk);
 // Compare every clock, including high addresses, read-after-write, and saves.
 for(j=0;j<2;j=j+1)begin
  mapper=j==0?8'h00:8'hc0;
  for(i=0;i<96;i=i+1)begin
   write_byte((i*1157)&20'h1ffff,i^8'h96);
   read_byte((i*1157)&20'h1ffff,i^8'h96);
   if(i%8==0)begin save_byte(18'h10020,i);save_read(18'h10020,i);end
  end
 end
 compare=0;gsu=1;mapper=8'h70;
 write_byte(20'h00020,8'ha5);write_byte(20'h10020,8'hb6);
 read_byte(20'h00020,8'ha5);prev_req=requests;read_byte(20'h10020,8'hb6);
 if(requests!=prev_req+1)$fatal(1,"upper-bank GSU read did not issue SDRAM");
 prev_req=requests;
 gsu_read(20'h00020,8'ha5);gsu_read(20'h10020,8'hb6);
 if(requests!=prev_req+1)$fatal(1,"GSU ownership read routing mismatch");
 prev_req=requests;
 read_byte(20'h00020,8'ha5);
 if(requests!=prev_req)$fatal(1,"mirrored GSU read issued SDRAM");
 save_byte(18'h00020,8'hc7);read_byte(20'h00020,8'hc7);
 save_byte(18'h10020,8'hd8);read_byte(20'h00020,8'hc7);read_byte(20'h10020,8'hd8);
 // A save issue and new cartridge write to the same byte share an edge.
 @(negedge clk);sa=18'h00020;sd=8'h11;sw=~sw;addr=20'h00020;din=8'h22;ce=0;we=0;rd=1;
 repeat(4)@(negedge clk);idle;
 read_byte(20'h00020,8'h22);
 if(mem[17'h00020]!==8'h22)$fatal(1,"coeval writes reached SDRAM out of order");
 // A save must not update the mirror before older cartridge FIFO writes issue.
 @(negedge clk);addr=20'h00020;din=8'h33;ce=0;we=0;rd=1;
 @(negedge clk);sa=18'h00020;sd=8'h44;sw=~sw;
 repeat(3)@(negedge clk);idle;
 read_byte(20'h00020,8'h44);
 if(mem[17'h00020]!==8'h44)$fatal(1,"queued/save ordering mismatch");
 sa1=1;repeat(3)@(negedge clk);if(q!==8'hc3)$fatal(1,"SA1 mux changed");
 $display("PASS: %0d non-GSU lockstep clocks; GSU mirror, upper bank, save priority and SA1",checks);
 $finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
