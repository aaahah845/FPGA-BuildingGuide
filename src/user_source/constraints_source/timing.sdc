
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk 的命名（早期的 audio_mclk / 音频 PLL 已删除，音频节拍由 video_clk 产生）
#
# 当前时钟：clk 50 MHz；sd_card_clk 50 MHz；ext_mem_clk 100 MHz；
#   sys_pll clkc[2] 100 MHz 相移 180°（SDRAM 硬核时钟，未改名）；
#   video_clk 40 MHz；hdmi_5x_clk 200 MHz。
# 第 8 节未给 SDRAM 硬核接口写 input/output delay，工具按默认单周期模型分析，
# 这是报告中 SDRAM 读/写建立违例（−5.565 / −1.894 ns）的直接原因。
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll（已删除，当前工程没有该实例）
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]


# ------------------------------------------------------------
# 4. HDMI pixel and serial clocks run simultaneously from the same PLL.
# Keep their real phase/frequency relationship from derive_clocks. The six-phase
# capture regression and routed single-cycle checks both pass; no exclusive
# grouping or multicycle exception is required here.
# ------------------------------------------------------------

# ------------------------------------------------------------
# 6. 可选：如果你的 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. 精确 CDC 例外
#
# pulse_cdc 的第一级只负责采样异步 toggle；后两级及事件异或仍由目标
# 时钟完整分析。异步 FIFO 自带“异步置位、各侧同步释放”复位链，生成
# 代码的两个复位寄存器都会直接接 rst 异步端，因此只忽略这些复位链
# 寄存器上的异步恢复/撤销检查。Gray 地址同步仍沿用 IP 自带的
# set_max_delay，不进行全局异步时钟分组。
# ------------------------------------------------------------
set_false_path -to [get_regs -nowarn {*/dst_sync[0]}]
set_false_path -to [get_regs -nowarn {*/asy_w_rst*}]
set_false_path -to [get_regs -nowarn {*/asy_r_rst*}]

# ------------------------------------------------------------
# 8. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------

# Removed four stale sampler exceptions: the first three registers have no
# drivers/users in this top; resident_mask is constant and eliminated. Their
# old get_regs patterns matched no physical registers and raised warnings.

# Descriptor is held from video frame request until request release.
set_false_path -to [get_regs -nowarn {*/desc_meta*}]
set_false_path -to [get_regs -nowarn {*/req_sync[0]}]

set_false_path -to [get_regs -nowarn {video_ack_sync[0]}]
set_false_path -to [get_regs -nowarn {reader_fault_sync[0]}]

# Held mailboxes: only asynchronous first sampling stages are exempt.
set_false_path -to [get_regs -nowarn {*/bus_meta*}]
set_false_path -to [get_regs -nowarn {*/toggle_sync[0]}]
set_false_path -to [get_regs -nowarn {cfg_ready_sync[0]}]
set_false_path -to [get_regs -nowarn {background_ready_sync[0]}]
# Existing writer samples the selected slot twice before acknowledging write_req.
# The loader holds the slot throughout file lookup and the entire frame write.
set_false_path -to [get_regs -nowarn {*/write_addr_index_d0*}]

# Verified two-stage single-bit samplers in the experimental top and mailbox.
# Only the first stage is asynchronous; second-stage timing remains analyzed.
set_false_path -to [get_regs -nowarn {prefetch_cancel_sync[0]}]

# Big-map held geometry: only asynchronous first-stage samplers are exempt.
# Write dimensions are established before allocation and held through done.
# Cache metadata is published before response CDC; protected slots are immutable.
set_false_path -to [get_regs -nowarn {*/geometry_meta*}]
set_false_path -to [get_regs -nowarn {*/write_len_d0*}]
# Selection originates in ext_mem_clk and remains timed. Only held SD-domain
# metadata entering the first sampler is asynchronous.
set_false_path -from [get_clocks {sd_card_clk}] -to [get_regs -nowarn {*/source_meta*}]
set_false_path -from [get_clocks {sd_card_clk}] -to [get_regs -nowarn {map_geometry_meta*}]

# Timing-repair copy: held audio-page lengths are sampled twice before the
# third-stage publication enables consumption. Only the first samples are CDC.
set_false_path -from [get_clocks {sd_card_clk}] -to [get_regs -nowarn {*/length0_meta*}]
set_false_path -from [get_clocks {sd_card_clk}] -to [get_regs -nowarn {*/length1_meta*}]
# Human-readable diagnostic status is sampled and stability-filtered at 50 MHz.
set_false_path -to [get_regs -nowarn {diag_code_meta*}]
