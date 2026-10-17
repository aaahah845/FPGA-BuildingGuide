onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
set lib sim/work_shared_input_timing
if {![file exists $lib]} {vlib $lib}
set src src/user_source/hdl_source
vlog -sv -work $lib +incdir+$src $src/guide_key_control.v $src/direction_key_event.v sim/tb_shared_input_timing.v
vsim -c $lib.tb_shared_input_timing
run -all
quit -f
