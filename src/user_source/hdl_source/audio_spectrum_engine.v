`ifndef AUDIO_SPECTRUM_ENGINE_V
`define AUDIO_SPECTRUM_ENGINE_V
// 512-point real-input radix-2 FFT. One shared signed 16x16 multiplier.
// Samples are Bartlett-windowed, bit-reversed on capture; each stage /2.
// Work RAM 512x32 (2 BRAM), twiddles 512x16 (1 BRAM).
// Analysis capture pauses during FFT; playback is never stalled.
// ============================================================================
// audio_spectrum_engine：音频频谱分析（video_clk）
//   state 0~2   采集：每个 pcm_valid 取左声道高 16 位，乘 Bartlett 窗系数，
//               按位倒序地址写入 mem；512 点约 10.7 ms
//   state 4~18  蝶形：9 级 radix-2，每个蝶形读 a、b 两点与旋转因子，
//               共用一个 16×16 乘法器分 4 次完成复数乘，结果每级 /2
//   state 19~24 频带：bin 1~255 的幅度近似为 max+min/2，按 band_end 表归并成
//               64 个频带取峰值，再按 db_height 表换算为 0~23 的柱高（约 3 dB/格）
//   state 21    翻转 published_bank，双缓冲发布结果
// 每个 bin 宽 48000/512 = 93.75 Hz。计算期间暂停采集，不影响音频播放。
// ============================================================================
module audio_spectrum_engine(
    input clk,rst,pcm_valid,
    input signed [23:0] pcm_left,
    input [6:0] level_address,
    output [4:0] level_value,
    output reg published_bank,
    output reg result_valid
);
(* syn_ramstyle="distributed_ram" *) reg [4:0] spectrum_heights[0:127];
assign level_value=spectrum_heights[level_address];

(* syn_ramstyle="block_ram" *) reg [31:0] mem[0:511];
(* syn_romstyle="block_rom" *) reg [15:0] twiddle[0:511];
// reflow:off  旋转因子表：偶数项 cos、奇数项 −sin，Q15，共 256 组
 initial begin
  twiddle[0]=16'h7fff; twiddle[1]=16'h0000;
  twiddle[2]=16'h7ffd; twiddle[3]=16'hfe6e;
  twiddle[4]=16'h7ff5; twiddle[5]=16'hfcdc;
  twiddle[6]=16'h7fe9; twiddle[7]=16'hfb4a;
  twiddle[8]=16'h7fd8; twiddle[9]=16'hf9b8;
  twiddle[10]=16'h7fc1; twiddle[11]=16'hf827;
  twiddle[12]=16'h7fa6; twiddle[13]=16'hf696;
  twiddle[14]=16'h7f86; twiddle[15]=16'hf505;
  twiddle[16]=16'h7f61; twiddle[17]=16'hf374;
  twiddle[18]=16'h7f37; twiddle[19]=16'hf1e4;
  twiddle[20]=16'h7f09; twiddle[21]=16'hf055;
  twiddle[22]=16'h7ed5; twiddle[23]=16'heec6;
  twiddle[24]=16'h7e9c; twiddle[25]=16'hed38;
  twiddle[26]=16'h7e5f; twiddle[27]=16'hebab;
  twiddle[28]=16'h7e1d; twiddle[29]=16'hea1e;
  twiddle[30]=16'h7dd5; twiddle[31]=16'he892;
  twiddle[32]=16'h7d89; twiddle[33]=16'he707;
  twiddle[34]=16'h7d39; twiddle[35]=16'he57e;
  twiddle[36]=16'h7ce3; twiddle[37]=16'he3f5;
  twiddle[38]=16'h7c88; twiddle[39]=16'he26d;
  twiddle[40]=16'h7c29; twiddle[41]=16'he0e6;
  twiddle[42]=16'h7bc5; twiddle[43]=16'hdf61;
  twiddle[44]=16'h7b5c; twiddle[45]=16'hdddd;
  twiddle[46]=16'h7aee; twiddle[47]=16'hdc5a;
  twiddle[48]=16'h7a7c; twiddle[49]=16'hdad8;
  twiddle[50]=16'h7a05; twiddle[51]=16'hd958;
  twiddle[52]=16'h7989; twiddle[53]=16'hd7da;
  twiddle[54]=16'h7909; twiddle[55]=16'hd65d;
  twiddle[56]=16'h7884; twiddle[57]=16'hd4e1;
  twiddle[58]=16'h77fa; twiddle[59]=16'hd367;
  twiddle[60]=16'h776b; twiddle[61]=16'hd1ef;
  twiddle[62]=16'h76d8; twiddle[63]=16'hd079;
  twiddle[64]=16'h7641; twiddle[65]=16'hcf05;
  twiddle[66]=16'h75a5; twiddle[67]=16'hcd92;
  twiddle[68]=16'h7504; twiddle[69]=16'hcc21;
  twiddle[70]=16'h745f; twiddle[71]=16'hcab3;
  twiddle[72]=16'h73b5; twiddle[73]=16'hc946;
  twiddle[74]=16'h7307; twiddle[75]=16'hc7dc;
  twiddle[76]=16'h7254; twiddle[77]=16'hc674;
  twiddle[78]=16'h719d; twiddle[79]=16'hc50e;
  twiddle[80]=16'h70e2; twiddle[81]=16'hc3aa;
  twiddle[82]=16'h7022; twiddle[83]=16'hc248;
  twiddle[84]=16'h6f5e; twiddle[85]=16'hc0e9;
  twiddle[86]=16'h6e96; twiddle[87]=16'hbf8d;
  twiddle[88]=16'h6dc9; twiddle[89]=16'hbe32;
  twiddle[90]=16'h6cf8; twiddle[91]=16'hbcdb;
  twiddle[92]=16'h6c23; twiddle[93]=16'hbb86;
  twiddle[94]=16'h6b4a; twiddle[95]=16'hba33;
  twiddle[96]=16'h6a6d; twiddle[97]=16'hb8e4;
  twiddle[98]=16'h698b; twiddle[99]=16'hb797;
  twiddle[100]=16'h68a6; twiddle[101]=16'hb64c;
  twiddle[102]=16'h67bc; twiddle[103]=16'hb505;
  twiddle[104]=16'h66cf; twiddle[105]=16'hb3c1;
  twiddle[106]=16'h65dd; twiddle[107]=16'hb27f;
  twiddle[108]=16'h64e8; twiddle[109]=16'hb141;
  twiddle[110]=16'h63ee; twiddle[111]=16'hb005;
  twiddle[112]=16'h62f1; twiddle[113]=16'haecd;
  twiddle[114]=16'h61f0; twiddle[115]=16'had98;
  twiddle[116]=16'h60eb; twiddle[117]=16'hac65;
  twiddle[118]=16'h5fe3; twiddle[119]=16'hab37;
  twiddle[120]=16'h5ed7; twiddle[121]=16'haa0b;
  twiddle[122]=16'h5dc7; twiddle[123]=16'ha8e3;
  twiddle[124]=16'h5cb3; twiddle[125]=16'ha7be;
  twiddle[126]=16'h5b9c; twiddle[127]=16'ha69c;
  twiddle[128]=16'h5a82; twiddle[129]=16'ha57e;
  twiddle[130]=16'h5964; twiddle[131]=16'ha464;
  twiddle[132]=16'h5842; twiddle[133]=16'ha34d;
  twiddle[134]=16'h571d; twiddle[135]=16'ha239;
  twiddle[136]=16'h55f5; twiddle[137]=16'ha129;
  twiddle[138]=16'h54c9; twiddle[139]=16'ha01d;
  twiddle[140]=16'h539b; twiddle[141]=16'h9f15;
  twiddle[142]=16'h5268; twiddle[143]=16'h9e10;
  twiddle[144]=16'h5133; twiddle[145]=16'h9d0f;
  twiddle[146]=16'h4ffb; twiddle[147]=16'h9c12;
  twiddle[148]=16'h4ebf; twiddle[149]=16'h9b18;
  twiddle[150]=16'h4d81; twiddle[151]=16'h9a23;
  twiddle[152]=16'h4c3f; twiddle[153]=16'h9931;
  twiddle[154]=16'h4afb; twiddle[155]=16'h9844;
  twiddle[156]=16'h49b4; twiddle[157]=16'h975a;
  twiddle[158]=16'h4869; twiddle[159]=16'h9675;
  twiddle[160]=16'h471c; twiddle[161]=16'h9593;
  twiddle[162]=16'h45cd; twiddle[163]=16'h94b6;
  twiddle[164]=16'h447a; twiddle[165]=16'h93dd;
  twiddle[166]=16'h4325; twiddle[167]=16'h9308;
  twiddle[168]=16'h41ce; twiddle[169]=16'h9237;
  twiddle[170]=16'h4073; twiddle[171]=16'h916a;
  twiddle[172]=16'h3f17; twiddle[173]=16'h90a2;
  twiddle[174]=16'h3db8; twiddle[175]=16'h8fde;
  twiddle[176]=16'h3c56; twiddle[177]=16'h8f1e;
  twiddle[178]=16'h3af2; twiddle[179]=16'h8e63;
  twiddle[180]=16'h398c; twiddle[181]=16'h8dac;
  twiddle[182]=16'h3824; twiddle[183]=16'h8cf9;
  twiddle[184]=16'h36ba; twiddle[185]=16'h8c4b;
  twiddle[186]=16'h354d; twiddle[187]=16'h8ba1;
  twiddle[188]=16'h33df; twiddle[189]=16'h8afc;
  twiddle[190]=16'h326e; twiddle[191]=16'h8a5b;
  twiddle[192]=16'h30fb; twiddle[193]=16'h89bf;
  twiddle[194]=16'h2f87; twiddle[195]=16'h8928;
  twiddle[196]=16'h2e11; twiddle[197]=16'h8895;
  twiddle[198]=16'h2c99; twiddle[199]=16'h8806;
  twiddle[200]=16'h2b1f; twiddle[201]=16'h877c;
  twiddle[202]=16'h29a3; twiddle[203]=16'h86f7;
  twiddle[204]=16'h2826; twiddle[205]=16'h8677;
  twiddle[206]=16'h26a8; twiddle[207]=16'h85fb;
  twiddle[208]=16'h2528; twiddle[209]=16'h8584;
  twiddle[210]=16'h23a6; twiddle[211]=16'h8512;
  twiddle[212]=16'h2223; twiddle[213]=16'h84a4;
  twiddle[214]=16'h209f; twiddle[215]=16'h843b;
  twiddle[216]=16'h1f1a; twiddle[217]=16'h83d7;
  twiddle[218]=16'h1d93; twiddle[219]=16'h8378;
  twiddle[220]=16'h1c0b; twiddle[221]=16'h831d;
  twiddle[222]=16'h1a82; twiddle[223]=16'h82c7;
  twiddle[224]=16'h18f9; twiddle[225]=16'h8277;
  twiddle[226]=16'h176e; twiddle[227]=16'h822b;
  twiddle[228]=16'h15e2; twiddle[229]=16'h81e3;
  twiddle[230]=16'h1455; twiddle[231]=16'h81a1;
  twiddle[232]=16'h12c8; twiddle[233]=16'h8164;
  twiddle[234]=16'h113a; twiddle[235]=16'h812b;
  twiddle[236]=16'h0fab; twiddle[237]=16'h80f7;
  twiddle[238]=16'h0e1c; twiddle[239]=16'h80c9;
  twiddle[240]=16'h0c8c; twiddle[241]=16'h809f;
  twiddle[242]=16'h0afb; twiddle[243]=16'h807a;
  twiddle[244]=16'h096a; twiddle[245]=16'h805a;
  twiddle[246]=16'h07d9; twiddle[247]=16'h803f;
  twiddle[248]=16'h0648; twiddle[249]=16'h8028;
  twiddle[250]=16'h04b6; twiddle[251]=16'h8017;
  twiddle[252]=16'h0324; twiddle[253]=16'h800b;
  twiddle[254]=16'h0192; twiddle[255]=16'h8003;
  twiddle[256]=16'h0000; twiddle[257]=16'h8001;
  twiddle[258]=16'hfe6e; twiddle[259]=16'h8003;
  twiddle[260]=16'hfcdc; twiddle[261]=16'h800b;
  twiddle[262]=16'hfb4a; twiddle[263]=16'h8017;
  twiddle[264]=16'hf9b8; twiddle[265]=16'h8028;
  twiddle[266]=16'hf827; twiddle[267]=16'h803f;
  twiddle[268]=16'hf696; twiddle[269]=16'h805a;
  twiddle[270]=16'hf505; twiddle[271]=16'h807a;
  twiddle[272]=16'hf374; twiddle[273]=16'h809f;
  twiddle[274]=16'hf1e4; twiddle[275]=16'h80c9;
  twiddle[276]=16'hf055; twiddle[277]=16'h80f7;
  twiddle[278]=16'heec6; twiddle[279]=16'h812b;
  twiddle[280]=16'hed38; twiddle[281]=16'h8164;
  twiddle[282]=16'hebab; twiddle[283]=16'h81a1;
  twiddle[284]=16'hea1e; twiddle[285]=16'h81e3;
  twiddle[286]=16'he892; twiddle[287]=16'h822b;
  twiddle[288]=16'he707; twiddle[289]=16'h8277;
  twiddle[290]=16'he57e; twiddle[291]=16'h82c7;
  twiddle[292]=16'he3f5; twiddle[293]=16'h831d;
  twiddle[294]=16'he26d; twiddle[295]=16'h8378;
  twiddle[296]=16'he0e6; twiddle[297]=16'h83d7;
  twiddle[298]=16'hdf61; twiddle[299]=16'h843b;
  twiddle[300]=16'hdddd; twiddle[301]=16'h84a4;
  twiddle[302]=16'hdc5a; twiddle[303]=16'h8512;
  twiddle[304]=16'hdad8; twiddle[305]=16'h8584;
  twiddle[306]=16'hd958; twiddle[307]=16'h85fb;
  twiddle[308]=16'hd7da; twiddle[309]=16'h8677;
  twiddle[310]=16'hd65d; twiddle[311]=16'h86f7;
  twiddle[312]=16'hd4e1; twiddle[313]=16'h877c;
  twiddle[314]=16'hd367; twiddle[315]=16'h8806;
  twiddle[316]=16'hd1ef; twiddle[317]=16'h8895;
  twiddle[318]=16'hd079; twiddle[319]=16'h8928;
  twiddle[320]=16'hcf05; twiddle[321]=16'h89bf;
  twiddle[322]=16'hcd92; twiddle[323]=16'h8a5b;
  twiddle[324]=16'hcc21; twiddle[325]=16'h8afc;
  twiddle[326]=16'hcab3; twiddle[327]=16'h8ba1;
  twiddle[328]=16'hc946; twiddle[329]=16'h8c4b;
  twiddle[330]=16'hc7dc; twiddle[331]=16'h8cf9;
  twiddle[332]=16'hc674; twiddle[333]=16'h8dac;
  twiddle[334]=16'hc50e; twiddle[335]=16'h8e63;
  twiddle[336]=16'hc3aa; twiddle[337]=16'h8f1e;
  twiddle[338]=16'hc248; twiddle[339]=16'h8fde;
  twiddle[340]=16'hc0e9; twiddle[341]=16'h90a2;
  twiddle[342]=16'hbf8d; twiddle[343]=16'h916a;
  twiddle[344]=16'hbe32; twiddle[345]=16'h9237;
  twiddle[346]=16'hbcdb; twiddle[347]=16'h9308;
  twiddle[348]=16'hbb86; twiddle[349]=16'h93dd;
  twiddle[350]=16'hba33; twiddle[351]=16'h94b6;
  twiddle[352]=16'hb8e4; twiddle[353]=16'h9593;
  twiddle[354]=16'hb797; twiddle[355]=16'h9675;
  twiddle[356]=16'hb64c; twiddle[357]=16'h975a;
  twiddle[358]=16'hb505; twiddle[359]=16'h9844;
  twiddle[360]=16'hb3c1; twiddle[361]=16'h9931;
  twiddle[362]=16'hb27f; twiddle[363]=16'h9a23;
  twiddle[364]=16'hb141; twiddle[365]=16'h9b18;
  twiddle[366]=16'hb005; twiddle[367]=16'h9c12;
  twiddle[368]=16'haecd; twiddle[369]=16'h9d0f;
  twiddle[370]=16'had98; twiddle[371]=16'h9e10;
  twiddle[372]=16'hac65; twiddle[373]=16'h9f15;
  twiddle[374]=16'hab37; twiddle[375]=16'ha01d;
  twiddle[376]=16'haa0b; twiddle[377]=16'ha129;
  twiddle[378]=16'ha8e3; twiddle[379]=16'ha239;
  twiddle[380]=16'ha7be; twiddle[381]=16'ha34d;
  twiddle[382]=16'ha69c; twiddle[383]=16'ha464;
  twiddle[384]=16'ha57e; twiddle[385]=16'ha57e;
  twiddle[386]=16'ha464; twiddle[387]=16'ha69c;
  twiddle[388]=16'ha34d; twiddle[389]=16'ha7be;
  twiddle[390]=16'ha239; twiddle[391]=16'ha8e3;
  twiddle[392]=16'ha129; twiddle[393]=16'haa0b;
  twiddle[394]=16'ha01d; twiddle[395]=16'hab37;
  twiddle[396]=16'h9f15; twiddle[397]=16'hac65;
  twiddle[398]=16'h9e10; twiddle[399]=16'had98;
  twiddle[400]=16'h9d0f; twiddle[401]=16'haecd;
  twiddle[402]=16'h9c12; twiddle[403]=16'hb005;
  twiddle[404]=16'h9b18; twiddle[405]=16'hb141;
  twiddle[406]=16'h9a23; twiddle[407]=16'hb27f;
  twiddle[408]=16'h9931; twiddle[409]=16'hb3c1;
  twiddle[410]=16'h9844; twiddle[411]=16'hb505;
  twiddle[412]=16'h975a; twiddle[413]=16'hb64c;
  twiddle[414]=16'h9675; twiddle[415]=16'hb797;
  twiddle[416]=16'h9593; twiddle[417]=16'hb8e4;
  twiddle[418]=16'h94b6; twiddle[419]=16'hba33;
  twiddle[420]=16'h93dd; twiddle[421]=16'hbb86;
  twiddle[422]=16'h9308; twiddle[423]=16'hbcdb;
  twiddle[424]=16'h9237; twiddle[425]=16'hbe32;
  twiddle[426]=16'h916a; twiddle[427]=16'hbf8d;
  twiddle[428]=16'h90a2; twiddle[429]=16'hc0e9;
  twiddle[430]=16'h8fde; twiddle[431]=16'hc248;
  twiddle[432]=16'h8f1e; twiddle[433]=16'hc3aa;
  twiddle[434]=16'h8e63; twiddle[435]=16'hc50e;
  twiddle[436]=16'h8dac; twiddle[437]=16'hc674;
  twiddle[438]=16'h8cf9; twiddle[439]=16'hc7dc;
  twiddle[440]=16'h8c4b; twiddle[441]=16'hc946;
  twiddle[442]=16'h8ba1; twiddle[443]=16'hcab3;
  twiddle[444]=16'h8afc; twiddle[445]=16'hcc21;
  twiddle[446]=16'h8a5b; twiddle[447]=16'hcd92;
  twiddle[448]=16'h89bf; twiddle[449]=16'hcf05;
  twiddle[450]=16'h8928; twiddle[451]=16'hd079;
  twiddle[452]=16'h8895; twiddle[453]=16'hd1ef;
  twiddle[454]=16'h8806; twiddle[455]=16'hd367;
  twiddle[456]=16'h877c; twiddle[457]=16'hd4e1;
  twiddle[458]=16'h86f7; twiddle[459]=16'hd65d;
  twiddle[460]=16'h8677; twiddle[461]=16'hd7da;
  twiddle[462]=16'h85fb; twiddle[463]=16'hd958;
  twiddle[464]=16'h8584; twiddle[465]=16'hdad8;
  twiddle[466]=16'h8512; twiddle[467]=16'hdc5a;
  twiddle[468]=16'h84a4; twiddle[469]=16'hdddd;
  twiddle[470]=16'h843b; twiddle[471]=16'hdf61;
  twiddle[472]=16'h83d7; twiddle[473]=16'he0e6;
  twiddle[474]=16'h8378; twiddle[475]=16'he26d;
  twiddle[476]=16'h831d; twiddle[477]=16'he3f5;
  twiddle[478]=16'h82c7; twiddle[479]=16'he57e;
  twiddle[480]=16'h8277; twiddle[481]=16'he707;
  twiddle[482]=16'h822b; twiddle[483]=16'he892;
  twiddle[484]=16'h81e3; twiddle[485]=16'hea1e;
  twiddle[486]=16'h81a1; twiddle[487]=16'hebab;
  twiddle[488]=16'h8164; twiddle[489]=16'hed38;
  twiddle[490]=16'h812b; twiddle[491]=16'heec6;
  twiddle[492]=16'h80f7; twiddle[493]=16'hf055;
  twiddle[494]=16'h80c9; twiddle[495]=16'hf1e4;
  twiddle[496]=16'h809f; twiddle[497]=16'hf374;
  twiddle[498]=16'h807a; twiddle[499]=16'hf505;
  twiddle[500]=16'h805a; twiddle[501]=16'hf696;
  twiddle[502]=16'h803f; twiddle[503]=16'hf827;
  twiddle[504]=16'h8028; twiddle[505]=16'hf9b8;
  twiddle[506]=16'h8017; twiddle[507]=16'hfb4a;
  twiddle[508]=16'h800b; twiddle[509]=16'hfcdc;
  twiddle[510]=16'h8003; twiddle[511]=16'hfe6e;
 end
 // reflow:on
reg [31:0] mem_q;
reg signed [15:0] tw_q,tw_cos,tw_sin;
reg [4:0] state;
reg [8:0] capture_index,base,j,half_size,tw_index,tw_step,scan_bin;
reg [3:0] stage;
reg [5:0] band;
reg signed [15:0] ar,ai,br,bi,mul_a,mul_b;
reg signed [31:0] product;
reg signed [16:0] rr,ri,tr,ti;
reg [15:0] band_peak,magnitude_q,peak_q;
reg [4:0] height_q;
reg [8:0] band_limit;

wire [8:0] reverse_index={capture_index[0],capture_index[1],capture_index[2],capture_index[3],capture_index[4],capture_index[5],capture_index[6],capture_index[7],capture_index[8]};
wire [8:0] addr_a=base+j,addr_b=base+j+half_size;
wire [8:0] read_addr=(state==4 || state==5)?addr_a:(state==6 || state==7)?addr_b:scan_bin;
wire signed [17:0] sum_r=$signed(ar)+$signed(tr),sum_i=$signed(ai)+$signed(ti);
wire signed [17:0] diff_r=$signed(ar)-$signed(tr),diff_i=$signed(ai)-$signed(ti);
wire signed [31:0] windowed=product>>>15;
wire [15:0] abs_r=mem_q[31]? (~mem_q[31:16]+16'd1):mem_q[31:16];
wire [15:0] abs_i=mem_q[15]? (~mem_q[15:0]+16'd1):mem_q[15:0];
// Approximate complex magnitude: max + min/2 (under 1 dB error).
wire [16:0] magnitude=abs_r>=abs_i?{1'b0,abs_r}+{2'b0,abs_i[15:1]}:{1'b0,abs_i}+{2'b0,abs_r[15:1]};
wire [15:0] peak=magnitude>band_peak?magnitude[15:0]:band_peak;
function[8:0] band_end;
    input [5:0] b;
    begin
        case(b)
            0:band_end=9'd1;
            1:band_end=9'd2;
            2:band_end=9'd3;
            3:band_end=9'd4;
            4:band_end=9'd5;
            5:band_end=9'd6;
            6:band_end=9'd7;
            7:band_end=9'd8;
            8:band_end=9'd9;
            9:band_end=9'd10;
            10:band_end=9'd11;
            11:band_end=9'd12;
            12:band_end=9'd13;
            13:band_end=9'd14;
            14:band_end=9'd15;
            15:band_end=9'd16;
            16:band_end=9'd17;
            17:band_end=9'd18;
            18:band_end=9'd19;
            19:band_end=9'd20;
            20:band_end=9'd21;
            21:band_end=9'd22;
            22:band_end=9'd23;
            23:band_end=9'd24;
            24:band_end=9'd25;
            25:band_end=9'd26;
            26:band_end=9'd27;
            27:band_end=9'd28;
            28:band_end=9'd29;
            29:band_end=9'd30;
            30:band_end=9'd31;
            31:band_end=9'd32;
            32:band_end=9'd33;
            33:band_end=9'd34;
            34:band_end=9'd35;
            35:band_end=9'd36;
            36:band_end=9'd37;
            37:band_end=9'd38;
            38:band_end=9'd39;
            39:band_end=9'd40;
            40:band_end=9'd41;
            41:band_end=9'd42;
            42:band_end=9'd43;
            43:band_end=9'd45;
            44:band_end=9'd49;
            45:band_end=9'd54;
            46:band_end=9'd59;
            47:band_end=9'd64;
            48:band_end=9'd70;
            49:band_end=9'd76;
            50:band_end=9'd83;
            51:band_end=9'd90;
            52:band_end=9'd98;
            53:band_end=9'd107;
            54:band_end=9'd117;
            55:band_end=9'd128;
            56:band_end=9'd139;
            57:band_end=9'd152;
            58:band_end=9'd165;
            59:band_end=9'd180;
            60:band_end=9'd197;
            61:band_end=9'd214;
            62:band_end=9'd234;
            63:band_end=9'd255;
        endcase
    end
endfunction
function[4:0] db_height;
    input [15:0] v;
    begin
        if(v<8) db_height=5'd0;
        else if(v<11) db_height=5'd1;
        else if(v<16) db_height=5'd2;
        else if(v<23) db_height=5'd3;
        else if(v<32) db_height=5'd4;
        else if(v<45) db_height=5'd5;
        else if(v<64) db_height=5'd6;
        else if(v<90) db_height=5'd7;
        else if(v<127) db_height=5'd8;
        else if(v<179) db_height=5'd9;
        else if(v<253) db_height=5'd10;
        else if(v<357) db_height=5'd11;
        else if(v<505) db_height=5'd12;
        else if(v<713) db_height=5'd13;
        else if(v<1007) db_height=5'd14;
        else if(v<1423) db_height=5'd15;
        else if(v<2010) db_height=5'd16;
        else if(v<2839) db_height=5'd17;
        else if(v<4009) db_height=5'd18;
        else if(v<5664) db_height=5'd19;
        else if(v<8000) db_height=5'd20;
        else if(v<11300) db_height=5'd21;
        else if(v<15962) db_height=5'd22;
        else db_height=23;
    end
endfunction
always @(posedge clk)
    if(!rst && state==24) spectrum_heights[{!published_bank,band}]<=height_q;
wire write_enable=state==2 || state==16 || state==17;
wire [8:0] write_addr=state==2?reverse_index:state==16?addr_a:addr_b;
wire [31:0] write_value=state==2?{windowed[15:0],16'd0}:state==16?{sum_r[16:1],sum_i[16:1]}:{diff_r[16:1],diff_i[16:1]};
always @(posedge clk) begin
    band_limit<=band_end(band);
    product<=mul_a*mul_b;
    mem_q<=mem[read_addr];
    tw_q<=twiddle[{tw_index[7:0],(state==6 || state==7)}];
    if(!rst && write_enable) mem[write_addr]<=write_value;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=0;
        capture_index<=0;
        base<=0;
        j<=0;
        half_size<=1;
        tw_index<=0;
        tw_step<=256;
        stage<=0;
        scan_bin<=1;
        band<=0;
        band_peak<=0;
        magnitude_q<=0;
        peak_q<=0;
        height_q<=0;
        published_bank<=0;
        result_valid<=0;
        ar<=0;
        ai<=0;
        br<=0;
        bi<=0;
        tw_cos<=0;
        tw_sin<=0;
        mul_a<=0;
        mul_b<=0;
        rr<=0;
        ri<=0;
        tr<=0;
        ti<=0;
    end else begin
        result_valid<=0;
        case(state)
            0:if(pcm_valid) begin
                mul_a<=pcm_left[23:8];
                mul_b<=capture_index[8]?{(9'd511-capture_index),7'd0}:{capture_index,7'd0};
                // Bartlett window reduces leakage; only the analysis copy is windowed.
                state<=1;
            end
            1:state<=2;
            2: begin
                capture_index<=capture_index+1'b1;
                if(capture_index==511) begin
                    stage<=0;
                    base<=0;
                    j<=0;
                    half_size<=1;
                    tw_index<=0;
                    tw_step<=256;
                    state<=4;
                end else state<=0;
            end
            4:state<=5;
            5: begin
                ar<=mem_q[31:16];
                ai<=mem_q[15:0];
                tw_cos<=tw_q;
                state<=6;
            end
            6:state<=7;
            7: begin
                br<=mem_q[31:16];
                bi<=mem_q[15:0];
                tw_sin<=tw_q;
                mul_a<=mem_q[31:16];
                mul_b<=tw_cos;
                state<=8;
            end
            8:state<=9;
            9: begin
                rr<=product>>>15;
                mul_a<=bi;
                mul_b<=tw_sin;
                state<=10;
            end
            10:state<=11;
            11: begin
                tr<=rr-($signed(product)>>>15);
                mul_a<=br;
                mul_b<=tw_sin;
                state<=12;
            end
            12:state<=13;
            13: begin
                ri<=product>>>15;
                mul_a<=bi;
                mul_b<=tw_cos;
                state<=14;
            end
            14:state<=15;
            15: begin
                ti<=ri+($signed(product)>>>15);
                state<=16;
            end
            16:state<=17;
            17:state<=18;
            18: begin
                if(j+1<half_size) begin
                    j<=j+1'b1;
                    tw_index<=tw_index+tw_step;
                    state<=4;
                end else if({1'b0,base}+{half_size,1'b0}<512) begin
                    base<=base+{half_size[7:0],1'b0};
                    j<=0;
                    tw_index<=0;
                    state<=4;
                end else if(stage<8) begin
                    stage<=stage+1'b1;
                    half_size<=half_size<<1;
                    tw_step<=tw_step>>1;
                    base<=0;
                    j<=0;
                    tw_index<=0;
                    state<=4;
                end else begin
                    scan_bin<=1;
                    band<=0;
                    band_peak<=0;
                    state<=19;
                end
            end
            19:state<=20;
            20: begin
                magnitude_q<=magnitude[15:0];
                state<=22;
            end
            22: begin
                peak_q<=magnitude_q>band_peak?magnitude_q:band_peak;
                state<=23;
            end
            23: begin
                if(scan_bin==band_limit) begin
                    height_q<=db_height(peak_q);
                    state<=24;
                end else begin
                    band_peak<=peak_q;
                    scan_bin<=scan_bin+1'b1;
                    state<=19;
                end
            end
            24: begin
                band<=band+1'b1;
                band_peak<=0;
                if(scan_bin==255) state<=21;
                else begin
                    scan_bin<=scan_bin+1'b1;
                    state<=19;
                end
            end
            21: begin
                published_bank<=!published_bank;
                result_valid<=1;
                state<=0;
            end
            default:state<=0;
        endcase
    end
end
endmodule
`endif
