-- Program cache RAM for CX4.vhd: 512 x 8, one write port, asynchronous read.
-- srg320's cx4cache.vhd is an Altera altdpram wizard file (altera_mf, MLAB), which
-- GowinSynthesis cannot read. This has the same entity and the same behaviour in
-- plain VHDL. GW5AST-138B has no SSRAM the tools can use (UG300-1.3.6E Table 5-1)
-- and BSRAM reads are synchronous, so the storage stays in flip-flops; the read is
-- predecoded one-hot AND-OR rather than an indexed read, so the PC bits each drive
-- one small decoder instead of every level of a 512-way mux tree. That was most of
-- the PC -> IR -> data-RAM-address half-cycle path delay (route, high fanout).

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
	signal ram : ram_t := (others => (others => '0'));

	function dec3(a : std_logic_vector(2 downto 0)) return std_logic_vector is
		variable r : std_logic_vector(7 downto 0) := (others => '0');
	begin
		r(to_integer(unsigned(a))) := '1';
		return r;
	end function;

	signal dec_lo  : std_logic_vector(7 downto 0);
	signal dec_mid : std_logic_vector(7 downto 0);
	signal dec_hi  : std_logic_vector(7 downto 0);
begin
	process(clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				ram(to_integer(unsigned(wraddress))) <= data;
			end if;
		end if;
	end process;

	dec_lo  <= dec3(rdaddress(2 downto 0));
	dec_mid <= dec3(rdaddress(5 downto 3));
	dec_hi  <= dec3(rdaddress(8 downto 6));

	process(ram, dec_lo, dec_mid, dec_hi)
		variable v : std_logic_vector(7 downto 0);
	begin
		v := (others => '0');
		for i in 0 to 511 loop
			if dec_hi(i / 64) = '1' and dec_mid((i / 8) mod 8) = '1' and dec_lo(i mod 8) = '1' then
				v := v or ram(i);
			end if;
		end loop;
		q <= v;
	end process;
end rtl;
