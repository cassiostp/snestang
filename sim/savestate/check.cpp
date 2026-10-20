#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <stdexcept>
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
  op(1);until(2);
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
  auto image=b.save(); b.end();
  const unsigned n=357380*4;
  std::vector<uint64_t> ref(n);std::vector<uint16_t> right(n);
  for(unsigned i=0;i<n;++i){b.step();ref[i]=b.sample();right[i]=b.snes->audio_r;}
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
  return diffs||rd?1:0;
 }catch(const std::exception&e){fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
