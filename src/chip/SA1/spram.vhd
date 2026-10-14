-- spram: single-port synchronous RAM, same entity/generics as the MiSTer
-- framework spram that SA1.vhd instantiates for its 2 KB I-RAM
-- (generic map(11, 8): addr_width, data_width). Inferred block RAM;
-- q is registered (data one clock after the address, old data on a
-- same-cycle write to the same address).

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spram is
	generic (
		addr_width : integer := 8;
		data_width : integer := 8
	);
	port (
		clock   : in std_logic;
		address : in std_logic_vector(addr_width-1 downto 0);
		wren    : in std_logic;
		data    : in std_logic_vector(data_width-1 downto 0);
		q       : out std_logic_vector(data_width-1 downto 0)
	);
end spram;

architecture rtl of spram is
	type ram_t is array (0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
	signal ram : ram_t;
begin
	process(clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				ram(to_integer(unsigned(address))) <= data;
			end if;
			q <= ram(to_integer(unsigned(address)));
		end if;
	end process;
end rtl;
