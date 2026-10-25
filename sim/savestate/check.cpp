#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include "Vsnestang_smoke.h"
#include "Vsnestang_smoke_snes_realsdram_top.h"
#include "Vsnestang_smoke_snestang_top.h"
#include "Vsnestang_smoke_sdram_chip.h"
#include "verilated.h"

struct Bench {
 Vsnestang_smoke top;
 Vsnestang_smoke_snestang_top* snes = top.snes_realsdram_top->snestang_top;
 Vsnestang_smoke_sdram_chip* chip = top.snes_realsdram_top->chip;
 uint64_t ticks=0;
 Bench() { top.sys_clk=0; top.s0=0; top.UART_RXD=1; top.eval(); }
 void step() {
  bool old=snes->__PVT__mclk_buf;
  for(;;) {
   top.sys_clk=0;top.eval();top.sys_clk=1;top.eval();
   bool now=snes->__PVT__mclk_buf;
   if(now && !old) { ++ticks; return; }
   old=now;
  }
 }
 void run(uint64_t n) {while(n--)step();}
 void op(int o) {snes->tb_ss_op=o;snes->tb_ss_op_stb=1;step();snes->tb_ss_op_stb=0;step();}
 int state() { return snes->__PVT__ss_engine__DOT__state; }
 void until(int st,uint64_t max=1000000) {while(max-- && state()!=st)step();if(state()!=st)throw std::runtime_error("state timeout");run(40);}
 std::vector<uint8_t> save() {
  uint64_t began=ticks; op(1);until(2);
  unsigned ready_wait=100000;while(ready_wait-- && !snes->__PVT__ss_engine__DOT__scan_done)step();
  if(!snes->__PVT__ss_engine__DOT__scan_done)throw std::runtime_error("capture ready timeout");
  unsigned size=snes->__PVT__ss_engine__DOT__total_bytes;
  printf("captured %u bytes at tick %lu\n",size,ticks);fflush(stdout);
  std::vector<uint8_t> out(size);
  for(unsigned a=0;a<size;++a) {
   snes->tb_ss_raddr=a;snes->tb_ss_rd=1;step();snes->tb_ss_rd=0;
   unsigned wait=500;while(wait-- && !snes->ss_img_rdy)step();
   if(!snes->ss_img_rdy)throw std::runtime_error("read timeout");
   out[a]=snes->ss_img_q;
   snes->tb_ss_taken=1;step();snes->tb_ss_taken=0;step();
  }
  printf("direct byte-bus capture/read clocks=%lu\n",ticks-began);fflush(stdout);
  return out;
 }
 void end() {op(3);until(0);}
 void load(const std::vector<uint8_t>& in) {
  op(2);until(3);
  for(unsigned a=0;a<in.size();++a) {
   if(a==512)until(5);
   snes->tb_ss_waddr=a;snes->tb_ss_wdin=in[a];snes->tb_ss_wr=1;step();snes->tb_ss_wr=0;
   run(50); // exercise the wire-side pacing constraint without UART overhead
  }
 }
 uint64_t sample() {
  return uint64_t(snes->rgb_out) | (uint64_t(snes->x_out)<<15) |
    (uint64_t(snes->y_out)<<24) | (uint64_t(snes->audio_ready)<<33) |
    (uint64_t(snes->audio_l)<<34); // right channel compared separately
 }
};
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);
 try {
  Bench b;
  uint64_t boot=argc>1?strtoull(argv[1],nullptr,10):100000000;
  b.run(boot);
  if(!b.snes->__PVT__loaded) throw std::runtime_error("ROM loader did not complete");
  if(argc>2 && !strcmp(argv[2],"--refuse")) {
   b.op(1); b.run(100);
   if(b.state()!=0) throw std::runtime_error("unsupported save accepted");
   b.op(2); b.run(100);
   if(b.state()!=0) throw std::runtime_error("unsupported load accepted");
   printf("unsupported cartridge save/load refused; no state transfer started\n");return 0;
  }
  auto image=b.save(); b.end();
  const unsigned n=357380*30;
  std::vector<uint64_t> ref(n);std::vector<uint16_t> right(n);
  unsigned visible=0, audible=0;
  for(unsigned i=0;i<n;++i){b.step();ref[i]=b.sample();right[i]=b.snes->audio_r;visible+=b.snes->rgb_out!=0;audible+=(b.snes->audio_l!=0 || b.snes->audio_r!=0);}
  printf("reference nonzero pixels=%u audio=%u\n",visible,audible);fflush(stdout);
  std::vector<uint16_t> ram(65536+32768+65536);
  for(unsigned i=0;i<65536;++i)ram[i]=b.chip->mem[0x3f0000+i];
  for(unsigned i=0;i<32768;++i)ram[65536+i]=b.chip->mem[0xbc0000+i];
  for(unsigned i=0;i<65536;++i)ram[98304+i]=b.chip->mem[0x780000+i];
  auto end_a=b.save(); b.end();
  b.snes->tb_game_reset=1;b.run(100);b.snes->tb_game_reset=0;b.run(1000);
  b.load(image);b.end();
  unsigned diffs=0;
  for(unsigned i=0;i<n;++i){b.step();if(ref[i]!=b.sample()||right[i]!=b.snes->audio_r){if(diffs<8)printf("DIFF tick %u video/audio %016lx/%016lx right %x/%x\n",i,ref[i],b.sample(),right[i],b.snes->audio_r);++diffs;}}
  unsigned rd=0;
  for(unsigned i=0;i<65536;++i)if(ram[i]!=b.chip->mem[0x3f0000+i]){++rd;printf("RAM difference WRAM byte offset %x\n",i*2);}
  for(unsigned i=0;i<32768;++i)if(ram[65536+i]!=b.chip->mem[0xbc0000+i]){++rd;printf("RAM difference ARAM byte offset %x\n",i*2);}
  for(unsigned i=0;i<65536;++i)if(ram[98304+i]!=b.chip->mem[0x780000+i]){++rd;printf("RAM difference BSRAM byte offset %x\n",i*2);}
  auto end_b=b.save(); b.end();
  unsigned image_diff=0;
  for(unsigned i=0;i<end_a.size();++i) if(end_a[i]!=end_b[i]) { if(image_diff<40)printf("endpoint image difference offset %x\n",i); ++image_diff; }
  printf("endpoint image differences=%u\n",image_diff);
  printf("A/B %u ticks, video/audio differences=%u, RAM differences=%u\n",n,diffs,rd);
  // A foreign header is rejected before reset. Ignoring the transfer's
  // frozen clocks, the running game's trajectory must remain identical.
  b.load(image); b.end();
  std::vector<uint8_t> foreign(image.begin(),image.begin()+512);
  foreign[6]=1; // NES core ID in an otherwise valid SNES image
  b.load(foreign);
  if(b.state()!=3) throw std::runtime_error("foreign header was accepted");
  b.op(4); b.until(0);
  unsigned reject_diff=0;
  // op(begin-load) executes one normal clock before freeze; abort executes
  // one normal clock, and until(0) advances another forty normal clocks.
  const unsigned advanced=42;
  for(unsigned i=advanced;i<n;++i) { b.step(); if(ref[i]!=b.sample() || right[i]!=b.snes->audio_r) ++reject_diff; }
  printf("foreign header rejection trajectory differences=%u over %u clocks\n",reject_diff,n-advanced);fflush(stdout);
  // Loading intentionally rolls cartridge RAM back. Poison the live bytes,
  // then verify every byte of the restored battery section while frozen.
  const unsigned cart=unsigned(image[20])|(unsigned(image[21])<<8)|(unsigned(image[22])<<16);
  const unsigned cart_image=512+8192+131072+65536;
  for(unsigned i=0;i<(cart+1)/2;++i) b.chip->mem[0x780000+i]=0x5a5a;
  b.load(image);
  unsigned battery_diff=0;
  for(unsigned i=0;i<cart;++i) {
   uint16_t word=b.chip->mem[0x780000+i/2];
   battery_diff+=image[cart_image+i] != uint8_t(word>>(8*(i&1)));
  }
  b.end();
  printf("battery rollback differences=%u over %u bytes\n",battery_diff,cart);
  return diffs||rd||image_diff||reject_diff||battery_diff||!visible||!audible?1:0;
 }catch(const std::exception&e){fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
