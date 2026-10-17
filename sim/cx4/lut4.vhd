-- Simulation-only model of Gowin's LUT4. The FPGA build uses the primitive.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity LUT4 is
	generic (INIT : bit_vector(15 downto 0) := x"0000");
	port (
		F : out std_logic;
		I0, I1, I2, I3 : in std_logic
	);
end LUT4;

architecture sim of LUT4 is
	constant TABLE : std_logic_vector(15 downto 0) := to_stdlogicvector(INIT);
	signal addr : std_logic_vector(3 downto 0);
begin
	addr <= I3 & I2 & I1 & I0;
	F <= TABLE(to_integer(unsigned(addr))) when not is_x(addr) else 'X';
end sim;
