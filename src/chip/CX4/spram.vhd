-- Single-port RAM with the entity of the MiSTer framework's spram (rtl/bram.vhd, an Altera
-- altsyncram wrapper), for the chips taken from SNES_MiSTer unchanged. Synchronous read,
-- the written word comes back on q (altsyncram NEW_DATA_NO_NBE_READ).
-- mem_init_file is a name, not a file: GowinSynthesis cannot read one. CX4.vhd asks for
-- rtl/chip/CX4/drom.mif, the CX4 data ROM, which comes from cx4_drom_pkg.vhd (see tools/mif2vhdl.py).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cx4_drom_pkg.all;

entity spram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " ";
		mem_name      : string := "MEM"
	);
	port (
		clock   : in  std_logic;
		address : in  std_logic_vector(addr_width-1 downto 0);
		data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable  : in  std_logic := '1';
		wren    : in  std_logic := '0';
		q       : out std_logic_vector(data_width-1 downto 0);
		cs      : in  std_logic := '1'
	);
end spram;

architecture rtl of spram is
	type ram_t is array (0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);

	function init_ram return ram_t is
		variable r : ram_t := (others => (others => '0'));
	begin
		if mem_init_file = "rtl/chip/CX4/drom.mif" then
			for i in CX4_DROM'range loop
				r(i) := CX4_DROM(i);
			end loop;
		end if;
		return r;
	end function;

	signal ram : ram_t := init_ram;
	signal q0  : std_logic_vector(data_width-1 downto 0);
begin
	process(clock)
	begin
		if rising_edge(clock) then
			if enable = '1' then
				if wren = '1' and cs = '1' then
					ram(to_integer(unsigned(address))) <= data;
					q0 <= data;
				else
					q0 <= ram(to_integer(unsigned(address)));
				end if;
			end if;
		end if;
	end process;

	q <= q0 when cs = '1' else (others => '1');
end rtl;
