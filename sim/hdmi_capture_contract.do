onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
set lib sim/work_hdmi_capture_contract
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib src/user_source/hdl_source/lane_lvds_10_1.v sim/tb_hdmi_capture_contract.v
vsim -c $lib.tb_hdmi_capture_contract
run -all
quit -f
