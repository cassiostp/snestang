-- SA1MULT: signed 16x16 -> 32 multiplier for the SA-1 arithmetic unit.
-- Same entity as srg320's SNES_MiSTer SA1MULT.vhd, whose implementation is
-- an Altera lpm_mult wizard file; replaced here by a plain signed multiply
-- (lpm_representation = "SIGNED", no pipeline stages).

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

ENTITY SA1MULT IS
	PORT
	(
		dataa		: IN STD_LOGIC_VECTOR (15 DOWNTO 0);
		datab		: IN STD_LOGIC_VECTOR (15 DOWNTO 0);
		result		: OUT STD_LOGIC_VECTOR (31 DOWNTO 0)
	);
END SA1MULT;

ARCHITECTURE rtl OF SA1MULT IS
BEGIN
	result <= std_logic_vector(signed(dataa) * signed(datab));
END rtl;
