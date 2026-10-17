onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
cd sim
set lib work_direction_control
if {![file exists $lib]} {vlib $lib}
set src ../src/user_source/hdl_source
vlog -sv -work $lib +incdir+$src $src/guide_key_control.v $src/guide_scene_control.v tb_direction_control.v
vsim -c $lib.tb_direction_control
run -all
quit -f
