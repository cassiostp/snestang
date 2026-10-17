-- CX4 chip testbench: srg320's CX4Map/CX4 exactly as the core builds them.
--
-- The bench plays the S-CPU bus (SlowROM LoROM cycles: 8 master clocks, SYSCLKR_CE on count 2 and
-- SYSCLKF_CE on count 7, like src/cpu.v), the cartridge ROM behind snestang's ROM port, and
-- checks the chip against known results:
--   1. register file: reset values and read-back of the 7F40..7F7F/7F80.. registers
--   2. the S-CPU's own ROM reads through CX4Map's LoROM address mapping
--   3. the CX4 data ROM: the package the core is built from is the same as drom.mif, and the
--      sine/sqrt/reciprocal tables hold what their names say
--   4. cache load of a hand-assembled CX4 program from ROM, run, HLT/IRQ
--   5. what the program computes: table lookups through RDROM and signed 24x24 multiplies,
--      read back through the S-CPU's $6000 data RAM window and compared with the numbers
--      worked out here (no model of the chip is involved)
--   6. the chip's DMA from ROM into its data RAM
-- ROM_DELAY is how long the ROM port takes from an address change to data (one master clock is
-- 10 ns here); the core's SDRAM port takes 2.3 to 4.3 master clocks (see sim/cx4/README.md). The
-- cache fill samples WS1+1 CX4 clocks (1.07 master clocks each) after the address changes, so a slow
-- ROM shows up as wrong program bytes; run.sh sweeps ROM_DELAY and WS to find where.

library ieee;
library std;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_cx4 is
	generic (
		ROM_DELAY_PS : integer := 0;   -- ROM port: time from address change to data, in ps
		WS        : integer := -1      -- program the ROM/RAM wait states (7F50) to this, -1 = reset value 33h
	);
end tb_cx4;

architecture sim of tb_cx4 is
	constant TCLK : time := 10 ns;
	constant ROM_DELAY : time := ROM_DELAY_PS * 1 ps;

	signal mclk       : std_logic := '0';
	signal rst_n      : std_logic := '0';
	signal enable     : std_logic := '1';

	signal ca         : std_logic_vector(23 downto 0) := (others => '0');
	signal di         : std_logic_vector(7 downto 0) := (others => '0');
	signal do_s       : std_logic_vector(7 downto 0);
	signal cpurd_n    : std_logic := '1';
	signal cpuwr_n    : std_logic := '1';
	signal sysclkf_ce : std_logic := '0';
	signal sysclkr_ce : std_logic := '0';
	signal irq_n      : std_logic;

	signal rom_addr   : std_logic_vector(22 downto 0);
	signal rom_q      : std_logic_vector(15 downto 0) := (others => '0');
	signal rom_ce_n   : std_logic;
	signal rom_oe_n   : std_logic;
	signal rom_word   : std_logic;
	signal bsram_addr : std_logic_vector(19 downto 0);
	signal bsram_d    : std_logic_vector(7 downto 0);
	signal bsram_q    : std_logic_vector(7 downto 0) := x"FF";
	signal bsram_ce_n, bsram_oe_n, bsram_we_n : std_logic;
	signal map_active : std_logic;

	constant ROM_SIZE : natural := 65536;
	type rom_t is array (0 to ROM_SIZE-1) of std_logic_vector(7 downto 0);

	-- 16-bit CX4 instruction words, little endian in ROM
	type prog_t is array (natural range <>) of std_logic_vector(15 downto 0);
	constant PROG : prog_t := (
		x"6403",   --  0 ld a,#3
		x"7000",   --  1 rdrom                 ROMB = DROM[3] = 2AAAAAh
		x"6008",   --  2 ld a,ROMB
		x"E060",   --  3 st GPR0,a
		x"6405",   --  4 ld a,#5
		x"E061",   --  5 st GPR1,a
		x"6060",   --  6 ld a,GPR0
		x"9861",   --  7 mul GPR1              2AAAAAh * 5 = D55552h
		x"0000",   --  8 nop
		x"0000",   --  9 nop
		x"6002",   --  A ld a,MACL
		x"E00C",   --  B st RAMB,a
		x"6400",   --  C ld a,#0
		x"E800",   --  D wrram b0 [a]          RAM[0] = 52h
		x"6401",   --  E ld a,#1
		x"E900",   --  F wrram b1 [a]          RAM[1] = 55h
		x"6402",   -- 10 ld a,#2
		x"EA00",   -- 11 wrram b2 [a]         RAM[2] = D5h
		x"6424",   -- 12 ld a,#24h
		x"DC04",   -- 13 shl a,4              A = 240h: sine table, 64 = pi/4
		x"7000",   -- 14 rdrom                ROMB = DROM[240h]
		x"6008",   -- 15 ld a,ROMB
		x"E00C",   -- 16 st RAMB,a
		x"6403",   -- 17 ld a,#3
		x"E800",   -- 18 wrram b0 [a]         RAM[3..5] = DROM[240h]
		x"6404",   -- 19 ld a,#4
		x"E900",   -- 1A wrram b1 [a]
		x"6405",   -- 1B ld a,#5
		x"EA00",   -- 1C wrram b2 [a]
		x"6407",   -- 1D ld a,#7
		x"E062",   -- 1E st GPR2,a
		x"6051",   -- 1F ld a,FFFFFFh         -1
		x"9862",   -- 20 mul GPR2             -1 * 7 = -7
		x"0000",   -- 21 nop
		x"0000",   -- 22 nop
		x"6002",   -- 23 ld a,MACL
		x"E00C",   -- 24 st RAMB,a
		x"6406",   -- 25 ld a,#6
		x"E800",   -- 26 wrram b0 [a]         RAM[6..8] = MACL = FFFFF9h
		x"6407",   -- 27 ld a,#7
		x"E900",   -- 28 wrram b1 [a]
		x"6408",   -- 29 ld a,#8
		x"EA00",   -- 2A wrram b2 [a]
		x"6001",   -- 2B ld a,MACH
		x"E00C",   -- 2C st RAMB,a
		x"6409",   -- 2D ld a,#9
		x"E800",   -- 2E wrram b0 [a]         RAM[9..11] = MACH = FFFFFFh
		x"640A",   -- 2F ld a,#0Ah
		x"E900",   -- 30 wrram b1 [a]
		x"640B",   -- 31 ld a,#0Bh
		x"EA00",   -- 32 wrram b2 [a]
		x"FC00"    -- 33 hlt
	);

	-- ROM image: the program at offset 0, a recognisable pattern elsewhere
	function pattern(i : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned((i * 7 + (i / 256) * 13 + 5) mod 256, 8));
	end function;

	impure function make_rom return rom_t is
		variable r : rom_t;
	begin
		for i in r'range loop
			r(i) := pattern(i);
		end loop;
		for k in PROG'range loop
			r(2 * k)     := PROG(k)(7 downto 0);
			r(2 * k + 1) := PROG(k)(15 downto 8);
		end loop;
		return r;
	end function;

	constant ROM : rom_t := make_rom;

	signal errors     : natural := 0;
	signal checks     : natural := 0;

	-- the S-CPU cycle counter, shared by the bus procedures
	signal cnt        : natural range 0 to 7 := 0;

begin

	mclk <= not mclk after TCLK / 2;

	dut : entity work.CX4Map
		port map (
			MCLK => mclk, RST_N => rst_n, ENABLE => enable,
			CA => ca, DI => di, DO => do_s, CPURD_N => cpurd_n, CPUWR_N => cpuwr_n,
			PA => x"00", PARD_N => '1', PAWR_N => '1', ROMSEL_N => '1', RAMSEL_N => '1',
			SYSCLKF_CE => sysclkf_ce, SYSCLKR_CE => sysclkr_ce, REFRESH => '0',
			IRQ_N => irq_n,
			ROM_ADDR => rom_addr, ROM_Q => rom_q, ROM_CE_N => rom_ce_n, ROM_OE_N => rom_oe_n,
			ROM_WORD => rom_word,
			BSRAM_ADDR => bsram_addr, BSRAM_D => bsram_d, BSRAM_Q => bsram_q,
			BSRAM_CE_N => bsram_ce_n, BSRAM_OE_N => bsram_oe_n, BSRAM_WE_N => bsram_we_n,
			MAP_ACTIVE => map_active, MAP_CTRL => x"40",
			ROM_MASK => x"00FFFF", BSRAM_MASK => x"000000");

	-- SlowROM S-CPU clock: R mid-cycle, F at the end (cpu.v: CPU_MID_CLOCK = 2, CPU_LAST_CLOCK = 7)
	process(mclk)
	begin
		if rising_edge(mclk) then
			sysclkr_ce <= '0';
			sysclkf_ce <= '0';
			if cnt = 2 then sysclkr_ce <= '1'; end if;
			if cnt = 7 then sysclkf_ce <= '1'; end if;
			if cnt = 7 then cnt <= 0; else cnt <= cnt + 1; end if;
		end if;
	end process;

	-- the cartridge ROM behind the core's ROM port: the byte at the address after ROM_DELAY
	rom_q <= transport x"00" & ROM(to_integer(unsigned(rom_addr(15 downto 0)))) after ROM_DELAY;

	main : process
		variable rd : std_logic_vector(7 downto 0);

		procedure check(cond : boolean; what : string) is
		begin
			checks <= checks + 1;
			if not cond then
				errors <= errors + 1;
				report "FAIL: " & what severity error;
			end if;
			wait for 0 ns;
		end procedure;

		procedure check8(got : std_logic_vector(7 downto 0); want : std_logic_vector(7 downto 0); what : string) is
		begin
			checks <= checks + 1;
			if got /= want then
				errors <= errors + 1;
				report "FAIL: " & what & ": got " & to_hstring(got) & " want " & to_hstring(want) severity error;
			end if;
			wait for 0 ns;
		end procedure;

		-- one S-CPU bus cycle (8 master clocks). The address is up for the whole cycle, the data
		-- is sampled / taken at SYSCLKF_CE like the real CPU does.
		procedure cycle(addr : std_logic_vector(23 downto 0); wr : boolean; wdata : std_logic_vector(7 downto 0);
		                rdata : out std_logic_vector(7 downto 0)) is
		begin
			-- align to the start of an S-CPU cycle
			wait until rising_edge(mclk) and cnt = 0;
			ca <= addr;
			if wr then
				di <= wdata;
				cpuwr_n <= '0';
				cpurd_n <= '1';
			else
				cpurd_n <= '0';
				cpuwr_n <= '1';
			end if;
			-- the 65C816 takes its data on the edge SYSCLKF_CE is high (cpu.v: CE = INT_CLKF_CE), and the
			-- chip registers a write on the same edge
			wait until rising_edge(mclk) and sysclkf_ce = '1';
			rdata := do_s;
			cpurd_n <= '1';
			cpuwr_n <= '1';
		end procedure;

		procedure wr8(addr : std_logic_vector(23 downto 0); d : std_logic_vector(7 downto 0)) is
			variable dummy : std_logic_vector(7 downto 0);
		begin
			cycle(addr, true, d, dummy);
		end procedure;

		procedure rd8(addr : std_logic_vector(23 downto 0); d : out std_logic_vector(7 downto 0)) is
		begin
			cycle(addr, false, x"00", d);
		end procedure;

		function mm(lo : natural) return std_logic_vector is
		begin
			return x"00" & std_logic_vector(to_unsigned(16#7000# + lo, 16));
		end function;

		function ramio(a : natural) return std_logic_vector is
		begin
			return x"00" & std_logic_vector(to_unsigned(16#6000# + a, 16));
		end function;

		-- LoROM: CPU address 00:8000 + n is ROM offset n (n < 32 KB per bank)
		function cpu_rom(off : natural) return std_logic_vector is
			variable bank : natural := off / 32768;
		begin
			return std_logic_vector(to_unsigned(bank, 8)) & std_logic_vector(to_unsigned(16#8000# + (off mod 32768), 16));
		end function;

		procedure wait_idle is
			variable s : std_logic_vector(7 downto 0);
			variable n : natural := 0;
		begin
			loop
				rd8(mm(16#F5E#), s);
				exit when s(6) = '0';
				n := n + 1;
				if n > 4000 then
					errors <= errors + 1;
					report "FAIL: chip stays busy" severity error;
					exit;
				end if;
			end loop;
		end procedure;

		-- DROM word, read from the .mif the way the core's package was made from it
		type word_arr is array (0 to 1023) of unsigned(23 downto 0);
		variable mif : word_arr := (others => (others => '0'));
		variable mif_seen : natural := 0;

		function hexval(c : character) return integer is
		begin
			if c >= '0' and c <= '9' then return character'pos(c) - character'pos('0'); end if;
			if c >= 'A' and c <= 'F' then return character'pos(c) - character'pos('A') + 10; end if;
			if c >= 'a' and c <= 'f' then return character'pos(c) - character'pos('a') + 10; end if;
			return -1;
		end function;

		-- data lines of a .mif look like "    03FF : 03243A;"
		procedure load_mif is
			file f : text open read_mode is "../../src/chip/CX4/drom.mif";
			variable l : line;
			variable colon, ai, v : integer;
			variable word : unsigned(23 downto 0);
		begin
			while not endfile(f) loop
				readline(f, l);
				colon := 0;
				for p in l'range loop
					if l(p) = ':' then colon := p; exit; end if;
				end loop;
				if colon > l'low + 3 then
					ai := 0;
					for k in colon - 4 to colon - 1 loop
						v := hexval(l(k));
						exit when v < 0;
						ai := ai * 16 + v;
					end loop;
					word := (others => '0');
					for k in colon + 2 to colon + 7 loop
						word := shift_left(word, 4) or to_unsigned(hexval(l(k)), 24);
					end loop;
					if ai <= 1023 then
						mif(ai) := word;
						mif_seen := mif_seen + 1;
					end if;
				end if;
			end loop;
		end procedure;

		variable s : std_logic_vector(7 downto 0);
		variable w : unsigned(23 downto 0);
		variable want : integer;
		variable ok : boolean;
		variable b0, b1, b2 : std_logic_vector(7 downto 0);
	begin
		rst_n <= '0';
		wait for 5 * TCLK;
		wait until rising_edge(mclk);
		rst_n <= '1';
		wait for 4 * TCLK;

		report "CX4 testbench, ROM_DELAY = " & time'image(ROM_DELAY) & ", WS = " & integer'image(WS);

		-- 1. register file ---------------------------------------------------------------
		rd8(mm(16#F50#), rd); check8(rd, x"33", "wait states after reset (7F50)");
		rd8(mm(16#F5E#), rd); check8(rd, x"00", "status after reset (7F5E)");
		rd8(mm(16#F51#), rd); check8(rd, x"01", "IRQ disabled after reset (7F51 bit 0 set)");
		wr8(mm(16#F40#), x"11"); wr8(mm(16#F41#), x"22"); wr8(mm(16#F42#), x"33");
		rd8(mm(16#F40#), rd); check8(rd, x"11", "DMA source low");
		rd8(mm(16#F41#), rd); check8(rd, x"22", "DMA source mid");
		rd8(mm(16#F42#), rd); check8(rd, x"33", "DMA source high");
		wr8(mm(16#F49#), x"A5"); wr8(mm(16#F4A#), x"5A"); wr8(mm(16#F4B#), x"C3");
		rd8(mm(16#F49#), rd); check8(rd, x"A5", "ROM base low");
		rd8(mm(16#F4A#), rd); check8(rd, x"5A", "ROM base mid");
		rd8(mm(16#F4B#), rd); check8(rd, x"C3", "ROM base high");
		wr8(mm(16#F4E#), x"FF");
		rd8(mm(16#F4E#), rd); check8(rd, x"7F", "ROM page high keeps 7 bits");
		for i in 0 to 31 loop
			wr8(mm(16#F60# + i), std_logic_vector(to_unsigned((i * 9 + 1) mod 256, 8)));
		end loop;
		ok := true;
		for i in 0 to 31 loop
			rd8(mm(16#F60# + i), rd);
			if rd /= std_logic_vector(to_unsigned((i * 9 + 1) mod 256, 8)) then ok := false; end if;
		end loop;
		check(ok, "vector memory 7F60..7F7F reads back");
		-- the vectors show through at 00:FFE0 only while the chip runs, otherwise ROM is read
		wr8(mm(16#F83#), x"12"); wr8(mm(16#F84#), x"34"); wr8(mm(16#F85#), x"56");
		rd8(mm(16#F83#), rd); check8(rd, x"12", "GPR1 low");
		rd8(mm(16#F85#), rd); check8(rd, x"56", "GPR1 high");
		-- a write to the data RAM window and back
		wr8(ramio(16#123#), x"9C");
		rd8(ramio(16#123#), rd); check8(rd, x"9C", "data RAM byte via $6123");
		-- 2. the S-CPU's own ROM reads ---------------------------------------------------
		ok := true;
		for k in 0 to 40 loop
			-- a spread of LoROM addresses: banks 00 and 01, and the 80+ mirror
			rd8(cpu_rom(100 + k * 997), rd);
			if rd /= ROM((100 + k * 997) mod ROM_SIZE) then ok := false; end if;
		end loop;
		check(ok, "S-CPU ROM reads through the LoROM map");
		rd8(x"808000", rd);
		check8(rd, ROM(0), "bank 80 mirrors bank 00");
		-- Alternate SRAM and ROM to check both arms of the S-CPU's LUT mux.
		ok := true;
		for k in 0 to 255 loop
			bsram_q <= std_logic_vector(to_unsigned(k, 8));
			rd8(x"700000", rd);
			if rd /= std_logic_vector(to_unsigned(k, 8)) then ok := false; end if;
			rd8(cpu_rom(100 + k), rd);
			if rd /= ROM(100 + k) then ok := false; end if;
		end loop;
		check(ok, "S-CPU SRAM/ROM mux selects each byte without adding a cycle");
		-- 3. the data ROM ----------------------------------------------------------------
		load_mif;
		check(mif_seen = 1024, "drom.mif has all 1024 words (" & integer'image(mif_seen) & ")");
		ok := true;
		for i in 0 to 1023 loop
			if work.cx4_drom_pkg.CX4_DROM(i) /= std_logic_vector(mif(i)) then ok := false; end if;
		end loop;
		check(ok, "cx4_drom_pkg is drom.mif");
		-- sine table: DROM[200h + i] = sin(i * pi/256) * 2^24, i = 0..127
		ok := true;
		for i in 0 to 127 loop
			want := integer(round(sin(real(i) * MATH_PI / 256.0) * 16777216.0));
			if want > 16777215 then want := 16777215; end if;
			if abs(to_integer(mif(512 + i)) - want) > 2 then ok := false; end if;
		end loop;
		check(ok, "DROM[200h..27Fh] is the sine table");
		-- square roots: DROM[100h + i] = sqrt(i) * 2^20, i = 0..255
		ok := true;
		for i in 0 to 255 loop
			want := integer(round(sqrt(real(i)) * 1048576.0));
			if abs(to_integer(mif(256 + i)) - want) > 2 then ok := false; end if;
		end loop;
		check(ok, "DROM[100h..1FFh] is the square root table");
		-- reciprocals: DROM[i] = 2^23 / i, i = 1..127
		ok := true;
		for i in 2 to 127 loop
			want := integer(round(8388608.0 / real(i)));
			if abs(to_integer(mif(i)) - want) > 2 then ok := false; end if;
		end loop;
		check(ok, "DROM[2..7Fh] is the reciprocal table");

		-- 4. cache load of the program, run ------------------------------------------------
		if WS >= 0 then
			wr8(mm(16#F50#), std_logic_vector(to_unsigned(WS * 16 + WS, 8)));
		end if;
		wr8(mm(16#F51#), x"00");                    -- enable the IRQ (bit 0 clear)
		wr8(mm(16#F49#), x"00"); wr8(mm(16#F4A#), x"80"); wr8(mm(16#F4B#), x"00");   -- ROM base 00:8000
		wr8(mm(16#F4D#), x"00"); wr8(mm(16#F4E#), x"00");                              -- page 0
		wr8(mm(16#F48#), x"00");                    -- cache bank 0: start loading 512 bytes
		wait_idle;
		rd8(mm(16#F5E#), s); check8(s and x"40", x"00", "idle after the cache load");
		wr8(mm(16#F4F#), x"00");                    -- run from PC 0
		wait_idle;
		rd8(mm(16#F5E#), s);
		check8(s and x"03", x"02", "IRQ flag set after HLT");
		check(irq_n = '0', "IRQ_N low after HLT");
		wr8(mm(16#F51#), x"01");                    -- acknowledge
		wait for 2 * TCLK;
		check(irq_n = '1', "IRQ_N released by 7F51");

		-- 5. results of the program ---------------------------------------------------------
		rd8(ramio(0), b0); rd8(ramio(1), b1); rd8(ramio(2), b2);
		check8(b0, x"52", "2AAAAAh * 5, low byte");
		check8(b1, x"55", "2AAAAAh * 5, mid byte");
		check8(b2, x"D5", "2AAAAAh * 5, high byte");
		w := unsigned(work.cx4_drom_pkg.CX4_DROM(16#240#));
		rd8(ramio(3), b0); rd8(ramio(4), b1); rd8(ramio(5), b2);
		check8(b0, std_logic_vector(w(7 downto 0)), "sine table entry 240h, low byte");
		check8(b1, std_logic_vector(w(15 downto 8)), "sine table entry 240h, mid byte");
		check8(b2, std_logic_vector(w(23 downto 16)), "sine table entry 240h, high byte");
		-- sin(64 * pi/256) = 0.7071 -> B504F3h by the formula, the table has the same
		want := integer(round(sin(64.0 * MATH_PI / 256.0) * 16777216.0));
		check(abs(to_integer(w) - want) <= 2, "sine(pi/4) from the data ROM = " & integer'image(want));
		rd8(ramio(6), b0); rd8(ramio(7), b1); rd8(ramio(8), b2);
		check8(b0, x"F9", "-1 * 7, MACL low byte");
		check8(b1, x"FF", "-1 * 7, MACL mid byte");
		check8(b2, x"FF", "-1 * 7, MACL high byte");
		rd8(ramio(9), b0); rd8(ramio(10), b1); rd8(ramio(11), b2);
		check8(b0, x"FF", "-1 * 7, MACH low byte");
		check8(b2, x"FF", "-1 * 7, MACH high byte");

		-- 6. DMA from ROM into the data RAM -------------------------------------------------
		wr8(mm(16#F40#), x"00"); wr8(mm(16#F41#), x"A0"); wr8(mm(16#F42#), x"00");   -- source 00:A000 = ROM 2000h
		wr8(mm(16#F43#), x"40"); wr8(mm(16#F44#), x"00");                              -- 64 bytes
		wr8(mm(16#F45#), x"00"); wr8(mm(16#F46#), x"62"); wr8(mm(16#F47#), x"00");   -- dest 00:6200 (starts the DMA)
		wait_idle;
		ok := true;
		for i in 0 to 63 loop
			rd8(ramio(16#200# + i), rd);
			if rd /= ROM(16#2000# + i) then ok := false; end if;
		end loop;
		check(ok, "DMA ROM -> data RAM copies 64 bytes");

		report "checks: " & integer'image(checks) & ", errors: " & integer'image(errors);
		if errors = 0 then
			report "PASS";
		else
			report "FAIL" severity failure;
		end if;
		wait for 20 * TCLK;
		std.env.finish;
	end process;
end sim;
