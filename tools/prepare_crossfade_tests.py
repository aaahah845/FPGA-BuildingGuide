from pathlib import Path
R=Path(__file__).resolve().parents[1]
p=R/'sim/tb_photo_full_reader.v'
s=p.read_text(encoding='utf-8')
s=s.replace('reg [2:0] photo_slot=4;', 'reg blend=0,expected_blend=0;\nreg [31:0] overlay_expected;\nreg [2:0] photo_slot=4;')
s=s.replace('.BILINEAR_SUPPORT(1)) dut(', '.BILINEAR_SUPPORT(1),.CROSSFADE_SUPPORT(1)) dut(')
s=s.replace('.panel_height(8\'d210),.photo_full(full),', '.panel_height(8\'d210),.photo_full(full),.photo_blend(blend),')
s=s.replace('function [31:0] pattern;', '''function [15:0] rgb565;
 input [31:0] p;
 begin rgb565={p[31:27],p[23:18],p[15:11]}; end
endfunction
function [31:0] pattern;''')
s=s.replace('if(word!==expected)', '''if(expected_blend) begin
   overlay_expected=32'hf8f7f500;
   if(x>=80 && x<720 && y>=60 && y<540)
    overlay_expected=pattern(expected_photo*307200+(y-60)*640+x-80);
   expected={rgb565(expected),rgb565(overlay_expected)};
  end
  if(word!==expected)''')
s=s.replace('expected_full=(frame==1 || frame==3);', 'expected_full=frame==2;\n  expected_blend=(frame==1 || frame==3);\n  blend=expected_blend;')
s=s.replace('bilinear=expected_full;', 'bilinear=expected_full || expected_blend;')
s=s.replace('full=!expected_full;', 'full=!expected_full; blend=!expected_blend;')
s=s.replace('FRAME_PASS frame=%0d full=%0d map=', 'FRAME_PASS frame=%0d full=%0d map=')
s=s.replace('PASS: photo_full reader 5 frames,', 'PASS: crossfade reader detail/mixed/full/mixed-map/detail 5 frames,')
p.write_text(s,encoding='utf-8')

p=R/'sim/tb_broker_photo_fade.v'
s=p.read_text(encoding='utf-8')
s=s.replace('reg [4:0] previous_alpha=16;', 'reg [4:0] previous_alpha=0;')
s=s.replace('if(photo_view_alpha>16 || photo_view_alpha[0])', 'if(photo_view_alpha>16)')
a=s.index('        if(full!=previous_full) begin')
b=s.index('        if(photo_view_active',a)
s=s[:a]+'''        if(full!=previous_full) mode_changes=mode_changes+1;
        if(full!==(photo_view_alpha==16)) $fatal(1,"full flag disagrees with opacity");
        if(photo_view_active!==(photo_view_alpha!=0)) $fatal(1,"active flag disagrees with opacity");
        if(photo_view_alpha>previous_alpha+1 || previous_alpha>photo_view_alpha+1)
            $fatal(1,"opacity discontinuity");
'''+s[b:]
s=s.replace('photo_view_alpha!==16 || dut.photo_fade_state!==0', 'photo_view_alpha!==(want_full?16:0)')
s=s.replace('full,photo_view_alpha,dut.photo_fade_state', 'full,photo_view_alpha,0')
a=s.index('task wait_black_mode;'); b=s.index('task pulse_next;',a); s=s[:a]+s[b:]
a=s.index('    // A request may arrive before'); b=s.index('    // Autoplay time',a)
s=s[:a]+'''    // A premature request must retain the existing detail view until ready.
    full_requested=1;
    i=0;
    while(panel_height!=210 && i<60) begin
        if(photo_view_alpha!=0) $fatal(1,"fade before detail ready");
        frame; i=i+1;
    end
    settle(1);
    $display("PASS: direct fade waits for loaded photo and fully opened detail");
    full_requested=0; settle(0);
    if(panel_height!=210 || !detail_requested) $fatal(1,"return closed detail");
    $display("PASS: direct return preserves detail and ends at opacity zero");

    full_requested=1; repeat(6) frame;
    if(photo_view_alpha==0 || photo_view_alpha==16) $fatal(1,"missing intermediate blend");
    full_requested=0; settle(0);
    $display("PASS: partial opening reverses continuously to detail");
    full_requested=1; settle(1);
    full_requested=0; repeat(6) frame;
    full_requested=1; settle(1);
    $display("PASS: partial return reverses continuously to full photo");
    full_requested=0; settle(0);

'''+s[b:]
a=s.index('    // Reset is independent'); b=s.index('    $display("PASS: broker photo fade assertions=',a)
s=s[:a]+'''    detail_requested=1; full_requested=1;
    settle(1);
    @(negedge clk); rst=1; full_requested=0;
    repeat(3) tick;
    if(full!==0 || photo_view_alpha!==0 || photo_view_active!==0)
        $fatal(1,"reset failed to restore detail mode");
    previous_alpha=0; previous_full=0;
    @(negedge clk); rst=0;
    repeat(15) frame;
    $display("PASS: reset restores detail with zero photo opacity");
'''+s[b:]
p.write_text(s,encoding='utf-8')

p=R/'sim/tb_photo_compositor.v'
s=p.read_text(encoding='utf-8')
s=s.replace('reg [4:0] alpha=16;', 'reg [4:0] alpha=0;\nreg [15:0] overlay565=0;\nreg [15:0] op[0:5];')
s=s.replace('`PORTS,.I_photo_view_alpha(alpha),', '`PORTS,.I_photo_view_alpha(alpha),.I_photo_rgb565(overlay565),')
s=s.replace('reg [23:0] expected;', '''reg [23:0] expected;
function [23:0] expand565;
 input [15:0] p;
 begin expand565={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]}; end
endfunction
function [23:0] crossfade;
 input [23:0] a,b;
 input [4:0] k;
 integer r,g,bl;
 begin
  r=(a[23:16]*(16-k)+b[23:16]*k)/16;
  g=(a[15:8]*(16-k)+b[15:8]*k)/16;
  bl=(a[7:0]*(16-k)+b[7:0]*k)/16;
  crossfade={r[7:0],g[7:0],bl[7:0]};
 end
endfunction''')
s=s.replace('sp[j]=sp[j-1];', 'sp[j]=sp[j-1];op[j]=op[j-1];')
s=s.replace('sp[0]={de,hs,vs};', 'sp[0]={de,hs,vs};op[0]=overlay565;')
s=s.replace('     expected=darken(expected,alpha);\n', '')
a=s.index('    end else if(alpha==0) begin'); b=s.index('\n   end\n  end',a)
s=s[:a]+'''    end else begin
     expected=alpha==0?reference_rgb:crossfade(reference_rgb,expand565(op[5]),alpha);
     if(rgb!==expected) $fatal(1,"crossfade alpha=%0d xy=%0d,%0d expected=%h got=%h base=%h overlay=%h",alpha,xp[5],yp[5],expected,rgb,reference_rgb,expand565(op[5]));
    end'''+s[b:]
s=s.replace('source_rgb={x[7:0],y[7:0],(x[7:0]^y[7:0])};', '''source_rgb={x[7:0],y[7:0],(x[7:0]^y[7:0])};
    overlay565={~x[4:0],y[5:0],x[4:0]^y[4:0]};''')
# Existing calls now represent opacity of the overlay instead of brightness.
s=s.replace('frame(0,16,0);', 'frame(0,0,0);')
s=s.replace('frame(0,16,1);', 'frame(0,0,1);')
s=s.replace('frame(0,0,0); //', 'frame(0,0,0); //')
s=s.replace('frame(1,0,0);', 'frame(0,1,0);')
s=s.replace('frame(1,8,0);', 'frame(0,8,0);')
s=s.replace('frame(1,8,1);', 'frame(0,15,1);')
p.write_text(s,encoding='utf-8')
print('Crossfade scoreboards prepared.')
