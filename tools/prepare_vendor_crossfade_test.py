from pathlib import Path
R=Path(__file__).resolve().parents[1]
p=R/'sim/tb_reader_lockstep.v'
s=p.read_text(encoding='utf-8')
# The non-transition test must use the same parameterization as the top.
s=s.replace('.BILINEAR_SUPPORT(1)) dut(`READER_PORTS,', '.BILINEAR_SUPPORT(1),.CROSSFADE_SUPPORT(1)) dut(`READER_PORTS,.photo_blend(1\'b0),')
p.write_text(s,encoding='utf-8')
s=s.replace('module tb_reader_lockstep;', 'module tb_vendor_crossfade;')
s=s.replace(".photo_blend(1'b0)",".photo_blend(1'b1)")
a=s.index('scene_frame_reader_reference #');b=s.index('// 帧 0~11',a)
s=s[:a]+s[b:]
s=s.replace('if(frame_bilinear && slot>=0 && !full)', 'if(1\'b0 && frame_bilinear && slot>=0 && !full)')
s=s.replace(' if(check_expected && word!==expected)', ''' if(x>=80 && x<720 && y>=60 && y<540)
  p00=pattern(4*307200+(y-60)*640+x-80);
 else p00=32'hf8f7f500;
 expected={expected[31:27],expected[23:18],expected[15:11],p00[31:27],p00[23:18],p00[15:11]};
 if(check_expected && word!==expected)''')
s=s.replace('integer first_frame=0,last_frame=18;', 'integer first_frame=3,last_frame=4;')
s=s.replace(' n=0;consumed=0;req=1;', ' half=210;full=0;motion=0;anim=0;bilinear=1;frame_bilinear=0;\n n=0;consumed=0;req=1;')
s=s.replace('LOCKSTEP FRAME %0d pixels=%0d time_ns=%0t compared_cycles=%0d', 'MIXED_VENDOR_FRAME %0d pixels=%0d time_ns=%0t compared_cycles=%0d')
s=s.replace('PASS: %0d pixels, %0d cycles identical between baseline and timing-fixed reader', 'PASS: %0d mixed pixels with encrypted SDRAM command timing and concurrent writer/refresh, unused_comparison=%0d')
(R/'sim/tb_vendor_crossfade.v').write_text(s,encoding='utf-8')
s=(R/'sim/reader_lockstep.do').read_text(encoding='utf-8')
s=s.replace('sim/work_reader_lockstep','reports/vendor_crossfade/work')
s=s.replace('  sim/scene_frame_reader_reference.v sim/tb_reader_lockstep.v','  sim/tb_vendor_crossfade.v')
s=s.replace('$lib.tb_reader_lockstep','$lib.tb_vendor_crossfade')
(R/'sim/vendor_crossfade.do').write_text(s,encoding='utf-8')
s=(R/'tools/run_direct_read_lockstep_test.py').read_text(encoding='utf-8')
s=s.replace("reports/direct_read_lockstep", "reports/vendor_crossfade")
s=s.replace("else (2, 3)", "else (3, 4)")
s=s.replace("sim/reader_lockstep.do", "sim/vendor_crossfade.do")
s=s.replace("'LOCKSTEP FRAME'", "'MIXED_VENDOR_FRAME'")
s=s.replace("'direct_read_lockstep'", "'vendor_crossfade'")
a=s.index('if first == 2 and last == 3:');b=s.index('print(json.dumps',a)
s=s[:a]+s[b:]
(R/'tools/run_vendor_crossfade_test.py').write_text(s,encoding='utf-8')
print('Vendor timing/refresh/contention test prepared.')
