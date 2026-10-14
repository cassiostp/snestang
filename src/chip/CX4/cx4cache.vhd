-- Program cache RAM for CX4.vhd: 512 x 8, one write port, asynchronous read.
-- srg320's cx4cache.vhd is an Altera altdpram wizard file (altera_mf, MLAB), which
-- GowinSynthesis cannot read. This has the same entity and the same behaviour,
-- built from Gowin RAM16SDP4 shadow-SRAM primitives (UG300): 32 banks of 16 x 4
-- per nibble, read addresses asynchronous, writes bank-decoded.

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
	component RAM16SDP4
		generic (
			INIT_0 : std_logic_vector(15 downto 0) := x"0000";
			INIT_1 : std_logic_vector(15 downto 0) := x"0000";
			INIT_2 : std_logic_vector(15 downto 0) := x"0000";
			INIT_3 : std_logic_vector(15 downto 0) := x"0000"
		);
		port (
			DO  : out std_logic_vector(3 downto 0);
			DI  : in  std_logic_vector(3 downto 0);
			CLK : in  std_logic;
			WRE : in  std_logic;
			WAD : in  std_logic_vector(3 downto 0);
			RAD : in  std_logic_vector(3 downto 0)
		);
	end component;

	type nib_t is array (0 to 31) of std_logic_vector(3 downto 0);
	signal do_lo, do_hi : nib_t;
	signal wre_bank : std_logic_vector(0 to 31);
begin
	gen_bank : for b in 0 to 31 generate
		wre_bank(b) <= wren when to_integer(unsigned(wraddress(8 downto 4))) = b else '0';

		lo : RAM16SDP4
			port map (
				DO  => do_lo(b),
				DI  => data(3 downto 0),
				CLK => clock,
				WRE => wre_bank(b),
				WAD => wraddress(3 downto 0),
				RAD => rdaddress(3 downto 0)
			);

		hi : RAM16SDP4
			port map (
				DO  => do_hi(b),
				DI  => data(7 downto 4),
				CLK => clock,
				WRE => wre_bank(b),
				WAD => wraddress(3 downto 0),
				RAD => rdaddress(3 downto 0)
			);
	end generate;

	q <= do_hi(to_integer(unsigned(rdaddress(8 downto 4)))) &
	     do_lo(to_integer(unsigned(rdaddress(8 downto 4))));
end rtl;
