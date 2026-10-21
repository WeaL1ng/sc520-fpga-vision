# ============================================================
#  run_key_mode_tb.do -- key_mode_ctrl 功能仿真
#
#  用法：
#     cd sim\tb
#     vsim -c -do run_key_mode_tb.do
#
#  或直接：
#     powershell -ExecutionPolicy Bypass -File ..\run_key_tb.ps1
#
#  环境（2026-09-19 实测）：
#     ModelSim ALTERA STARTER EDITION 10.3c  (F:\modelsim\modelsim_ase\win32aloem)
#     **免费版，不需要许可证** —— 原来的 SE 10.1c 需要许可证且已不在本机。
# ============================================================

# 顶层库映射
vmap work ./work

# 重新编译（-refresh 保证源改动生效）
vlib work
vlog -quiet -work work ../../rtl_vendor/anlogic_example/lab_ex4_all_features_SC500_720P/lab_ex4_all_features/user_source/hdl_source/key_mode_ctrl.v
vlog -quiet -work work tb_key_mode_ctrl.v

# 运行（-c 批处理模式；跑完自动退出）
vsim -c -quiet -lib work tb_key_mode_ctrl -do "run -all; quit -f"
