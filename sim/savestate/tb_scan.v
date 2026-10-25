`timescale 1ns/1ps
module tb_scan;
reg clk=0;
always #5 clk=~clk;
reg resetn=0, point=0, op_stb=0, rd=0, taken=0, wr=0;
reg [2:0] op=0;
reg [19:0] raddr=0,waddr=0;
reg [7:0] wdin=0;
wire freeze,active,ss_we,rdy,mreq;
wire [12:0] ss_a;
wire [7:0] ss_d,q;
reg [7:0] ss_q;
wire [127:0] status;
reg mack=0;
always @(posedge clk) mack<=mreq;
savestate dut(.clk(clk),.clkref(1'b0),.resetn(resetn),.mapper_flags(64'b0),
 .ss_supported(1'b1),.ss_point(point),.ss_freeze(freeze),.ss_reset(),.ss_loaded(),.ss_edge_reset(),.ss_active(active),
 .ss_a(ss_a),.ss_din(ss_d),.ss_we(ss_we),.ss_dout(ss_q),.sd_douta(8'b0),.sd_doutb(8'b0),.sd_ld_we(),.sd_ld_douta(),.sd_ld_doutb(),
 .mem_addr(),.mem_din(),.mem_we(),.mem_req(mreq),.mem_ack(mack),.mem_q(8'b0),
 .op(op),.op_stb(op_stb),.ss_status(status),.img_raddr(raddr),.img_rd_stb(rd),.img_taken(taken),.img_abort(1'b0),
 .img_rdy(rdy),.img_q(q),.img_waddr(waddr),.img_wdin(wdin),.img_wr_stb(wr));
`include "scan_sizes.vh"
reg [7:0] nodes[0:SCAN_COUNT-1], image[0:8191], saved[0:8191];
integer index_of[0:8191];
`include "scan_fixture.vh"
integer n;
always @* begin
 ss_q=0;
 if(ss_a>=13'h1bf0 && ss_a<=13'h1bf5) begin
  if(ss_we) case(ss_a[2:1])
   0:ss_q=nodes[0];
   1:ss_q=nodes[PPU_END+1];
   2:ss_q=nodes[DSP_END+1];
   default:;
  endcase
 end else if(index_of[ss_a]<0) ss_q=image[ss_a];
end
always @(posedge clk) if(ss_we) begin
 case(ss_a)
 13'h1bf0,13'h1bf1:begin
  for(n=0;n<PPU_END;n=n+1)nodes[n]<=nodes[n+1];
  nodes[PPU_END]<=ss_a[0]?ss_d:nodes[0];
 end
 13'h1bf2,13'h1bf3:begin
  for(n=PPU_END+1;n<DSP_END;n=n+1)nodes[n]<=nodes[n+1];
  nodes[DSP_END]<=ss_a[0]?ss_d:nodes[PPU_END+1];
 end
 13'h1bf4,13'h1bf5:begin
  for(n=DSP_END+1;n<SCAN_COUNT-1;n=n+1)nodes[n]<=nodes[n+1];
  nodes[SCAN_COUNT-1]<=ss_a[0]?ss_d:nodes[DSP_END+1];
 end
 default:if(index_of[ss_a]<0)image[ss_a]<=ss_d;
 endcase
end
task tick;begin @(posedge clk);#1;end endtask
task control(input [2:0] v);begin @(negedge clk);op=v;op_stb=1;tick;@(negedge clk);op_stb=0;tick;end endtask
task idle;integer limit;begin
 limit=10000;while(active && limit>0)begin tick;limit=limit-1;end
 if(active||freeze)$fatal(1,"did not resume");
end endtask
task begin_save;begin control(1);point=1;repeat(3)tick;point=0;end endtask
task check_nodes;integer j;begin
 for(j=0;j<SCAN_COUNT;j=j+1)if(nodes[j]!==((j*37+11)&255))$fatal(1,"chain mismatch node %0d value %h",j,nodes[j]);
end endtask
integer a,j,limit,expected,checkpoint;
initial begin
 for(a=0;a<8192;a=a+1)image[a]=(a*19+3)&255;
 for(j=0;j<SCAN_COUNT;j=j+1)nodes[j]=(j*37+11)&255;
 repeat(3)tick;resetn=1;tick;
 begin_save;
 limit=10000;while(!status[8] && limit>0)begin tick;limit=limit-1;end
 if(!status[8])$fatal(1,"capture never became ready");
 check_nodes;
 for(a=0;a<8192;a=a+1)begin
  @(negedge clk);raddr=a+512;rd=1;tick;
  @(negedge clk);rd=0;
  limit=20;while(!rdy && limit>0)begin tick;limit=limit-1;end
  if(!rdy)$fatal(1,"read timeout %h",a);
  saved[a]=q;
  expected=index_of[a]<0?image[a]:((index_of[a]*37+11)&255);
  if(a>=13'h1bf0 && a<=13'h1bf5)expected=0;
  if(q!==expected[7:0])$fatal(1,"image mismatch %h got %h expected %h",a,q,expected[7:0]);
  @(negedge clk);taken=1;tick;@(negedge clk);taken=0;tick;
 end
 control(3);idle;
 for(j=0;j<SCAN_COUNT;j=j+1)nodes[j]=~nodes[j];
 control(2);
 // Header and register payload are deliberately one byte per clock.
 @(negedge clk);wr=1;
 for(a=0;a<512;a=a+1)begin waddr=a;wdin=dut.hdr_byte(a);tick;@(negedge clk);end
 wr=0;limit=100;while(dut.state!=5 && limit>0)begin tick;limit=limit-1;end
 if(dut.state!=5)$fatal(1,"load header rejected");
 @(negedge clk);wr=1;
 for(a=0;a<8192;a=a+1)begin waddr=a+512;wdin=saved[a];tick;@(negedge clk);end
 wr=0;control(3);idle;check_nodes;
 // Abort after each chain has begun; release must wait for full rotation.
 for(checkpoint=1;checkpoint<=350;checkpoint=checkpoint+174)begin
  begin_save;
  wait(dut.scan_busy && dut.scan_index>=checkpoint);control(4);
  if(!freeze)$fatal(1,"abort released a partially rotated chain");
  idle;check_nodes;
 end
 $display("PASS: 8192 sparse bytes, %0d scan bytes, continuous load, three mid-scan aborts",SCAN_COUNT);$finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
