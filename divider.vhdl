library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.common.all;
use work.decode_types.all;
use work.crhelpers.all;

entity divider is
    port (
        clk   : in std_logic;
        rst   : in std_logic;
        d_in  : in Decode2ToDividerType;
        d_out : out DividerToWritebackType
        );
end entity divider;

architecture behaviour of divider is
    signal dend       : std_ulogic_vector(128 downto 0);
    signal div        : unsigned(63 downto 0);
    signal quot       : std_ulogic_vector(63 downto 0);
    signal result     : std_ulogic_vector(63 downto 0);
    signal sresult    : std_ulogic_vector(63 downto 0);
    signal oresult    : std_ulogic_vector(63 downto 0);
    signal qbit       : std_ulogic;
    signal running    : std_ulogic;
    signal signcheck  : std_ulogic;
    signal count      : unsigned(6 downto 0);
    signal neg_result : std_ulogic;
    signal is_modulus : std_ulogic;
    signal is_32bit   : std_ulogic;
    signal extended   : std_ulogic;
    signal is_signed  : std_ulogic;
    signal rc         : std_ulogic;
    signal write_reg  : std_ulogic_vector(4 downto 0);
    signal overflow   : std_ulogic;
    signal ovf32      : std_ulogic;
    signal did_ovf    : std_ulogic;
    signal cr_data    : std_ulogic_vector(2 downto 0);

begin
    divider_0: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                dend <= (others => '0');
                div <= (others => '0');
                quot <= (others => '0');
                running <= '0';
                count <= "0000000";
            elsif d_in.valid = '1' then
                if d_in.is_extended = '1' and not (d_in.is_signed = '1' and d_in.dividend(63) = '1') then
                    dend <= '0' & d_in.dividend & x"0000000000000000";
                else
                    dend <= '0' & x"0000000000000000" & d_in.dividend;
                end if;
                div <= unsigned(d_in.divisor);
                quot <= (others => '0');
                write_reg <= d_in.write_reg;
                neg_result <= '0';
                is_modulus <= d_in.is_modulus;
                extended <= d_in.is_extended;
                is_32bit <= d_in.is_32bit;
                is_signed <= d_in.is_signed;
                rc <= d_in.rc;
                count <= "1111111";
                running <= '1';
                overflow <= '0';
                ovf32 <= '0';
                signcheck <= d_in.is_signed and (d_in.dividend(63) or d_in.divisor(63));
            elsif signcheck = '1' then
                signcheck <= '0';
                neg_result <= dend(63) xor (div(63) and not is_modulus);
                if dend(63) = '1' then
                    if extended = '1' then
                        dend <= '0' & std_ulogic_vector(- signed(dend(63 downto 0))) & x"0000000000000000";
                    else
                        dend <= '0' & x"0000000000000000" & std_ulogic_vector(- signed(dend(63 downto 0)));
                    end if;
                end if;
                if div(63) = '1' then
                    div <= unsigned(- signed(div));
                end if;
            elsif running = '1' then
                if count = "0111111" then
                    running <= '0';
                end if;
                overflow <= quot(63);
                if dend(128) = '1' or unsigned(dend(127 downto 64)) >= div then
                    ovf32 <= ovf32 or quot(31);
                    dend <= std_ulogic_vector(unsigned(dend(127 downto 64)) - div) &
                            dend(63 downto 0) & '0';
                    quot <= quot(62 downto 0) & '1';
                    count <= count + 1;
                elsif dend(128 downto 57) = x"000000000000000000" and count(6 downto 3) /= "0111" then
                    -- consume 8 bits of zeroes in one cycle
                    ovf32 <= or (ovf32 & quot(31 downto 24));
                    dend <= dend(120 downto 0) & x"00";
                    quot <= quot(55 downto 0) & x"00";
                    count <= count + 8;
                else
                    ovf32 <= ovf32 or quot(31);
                    dend <= dend(127 downto 0) & '0';
                    quot <= quot(62 downto 0) & '0';
                    count <= count + 1;
                end if;
            else
                count <= "0000000";
            end if;
        end if;
    end process;

    divider_1: process(all)
    begin
        d_out.write_reg_nr <= write_reg;
        d_out.write_cr_mask <= num_to_fxm(0);

        if is_modulus = '1' then
            result <= dend(128 downto 65);
        else
            result <= quot;
        end if;
        if neg_result = '1' then
            sresult <= std_ulogic_vector(- signed(result));
        else
            sresult <= result;
        end if;
        did_ovf <= '0';
        if is_32bit = '0' then
            did_ovf <= overflow or (is_signed and (sresult(63) xor neg_result));
        elsif is_signed = '1' then
            if ovf32 = '1' or sresult(32) /= sresult(31) then
                did_ovf <= '1';
            end if;
        else
            did_ovf <= ovf32;
        end if;
        if did_ovf = '1' then
            oresult <= (others => '0');
        elsif (is_32bit = '1') and (is_modulus = '0') then
            -- 32-bit divisions set the top 32 bits of the result to 0
            oresult <= x"00000000" & sresult(31 downto 0);
        else
            oresult <= sresult;
        end if;

        if (did_ovf = '1') or (or (sresult) = '0') then
            cr_data <= "001";
        elsif (sresult(63) = '1') and not ((is_32bit = '1') and (is_modulus = '0')) then
            cr_data <= "100";
        else
            cr_data <= "010";
        end if;
    end process;

    divider_out: process(clk)
    begin
        if rising_edge(clk) then
            d_out.write_reg_data <= oresult;
            d_out.write_cr_data <= cr_data & '0' & x"0000000";
            if count = "1000000" then
                d_out.valid <= '1';
                d_out.write_reg_enable <= '1';
                d_out.write_cr_enable <= rc;
            else
                d_out.valid <= '0';
                d_out.write_reg_enable <= '0';
                d_out.write_cr_enable <= '0';
            end if;
        end if;
    end process;

end architecture behaviour;
