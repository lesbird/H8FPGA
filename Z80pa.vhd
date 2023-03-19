library ieee;
use ieee.std_logic_1164.all;
use  IEEE.STD_LOGIC_ARITH.all;
use  IEEE.STD_LOGIC_UNSIGNED.all;

entity Z80pa is
	generic(
		Mode    : integer := 0; -- 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
		T2Write : integer := 1; -- 0 => WR_n active in T3, /=0 => WR_n active in T2
		IOWait  : integer := 0  -- 0 => Single cycle I/O, 1 => Std I/O cycle
	);
	port(
        RESET_n     : in  std_logic;
        CLKIN       : in  std_logic;
        WAIT_n      : in  std_logic := '1';
        INT_n       : in  std_logic := '1';
        NMI_n       : in  std_logic := '1';
        BUSRQ_n     : in  std_logic := '1';
        M1_n        : out std_logic;
        MREQ_n      : out std_logic;
        IORQ_n      : out std_logic;
        RD_n        : out std_logic;
        WR_n        : out std_logic;
        RFSH_n      : out std_logic;
        HALT_n      : out std_logic;
        BUSAK_n     : out std_logic;
        A           : out std_logic_vector(15 downto 0);
        DI          : in  std_logic_vector(7 downto 0);
        DO          : out std_logic_vector(7 downto 0)
	);
end Z80pa;

architecture struct of Z80pa is
		signal CLOCK				: std_logic;

begin

CPU1 : entity work.T80pa

port map(
		RESET_n	=> RESET_n,
		CLK		=> CLOCK,
		WAIT_n	=> WAIT_n,
		INT_n		=> INT_n,
		NMI_n		=> NMI_n,
		BUSRQ_n	=> BUSRQ_n,
		M1_n		=> M1_n,
		MREQ_n	=> MREQ_n,
		IORQ_n	=> IORQ_n,
		RD_n		=> RD_n,
		WR_n		=> WR_n,
		RFSH_n	=> RFSH_n,
		HALT_n	=> HALT_n,
		BUSAK_n	=> BUSAK_n,
		A			=> A,
		DI			=> DI,
		DO			=> DO
	);

process (CLKIN)
	begin
		CLOCK <= CLKIN;
	end process;
end;
