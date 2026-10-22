`timescale 1ns/1ps
module tb_control;
reg clk=0;
always #5 clk=~clk;
reg resetn=0, supported=0, point=0, op_stb=0, img_wr=0;
reg [2:0] op=0;
reg [19:0] wa=0;
reg [7:0] wd=0;
wire freeze, reset, loaded, active;
wire [127:0] status;
wire [24:0] ma;
wire [7:0] md;
wire mwe,mreq;
reg mack=0;
always @(posedge clk) mack<=mreq;
savestate dut(.clk(clk),.clkref(1'b0),.resetn(resetn),.mapper_flags(64'b0),
 .ss_supported(supported),.ss_point(point),.ss_freeze(freeze),.ss_reset(reset),.ss_loaded(loaded),.ss_edge_reset(),.ss_active(active),
 .ss_a(),.ss_din(),.ss_we(),.ss_dout(8'b0),.sd_douta(8'b0),.sd_doutb(8'b0),.sd_ld_we(),.sd_ld_douta(),.sd_ld_doutb(),
 .mem_addr(ma),.mem_din(md),.mem_we(mwe),.mem_req(mreq),.mem_ack(mack),.mem_q(8'b0),
 .op(op),.op_stb(op_stb),.ss_status(status),
 .img_raddr(20'b0),.img_rd_stb(1'b0),.img_taken(1'b0),.img_abort(1'b0),.img_rdy(),.img_q(),
 .img_waddr(wa),.img_wdin(wd),.img_wr_stb(img_wr));
task tick; begin @(posedge clk); #1; end endtask
task control(input [2:0] command); begin @(negedge clk);op=command;op_stb=1;tick;@(negedge clk);op_stb=0;tick;end endtask
integer i;
initial begin
 repeat(3)tick;resetn=1;tick;
 control(1);if(active||freeze||reset)$fatal(1,"unsupported save disturbed machine");
 control(2);if(active||freeze||reset)$fatal(1,"unsupported load disturbed machine");
 supported=1;control(1);if(dut.state!=1)$fatal(1,"save did not wait");
 @(negedge clk);point=1;op=4;op_stb=1;tick;
 if(active||freeze||reset)$fatal(1,"capture point overwrote abort");
 @(negedge clk);point=0;op_stb=0;tick;
 control(2);if(dut.state!=3||!freeze)$fatal(1,"load did not wait for header");
 for(i=0;i<512;i=i+1)begin
  @(negedge clk);wa=i;wd=dut.hdr_byte(i);if(i==6)wd=1;img_wr=1;tick;
  @(negedge clk);img_wr=0;tick;
  if(reset)$fatal(1,"foreign header reset the machine");
 end
 repeat(5)tick;
 if(dut.state!=3||!status[9]||reset)$fatal(1,"foreign header accepted");
 control(4);if(active||freeze||reset)$fatal(1,"abort failed");
 control(1);point=1;repeat(40)tick;
 if(dut.state!=2||!freeze)$fatal(1,"supported save failed");
 control(3);repeat(80)tick;
 if(active||freeze||reset)$fatal(1,"end did not resume");
 $display("PASS: unsupported save/load, capture-abort race, foreign header before reset, save/end");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
