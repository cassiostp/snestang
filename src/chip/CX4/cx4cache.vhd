-- Program cache RAM for CX4.vhd: 512 x 8, one write port, synchronous read.
-- srg320's cx4cache.vhd is an Altera altdpram wizard file (altera_mf, MLAB), which
-- GowinSynthesis cannot read. This has the same entity and the same behaviour in plain VHDL.
--
-- Gowin note: the GW5AST has no distributed/SSRAM, so the previous asynchronous-read
-- version became ~4k flip-flops per byte lane plus a wide read mux sitting in the
-- PC -> IR -> data-RAM-address half-cycle path (`cassiostp/tangcore#34`). This version
-- keeps the entity and the CX4.vhd fill protocol (CACHE_WE/CACHE_ADDR_WR sample the
-- write on rising CLK, exactly as before) and maps each lane to one BSRAM:
--   * the write port samples data/wraddress/wren on rising CLK, unchanged;
--   * the read port presents mem[rdaddress] after the falling CLK edge.
-- The falling-edge read is load-bearing: the CX4 CPU samples IR only on rising CLK
-- edges where its ~2 MHz CE is high (CPU_EN in CX4.vhd), while an S-CPU-programmed
-- PC/BANK change ($7F4F start in CX4.vhd) can land a single MCLK before such an
-- edge, so a rising-edge read could execute a stale first instruction. PC and BANK
-- are MCLK registers, so the read address is stable half a cycle before the falling
-- edge, and the fresh IR still has half a cycle of setup to every rising-edge
-- consumer. During cache fills and DMA the CPU is stalled, so read-during-write
-- values are never consumed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cx4cache is
	port (
		clock     : in  std_logic;
		data      : in  std_logic_vector(7 downto 0);
		rdaddress : in  std_logic_vector(8 downto 0);
		wraddress : in  std_logic_vector(8 downto 0);
		wren      : in  std_logic := '0';
		q         : out std_logic_vector(7 downto 0)
	);
end cx4cache;

architecture rtl of cx4cache is
	type ram_t is array (0 to 511) of std_logic_vector(7 downto 0);
	shared variable ram : ram_t := (others => (others => '0'));
	signal q0 : std_logic_vector(7 downto 0) := (others => '0');
begin
	process(clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				ram(to_integer(unsigned(wraddress))) := data;
			end if;
		end if;
	end process;

	process(clock)
	begin
		if falling_edge(clock) then
			q0 <= ram(to_integer(unsigned(rdaddress)));
		end if;
	end process;

	q <= q0;
end rtl;
