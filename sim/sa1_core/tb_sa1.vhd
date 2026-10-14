-- SA-1 core testbench (GHDL): SA1Map + SA1 + P65C816_SA1 against models
-- of snestang's memory system:
--   * S-CPU ROM lane: SNES_ROM_Q presents the word 3 mclk after
--     SNES_ROM_ADDR changes (the SDRAM CPU lane's sticky register);
--   * SA-1 ROM lane: a word is presented 4 mclk after ROM_ADDR changes
--     under ROM_REQ, with ROM_WAIT up until then (a cache miss every
--     word: the worst case for the ROM_WAIT stall points);
--   * BW-RAM: synchronous RAM, q holds during writes (bwram_256k port A).
-- A fake S-CPU drives 6-mclk bus cycles with SYSCLKR_CE in cycle 3 and
-- SYSCLKF_CE in cycle 5, probes the S-CPU ROM lane (incl. the live CXB
-- bank map: CXB is the 1 MB bank, so CXB=1/CBMAP=1 takes $00:8000 to ROM
-- $100000), seeds BW-RAM, releases the SA-1 from reset, and checks the
-- results of the SA-1 program built by mkrom.py (multiply, divide, VBP
-- preload, BW-RAM both ways, I-RAM, normal DMA ROM->I-RAM).

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
library STD;
use STD.TEXTIO.ALL;
use STD.ENV.ALL;

entity tb_sa1 is
end tb_sa1;

architecture sim of tb_sa1 is

constant TCLK : time := 46 ns;

signal CLK : std_logic := '0';
signal RST_N : std_logic := '0';

signal CA : std_logic_vector(23 downto 0) := (others => '0');
signal DI : std_logic_vector(7 downto 0) := (others => '0');
signal DO : std_logic_vector(7 downto 0);
signal RD_N : std_logic := '1';
signal WR_N : std_logic := '1';
signal SYSCLKF_CE : std_logic := '0';
signal SYSCLKR_CE : std_logic := '0';

signal ROM_ADDR_I : std_logic_vector(22 downto 0);
signal ROM_REQ : std_logic;
signal ROM_WAIT : std_logic;
signal ROM_DI_R : std_logic_vector(15 downto 0) := (others => '0');
signal SNES_ROM_ADDR_I : std_logic_vector(22 downto 0);
signal SNES_ROM_Q_R : std_logic_vector(15 downto 0) := (others => '0');

signal BSRAM_ADDR_I : std_logic_vector(19 downto 0);
signal BSRAM_D_I : std_logic_vector(7 downto 0);
signal BSRAM_Q_R : std_logic_vector(7 downto 0) := (others => '0');
signal BSRAM_WE_N_I : std_logic;

type rom_t is array (0 to 2097151) of std_logic_vector(7 downto 0);
type bw_t is array (0 to 262143) of std_logic_vector(7 downto 0);

impure function load_rom return rom_t is
    file f : text open read_mode is "sa1test.hex";
    variable l : line;
    variable r : rom_t;
    variable b : std_logic_vector(7 downto 0);
begin
    for i in r'range loop
        readline(f, l);
        hread(l, b);
        r(i) := b;
    end loop;
    return r;
end function;

signal rom : rom_t := load_rom;
signal bwram : bw_t := (others => (others => '0'));

signal wait_cycles : integer := 0;

function rom_word(r : rom_t; a : std_logic_vector(22 downto 0)) return std_logic_vector is
    variable base : integer;
begin
    base := to_integer(unsigned(a(22 downto 1))) * 2;
    return r(base + 1) & r(base);
end function;

begin

CLK <= not CLK after TCLK / 2;

UUT : entity work.SA1Map
port map (
    MCLK => CLK,
    RST_N => RST_N,
    ENABLE => '1',
    CA => CA,
    DI => DI,
    DO => DO,
    CPURD_N => RD_N,
    CPUWR_N => WR_N,
    PA => x"00",
    PARD_N => '1',
    PAWR_N => '1',
    ROMSEL_N => '0',
    RAMSEL_N => '0',
    SYSCLKF_CE => SYSCLKF_CE,
    SYSCLKR_CE => SYSCLKR_CE,
    REFRESH => '0',
    PAL => '0',
    IRQ_N => open,
    ROM_ADDR => ROM_ADDR_I,
    ROM_Q => ROM_DI_R,
    ROM_CE_N => open,
    ROM_OE_N => open,
    ROM_WORD => open,
    ROM_REQ => ROM_REQ,
    ROM_WAIT => ROM_WAIT,
    SNES_ROM_ADDR => SNES_ROM_ADDR_I,
    SNES_ROM_Q => SNES_ROM_Q_R,
    SNES_ROM_CE_N => open,
    BSRAM_ADDR => BSRAM_ADDR_I,
    BSRAM_D => BSRAM_D_I,
    BSRAM_Q => BSRAM_Q_R,
    BSRAM_CE_N => open,
    BSRAM_OE_N => open,
    BSRAM_WE_N => BSRAM_WE_N_I,
    MAP_ACTIVE => open,
    MAP_CTRL => x"63",
    ROM_MASK => x"1FFFFF",
    BSRAM_MASK => x"03FFFF",
    SA1_P65_A => open,
    SA1_P65_DO => open,
    SA1_P65_RD_N => open,
    SA1_P65_WR_N => open,
    SS_BUSY => '0',
    SS_SA1_ROMSEL => open,
    SS_SNS_ROMSEL => open
);

-- SA-1 ROM lane: present each new word 4 mclk after it is requested
sa1_lane : process(CLK)
    variable busy_cnt : integer := 0;
    variable pending : std_logic_vector(22 downto 0) := (others => '0');
    variable presented : std_logic_vector(22 downto 0) := (others => '0');
    variable presented_valid : boolean := false;
begin
    if rising_edge(CLK) then
        if ROM_WAIT = '1' and ROM_REQ = '1' then
            wait_cycles <= wait_cycles + 1;
        end if;
        if busy_cnt > 1 then
            busy_cnt := busy_cnt - 1;
        elsif busy_cnt = 1 then
            busy_cnt := 0;
            presented := pending;
            presented_valid := true;
            ROM_DI_R <= rom_word(rom, pending);
        elsif ROM_REQ = '1' and not (presented_valid and presented(22 downto 1) = ROM_ADDR_I(22 downto 1)) then
            busy_cnt := 4;
            pending := ROM_ADDR_I;
        end if;
        if busy_cnt > 0 or (ROM_REQ = '1' and not (presented_valid and presented(22 downto 1) = ROM_ADDR_I(22 downto 1))) then
            ROM_WAIT <= '1';
        else
            ROM_WAIT <= '0';
        end if;
    end if;
end process;

-- S-CPU ROM lane: word for the address of 3 mclk ago
snes_lane : process(CLK)
    variable d1, d2 : std_logic_vector(22 downto 0) := (others => '0');
begin
    if rising_edge(CLK) then
        SNES_ROM_Q_R <= rom_word(rom, d2);
        d2 := d1;
        d1 := SNES_ROM_ADDR_I;
    end if;
end process;

-- BW-RAM port A model (q holds during writes, like bwram_256k)
bw_proc : process(CLK)
begin
    if rising_edge(CLK) then
        if BSRAM_WE_N_I = '0' then
            bwram(to_integer(unsigned(BSRAM_ADDR_I(17 downto 0)))) <= BSRAM_D_I;
        else
            BSRAM_Q_R <= bwram(to_integer(unsigned(BSRAM_ADDR_I(17 downto 0))));
        end if;
    end if;
end process;

stim : process
    variable errs : integer := 0;
    variable checks : integer := 0;

    procedure snes_cycle(a : in std_logic_vector(23 downto 0); wr : in boolean;
                         wd : in std_logic_vector(7 downto 0);
                         rd : out std_logic_vector(7 downto 0)) is
    begin
        for i in 0 to 5 loop
            CA <= a;
            DI <= wd;
            if i = 3 then SYSCLKR_CE <= '1'; else SYSCLKR_CE <= '0'; end if;
            if i = 5 then SYSCLKF_CE <= '1'; else SYSCLKF_CE <= '0'; end if;
            if i >= 3 and not wr then RD_N <= '0'; else RD_N <= '1'; end if;
            if i >= 3 and wr then WR_N <= '0'; else WR_N <= '1'; end if;
            if i = 5 then
                wait for TCLK - 4 ns;
                rd := DO;
            end if;
            wait until rising_edge(CLK);
            wait for 2 ns;
        end loop;
        RD_N <= '1'; WR_N <= '1'; SYSCLKR_CE <= '0'; SYSCLKF_CE <= '0';
    end procedure;

    procedure wr8(a : in integer; d : in integer) is
        variable r : std_logic_vector(7 downto 0);
    begin
        snes_cycle(std_logic_vector(to_unsigned(a, 24)), true,
                   std_logic_vector(to_unsigned(d, 8)), r);
    end procedure;

    procedure rd8(a : in integer; d : out std_logic_vector(7 downto 0)) is
    begin
        snes_cycle(std_logic_vector(to_unsigned(a, 24)), false, x"00", d);
    end procedure;

    procedure expect(a : in integer; want : in integer; name : in string) is
        variable d : std_logic_vector(7 downto 0);
    begin
        rd8(a, d);
        checks := checks + 1;
        if d /= std_logic_vector(to_unsigned(want, 8)) then
            errs := errs + 1;
            report "FAIL " & name & " addr " & to_hstring(std_logic_vector(to_unsigned(a, 24)))
                & ": got " & to_hstring(d) & " want " & to_hstring(std_logic_vector(to_unsigned(want, 8)))
                severity error;
        end if;
    end procedure;

    variable d : std_logic_vector(7 downto 0);
    variable sum : integer;
    variable done : boolean;
begin
    wait until rising_edge(CLK);
    wait for 2 ns;
    RST_N <= '0';
    for i in 0 to 9 loop
        snes_cycle(x"000000", false, x"00", d);
    end loop;
    RST_N <= '1';
    for i in 0 to 3 loop
        snes_cycle(x"000000", false, x"00", d);
    end loop;

    -- S-CPU ROM lane: default map reads the SA-1 program's first byte
    expect(16#008000#, 16#A9#, "snes-rom-lane-default");
    -- live CXB bank map on the S-CPU lane: $00:8000 -> ROM $100000
    wr8(16#2220#, 16#81#);
    expect(16#008000#, 16#5C#, "snes-rom-lane-cxb");
    wr8(16#2220#, 16#00#);
    expect(16#008000#, 16#A9#, "snes-rom-lane-restored");

    -- BW-RAM write enable + seed, I-RAM write enable, SA-1 reset vector
    wr8(16#2226#, 16#80#);          -- SBWE
    wr8(16#2229#, 16#FF#);          -- SIWP
    wr8(16#400100#, 16#41#);        -- seed (also checks the SNES BW write path below)
    wr8(16#2203#, 16#00#);          -- CRV lo
    wr8(16#2204#, 16#80#);          -- CRV hi -> $8000

    -- release the SA-1
    wr8(16#2200#, 16#00#);          -- CCNT: SA1RST=0, SA1WAIT=0

    -- poll CCNT ($2300) low nibble for CMSG=$A
    done := false;
    for n in 0 to 20000 loop
        rd8(16#2300#, d);
        if d(3 downto 0) = x"A" then
            done := true;
            exit;
        end if;
        for i in 0 to 7 loop
            snes_cycle(x"000000", false, x"00", d);
        end loop;
    end loop;
    checks := checks + 1;
    if not done then
        errs := errs + 1;
        report "FAIL sa1-program-done: CMSG never became $A" severity error;
    end if;

    -- multiply -3 * 7 = -21
    expect(16#400000#, 16#EB#, "mul-b0");
    expect(16#400001#, 16#FF#, "mul-b1");
    expect(16#400002#, 16#FF#, "mul-b2");
    expect(16#400003#, 16#FF#, "mul-b3");
    -- divide 1000 / 7 = 142 rem 6
    expect(16#400004#, 16#8E#, "div-q0");
    expect(16#400005#, 16#00#, "div-q1");
    expect(16#400006#, 16#06#, "div-r0");
    expect(16#400007#, 16#00#, "div-r1");
    -- VBP preload: pattern word at ROM $200
    expect(16#400008#, to_integer(unsigned(rom(16#200#))), "vbp-lo");
    expect(16#400009#, to_integer(unsigned(rom(16#201#))), "vbp-hi");
    -- BW-RAM seed read back both ways
    expect(16#400100#, 16#41#, "bw-seed");
    expect(16#400101#, 16#42#, "bw-seed-plus1");
    -- DMA ROM->I-RAM checksum + first bytes (copied on to BW-RAM by the SA-1)
    sum := 0;
    for i in 0 to 15 loop
        sum := (sum + to_integer(unsigned(rom(16#200# + i)))) mod 256;
    end loop;
    expect(16#400102#, sum, "dma-checksum");
    for i in 0 to 3 loop
        expect(16#400104# + i, to_integer(unsigned(rom(16#200# + i))), "dma-byte");
    end loop;
    -- I-RAM pattern through the SNES $3000 window
    expect(16#003010#, 16#DE#, "iram-0");
    expect(16#003011#, 16#AD#, "iram-1");
    expect(16#003012#, 16#BE#, "iram-2");
    expect(16#003013#, 16#EF#, "iram-3");

    report "wait cycles (ROM_WAIT while ROM_REQ): " & integer'image(wait_cycles);
    if errs = 0 then
        report "tb_sa1: PASS (" & integer'image(checks) & " checks)";
    else
        report "tb_sa1: FAIL (" & integer'image(errs) & " of " & integer'image(checks) & " checks)";
    end if;
    finish;
    wait;
end process;

end sim;
