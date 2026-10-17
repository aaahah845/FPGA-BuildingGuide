# 读控制器时序修正：与改名版逐拍等价测试。在本副本根目录运行：
#   vsim -c -do sim/reader_lockstep.do
# 可用环境变量 FIRST_FRAME / LAST_FRAME 只跑部分帧。
onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
set lib reports/vendor_crossfade/work
if {![file exists $lib]} {vlib $lib}
set src src/user_source/hdl_source
vlog -sv -permissive +define+SIMULATION -work $lib +incdir+src/td_project +incdir+$src/include +incdir+$src +incdir+$src/SD \
  $src/include/sdr_as_ram.enc.v $src/include/sdr_init_ref.enc.v $src/include/sdr_wrrd.enc.v \
  $src/SD/sdram_refresh_guard.v $src/SD/frame_fifo_write.v $src/SD/scene_frame_reader.v \
  sim/tb_vendor_crossfade.v
if {[info exists env(COMPILE_ONLY)]} {quit -f}
set args {}
if {[info exists env(FIRST_FRAME)]} {lappend args +FIRST_FRAME=$env(FIRST_FRAME)}
if {[info exists env(LAST_FRAME)]} {lappend args +LAST_FRAME=$env(LAST_FRAME)}
eval vsim -c $lib.tb_vendor_crossfade $args
run -all
quit -f
