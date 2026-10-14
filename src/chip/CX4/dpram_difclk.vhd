-- True dual-port RAM, a different clock and width on each port, with the entity of the MiSTer
-- framework's dpram_difclk (rtl/bram.vhd, an Altera altsyncram wrapper). Synchronous read on both
-- ports, the written word comes back on the writing port's q (NEW_DATA_NO_NBE_READ).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_difclk is
	generic (
		addr_width_a  : integer := 8;
		data_width_a  : integer := 8;
		addr_width_b  : integer := 8;
		data_width_b  : integer := 8;
		mem_init_file : string := " "
	);
	port (
		clock0    : in  std_logic;
		clock1    : in  std_logic;

		address_a : in  std_logic_vector(addr_width_a-1 downto 0);
		data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width_a-1 downto 0);
		cs_a      : in  std_logic := '1';

		address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width_b-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end dpram_difclk;

architecture rtl of dpram_difclk is
	-- Only equal-width ports are used (CX4 data RAM, 4096 x 8 on both).
	type ram_t is array (0 to 2**addr_width_a-1) of std_logic_vector(data_width_a-1 downto 0);
	shared variable ram : ram_t := (others => (others => '0'));
	signal q0 : std_logic_vector(data_width_a-1 downto 0);
	signal q1 : std_logic_vector(data_width_b-1 downto 0);
begin
	assert addr_width_a = addr_width_b and data_width_a = data_width_b
		report "dpram_difclk: ports must have the same shape" severity failure;

	process(clock0)
	begin
		if rising_edge(clock0) then
			if enable_a = '1' then
				if wren_a = '1' and cs_a = '1' then
					ram(to_integer(unsigned(address_a))) := data_a;
					q0 <= data_a;
				else
					q0 <= ram(to_integer(unsigned(address_a)));
				end if;
			end if;
		end if;
	end process;

	process(clock1)
	begin
		if rising_edge(clock1) then
			if enable_b = '1' then
				if wren_b = '1' and cs_b = '1' then
					ram(to_integer(unsigned(address_b))) := data_b;
					q1 <= data_b;
				else
					q1 <= ram(to_integer(unsigned(address_b)));
				end if;
			end if;
		end if;
	end process;

	q_a <= q0 when cs_a = '1' else (others => '1');
	q_b <= q1 when cs_b = '1' else (others => '1');
end rtl;
