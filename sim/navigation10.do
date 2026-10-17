onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
cd sim
vlib work_navigation10
set src ../src/user_source/hdl_source
vlog -sv -work work_navigation10 $src/map_navigation.v tb_navigation10.v
vsim -c work_navigation10.tb_navigation10
run -all
quit -f
