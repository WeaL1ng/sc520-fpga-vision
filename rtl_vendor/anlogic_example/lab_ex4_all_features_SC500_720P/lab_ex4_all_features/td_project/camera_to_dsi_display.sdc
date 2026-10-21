create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]


set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]


# ---------------------------------------------------------------------------
# lab_ex4 additive fix, 2026-09-19 : declare the pll_clk_24m -> HDMI_PIXEL_CLK
# clock-domain crossing as a false path.
#
# WHY
#   The line above puts pll_clk_24m (23.810 MHz, PLL clkc[1]) and HDMI_PIXEL_CLK
#   (75.002 MHz, PLL clkc[4]) in the SAME asynchronous group, i.e. it tells STA
#   to treat them as SYNCHRONOUS to each other.  That was harmless in lab1..lab3
#   because no logic ever crossed between those two clocks.  lab_ex4 adds
#   key_mode_ctrl, whose mode[1:0] is carried into the HDMI pixel domain by a
#   2-FF synchronizer in design_top_wrapper.v, so a
#   "pll_clk_24m -> HDMI_PIXEL_CLK" path group now exists and is analysed as a
#   same-domain setup check.
#
# EVIDENCE (phy_1/camera_to_dsi_display_pr.timing, routed, 2026-09-19 18:36)
#   Path Group : pll_clk_24m -> HDMI_PIXEL_CLK
#   Max        : SWNS -0.111ns, STNS -0.138ns, 2 Viol Endpoints, 3 Total
#   End Point  : S_mode_hdmi_s1_reg[1]   (u_key_mode_ctrl/S_pressed_d_reg[1] launch)
#   Logic Level: 0        Data Path Delay: 0.529ns (cell 0.224 + net 0.305)
#   Budget     : 0.653ns  { HDMI_PIXEL_CLK rising@546.653 - pll_clk_24m rising@546.000 }
#
#   The violation is NOT a slow logic path - it is 0 logic levels and 0.53ns of
#   delay.  It fails purely because STA picked an edge pair only 0.653ns apart
#   from two independent PLL output taps, which have no fixed phase relationship.
#   Every other path group in the design meets timing (30 groups, 0 violations).
#
# WHAT THIS DOES / DOES NOT DO
#   DOES    : removes only the pll_clk_24m -> HDMI_PIXEL_CLK crossing from setup
#             and hold analysis, which is what a CDC synchronizer requires.
#   DOES NOT: touch any same-domain path.  pll_clk_24m -> pll_clk_24m,
#             HDMI_PIXEL_CLK -> HDMI_PIXEL_CLK and HDMI_PIXEL_CLK ->
#             HDMI_SERIAL_CLK all remain fully analysed.
#
#   The crossing is safe because it is a 2-flop synchronizer
#   (S_mode_hdmi_s1 / S_mode_hdmi_s2 in design_top_wrapper.v).  The two bits
#   MUST stay in one synchronizer; do not split them into two.
#
#   Note: key_mode_ctrl's OTHER output, O_btn_ae, stays inside pll_clk_24m and
#   needs no constraint change.  The pll_clk_24m -> MIPI_RX_BYTE_CLK crossing
#   (mode[0] -> isp_top.I_edge_en) is already covered by the clock group line
#   above, which puts pll_clk_24m and MIPI_RX_BYTE_CLK in different groups.
# ---------------------------------------------------------------------------
set_false_path -from [get_clocks {pll_clk_24m}] -to [get_clocks {HDMI_PIXEL_CLK}]
