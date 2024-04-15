----------------------------------------------------------------------------------
-- BSD 3-Clause License
-- Copyright (c) 2024, Hirotsugu Okuno
--
-- EzUsb Controller rev. 1.00 (2008/12/05)
-- EzUsb Controller rev. 1.01 (2010/11/02)
--		"Delay = 2" was enabled.
-- EzUsb Controller rev. 1.02 (2011/07/08)
--		CLK timing was optimized.
-- EzUsb Controller rev. 2.00 (2012/07/09)
--		CLK timing was optimized for Spartan 6.
-- EzUsb Controller rev. 2.01 (2013/05/03)
-- 		SLRD was wired for internal ctrl.  
-- EzUsb Controller rev. 2.02 (2013/05/05)
-- 		IMG_ADDR_X, and Y were added.   
-- EzUsb Controller rev. 3.00 (2013/12/21)
-- 		USB_ACTIVE was added.
-- EzUsb Controller rev. 3.10 (2015/10/13)
-- 		Common platform bus was implemented.
--		Source codes were rearranged.
-- EzUsb Controller rev. 3.20 (2021/03/23)
-- 		State Machine was implemented.
-- EzUsb Controller rev. 4.00 (2021/03/26)
-- 		Independent clock rate was enabled.
-- EzUsb Controller rev. 4.10 (2021/04/08)
-- 		Most of FPGA-dependent descriptions were removed.
-- EzUsb Controller rev. 4.20 (2021/04/18)
-- 		CLK interface was separated.
-- EzUsb Controller rev. 4.30 (2021/07/13)
-- 		IOBUF was separated.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity EZUSBctrlv43_QQVGA is
	port(
		CLK				:in		std_logic;
		RESET			:in		std_logic;
		SEND_START		:in		std_logic;
		USB_FLAGB		:in		std_logic;
		USB_FLAGC		:in		std_logic;
		NUM_OF_DATA		:in		std_logic_vector(3 downto 0);
		IMAGE_DATA		:in		std_logic_vector(7 downto 0);
		APPEND_DATA		:in		std_logic_vector(7 downto 0);
		FRAME_NUMBER	:in		std_logic_vector(7 downto 0);
		USB_DIN			:in		std_logic_vector(7 downto 0);
		INIT_BUF		:out	std_logic;
		UPDATE_BUF		:out	std_logic;
		TX_ACTIVE		:out	std_logic;
		RX_ACTIVE		:out	std_logic;
		USB_nRESET		:out	std_logic;
		USB_PKTEND		:out	std_logic;
		USB_SLOE		:out	std_logic;
		USB_SLRD		:out	std_logic;
		USB_SLWR		:out	std_logic;
		IMAGE_NUMBER	:out	std_logic_vector(3 downto 0);
		IMAGE_ADDR		:out	std_logic_vector(16 downto 0);
		APPEND_ADDR		:out	std_logic_vector(8 downto 0);
		RX_WOUT			:out	std_logic_vector(25 downto 0);
		USB_FIFOADDR	:out	std_logic_vector(1 downto 0);
		USB_DOUT		:out	std_logic_vector(7 downto 0)
		);
end EZUSBctrlv43_QQVGA;

architecture Behavioral of EZUSBctrlv43_QQVGA is
	signal		RESET_COUNT			: std_logic_vector(15 downto 0);
	signal		SENDING				: std_logic;
	signal		SENDING_DLY			: std_logic;
	signal		APPEND_DATA_EN		: std_logic;
	signal		APPEND_DATA_EN_PRE	: std_logic_vector(1 downto 0);
	signal		USB_SLWR_IN			: std_logic;
	signal		USB_SLRD_IN			: std_logic;
	signal		USB_PKTEND_IN		: std_logic;
	signal		USB_SLRD_DLY		: std_logic;
	signal		cnt_unit_en			: std_logic;
	signal		cnt_unit_end		: std_logic;
	signal		cnt_unit			: std_logic_vector(11 downto 0);
	signal		FRAME_NUMBER_USBCLK	: std_logic_vector(7 downto 0);
	signal		SEND_DATA			: std_logic_vector(7 downto 0);
	signal		IMG_ADDR			: std_logic_vector(16 downto 0);
	signal		IMG_NUMBER			: std_logic_vector(3 downto 0);
	signal		A_ADDR				: std_logic_vector(8 downto 0);
	signal		R_ADDR				: std_logic_vector(8 downto 0);
	signal		USB_DIN_BUF			: std_logic_vector(7 downto 0);
	signal		BUF_NUMBER			: std_logic_vector(7 downto 0);
	signal		cnt_prepare			: std_logic_vector(3 downto 0);
	constant	cnt_reset_end		: integer := 40;
--	constant	cnt_reset_end		: integer := 8;		-- for debugging
	constant	BufLength			: integer := 512;	-- Size of buffer
	constant	NumOfBuf			: integer := 38;
--	constant	BufLength			: integer := 60;	-- for debugging
--	constant	NumOfBuf			: integer := 4;		-- for debugging
	constant	IntervalLength		: integer := 8;
	constant	DataLength			: integer := 19200;
--	constant	DataLength			: integer := 200;	-- for debugging
	constant	cnt_prepare_end		: integer := 8;
	constant	HeaderLength		: integer := 4;
	constant	Delay				: integer := 1; -- 0 or 1 or 2
	
	-- USB state machine ---------------------------------------------------
	signal		state_usb			: std_logic_vector(2 downto 0);
	constant	INIT_USB			: std_logic_vector(2 downto 0) := "000";
	constant	RECEIVE				: std_logic_vector(2 downto 0) := "001";
	constant	PREPARE_BUF			: std_logic_vector(2 downto 0) := "010";
	constant	WAIT_FLAGB			: std_logic_vector(2 downto 0) := "011";
	constant	WRITE_BUF			: std_logic_vector(2 downto 0) := "100";
	
begin
	
---- Initializing --------------------------------------------------------------
	process(CLK, RESET) begin
		if(RESET = '1') then
			RESET_COUNT <= (others => '0');
		elsif(rising_edge(CLK)) then
			if(RESET_COUNT < cnt_reset_end) then
				RESET_COUNT <= RESET_COUNT + 1;
			end if;
		end if;
	end process;

	USB_nRESET <=	'1' when RESET_COUNT = cnt_reset_end else
					'0';
--------------------------------------------------------------------------------

---- State Machine for TX ------------------------------------------------------
	process(CLK, RESET) begin
		if(RESET = '1') then
			state_usb <= INIT_USB;
		elsif(rising_edge(CLK)) then
			case state_usb is
				when INIT_USB =>
					if(USB_DIN_BUF = 255 and R_ADDR = 0) then
						state_usb <= RECEIVE;
					end if;
				when RECEIVE =>
					if(SEND_START = '1') then
						state_usb <= PREPARE_BUF;
					end if;
				when PREPARE_BUF =>					
					if(cnt_prepare = cnt_prepare_end - 1) then
						state_usb <= WAIT_FLAGB;
					end if;
				when WAIT_FLAGB =>					
					if(USB_FLAGB = '1') then
						state_usb <= WRITE_BUF;
					end if;
				when WRITE_BUF =>
					if(cnt_unit = BufLength + IntervalLength - 1) then
						if(BUF_NUMBER = NumOfBuf - 1 and IMG_NUMBER = NUM_OF_DATA - 1) then
							state_usb <= RECEIVE;
						elsif(BUF_NUMBER = NumOfBuf - 1) then
							state_usb <= PREPARE_BUF;
						else
							state_usb <= WAIT_FLAGB;
						end if;
					end if;
				when others =>
					state_usb <= RECEIVE;
			end case;
		end if;
	end process;
	
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb /= RECEIVE and state_usb /= INIT_USB) then
				SENDING <= '1';
			else
				SENDING <= '0';
			end if;
		end if;
	end process;
	TX_ACTIVE <= SENDING;
	
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb /= WRITE_BUF or cnt_unit = BufLength) then
				USB_SLWR_IN <= '1';
			elsif(cnt_unit = 0) then
				USB_SLWR_IN <= '0';
			end if;
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(cnt_unit = BufLength + IntervalLength - 5) then
				USB_PKTEND_IN <= '0';
			else
				USB_PKTEND_IN <= '1';
			end if;
		end if;
	end process;

	USB_FIFOADDR <= "10" when SENDING = '1' else 	-- EP6
					"00"; 							-- EP2
--------------------------------------------------------------------------------

---- Counters for TX -----------------------------------------------------------
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb /= PREPARE_BUF) then
				cnt_prepare <= (others => '0');
			else
				cnt_prepare <= cnt_prepare + 1;
			end if;
		end if;
	end process;

	process(CLK, RESET) begin
		if(rising_edge(CLK)) then
			if(state_usb /= WRITE_BUF) then
				cnt_unit <= (others => '0');
			else
				cnt_unit <= cnt_unit + 1;
			end if;
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(cnt_unit = BufLength + IntervalLength - 2) then
				cnt_unit_end <= '1';
			else
				cnt_unit_end <= '0';
			end if;
		end if;
	end process;
	
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb = RECEIVE) then
				BUF_NUMBER <= (others => '0');
			elsif(cnt_unit_end = '1') then
				if(BUF_NUMBER = NumOfBuf - 1) then
					BUF_NUMBER <= (others => '0');
				else
					BUF_NUMBER <= BUF_NUMBER + 1;
				end if;
			end if;				
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb = RECEIVE or APPEND_DATA_EN = '1') then
				IMG_ADDR <= (others => '0');
			elsif((cnt_unit > HeaderLength - Delay - 1) and
					(cnt_unit < BufLength - Delay)) then
				if(IMG_ADDR = DataLength - 1) then
					IMG_ADDR <= (others => '0');
				else
					IMG_ADDR <= IMG_ADDR + 1;
				end if;
			end if;				
		end if;
	end process;
	IMAGE_ADDR <= IMG_ADDR;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb = RECEIVE) then
				IMG_NUMBER <= (others => '0');
			elsif(cnt_unit_end = '1' and BUF_NUMBER = NumOfBuf - 1) then
				IMG_NUMBER <= IMG_NUMBER + 1;
			end if;				
		end if;
	end process;
	IMAGE_NUMBER <= IMG_NUMBER;
--------------------------------------------------------------------------------

---- Append data ---------------------------------------------------------------
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb /= WRITE_BUF) then
				APPEND_DATA_EN_PRE(0) <= '0';
			elsif(IMG_ADDR = DataLength - 3 + Delay) then
				APPEND_DATA_EN_PRE(0) <= '1';
			end if;
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			APPEND_DATA_EN_PRE(1) <= APPEND_DATA_EN_PRE(0);
			APPEND_DATA_EN <= APPEND_DATA_EN_PRE(1);
		end if;
	end process;	
	
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(APPEND_DATA_EN_PRE(1) = '0') then
				A_ADDR <= (others => '0');
			else
				A_ADDR <= A_ADDR + 1;
			end if;				
		end if;
	end process;
	APPEND_ADDR <= A_ADDR;
--------------------------------------------------------------------------------

---- Signals for USB Buffer ----------------------------------------------------
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb = PREPARE_BUF and cnt_prepare = 0) then
				INIT_BUF <= '1';
			else
				INIT_BUF <= '0';
			end if;
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb = WRITE_BUF and IMG_ADDR(2 downto 0) = "001") then
				UPDATE_BUF <= '1';
			else
				UPDATE_BUF <= '0';
			end if;
		end if;
	end process;
--------------------------------------------------------------------------------

---- TX data -------------------------------------------------------------------
	process(CLK) begin
		if(rising_edge(CLK)) then
			case cnt_unit is
				when "000000000000"	=> USB_DOUT <= BUF_NUMBER;
				when "000000000001"	=> USB_DOUT <= "0000" & IMG_NUMBER;
				when "000000000010"	=> USB_DOUT <= FRAME_NUMBER_USBCLK;
				when "000000000011"	=> USB_DOUT <= "0000" & NUM_OF_DATA;
				when others			=> USB_DOUT <= SEND_DATA;
			end case;				
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(SEND_START = '1') then
				FRAME_NUMBER_USBCLK <= FRAME_NUMBER;
			end if;
		end if;
	end process;
	
	SEND_DATA <= 	IMAGE_DATA when APPEND_DATA_EN = '0' else
					APPEND_DATA;
--------------------------------------------------------------------------------

---- Signals for RX ------------------------------------------------------------
	process(CLK) begin
		if(rising_edge(CLK)) then
			SENDING_DLY <= SENDING;
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(SENDING = '1' or SENDING_DLY = '1' or IMG_ADDR = BufLength - 1) then
				USB_SLRD_IN <= '1';
			elsif(USB_FLAGC = '1') then
				USB_SLRD_IN <= '0';
			else
				USB_SLRD_IN <= '1';
			end if;				
		end if;
	end process;
	
	process(CLK) begin
		if(rising_edge(CLK)) then
			USB_SLRD_DLY <= USB_SLRD_IN;
		end if;
	end process;
	
	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb /= RECEIVE) then		-- ver.3
				R_ADDR <= (others => '0');
			elsif(USB_SLRD_DLY = '0') then
				R_ADDR <= R_ADDR + 1;
			end if;				
		end if;
	end process;

	process(CLK) begin
		if(rising_edge(CLK)) then
			if(state_usb = INIT_USB or state_usb = RECEIVE) then
				USB_DIN_BUF <= USB_DIN;
			else
				USB_DIN_BUF <= (others => '0');
			end if;
		end if;
	end process;

	RX_ACTIVE <= not USB_SLRD_IN;
	RX_WOUT <= USB_DIN_BUF & "00000000" & R_ADDR & not USB_SLRD_IN;
--------------------------------------------------------------------------------

---- Output port ---------------------------------------------------------------
	USB_SLRD <= USB_SLRD_IN;
	USB_SLWR <= USB_SLWR_IN;
	USB_SLOE <= SENDING;
	USB_PKTEND <= USB_PKTEND_IN;
--------------------------------------------------------------------------------

end Behavioral;
