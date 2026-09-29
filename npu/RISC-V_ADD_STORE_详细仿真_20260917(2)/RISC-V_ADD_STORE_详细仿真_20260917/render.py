from pathlib import Path
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from vcd_reader import VCD

HERE=Path(__file__).resolve().parent
OUT=HERE/'波形图片';OUT.mkdir(exist_ok=True)
plt.rcParams.update({'font.family':['Microsoft YaHei','DejaVu Sans'],'axes.unicode_minus':False,'svg.fonttype':'none'})
BLUE='#215FA6';GREEN='#00846F';INK='#183247';GRAY='#567083'

add_front=[
 ('dut.pc_addr','PC · 字节地址',None),
 ('dut.inst_raw','取出的指令',2130355),
 ('dut.opcode_1','预译码 opcode · OP=33',51),
 ('dut.rs1_1','源寄存器 rs1 · x1',1),
 ('dut.rs2_1','源寄存器 rs2 · x2',2),
 ('dut.rd_1','目的寄存器 rd · x3',3),
 ('dut.func10_1','funct7 + funct3 · ADD=0',0),
 ('dut.opcode_2','缓冲后的 opcode',51),
 ('dut.r1_data_dec','同步读出的 x1',18),
 ('dut.r2_data_dec','同步读出的 x2',35)]
add_back=[
 ('dut.r1_data_final_dec','旁路选择后的操作数 A',18),
 ('dut.r2_data_final_dec','旁路选择后的操作数 B',35),
 ('dut.r1_data_3','执行端操作数 A',18),
 ('dut.r2_data_3','执行端操作数 B',35),
 ('dut.alu_func4','ALU 功能 · ADD=0',0),
 ('dut.result_4','组合 ALU 结果',53),
 ('dut.rd_4','ALU 目的寄存器',3),
 ('dut.we_4','ALU 输出有效',1),
 ('dut.result_5','WB 缓冲数据',53),
 ('dut.rd_5','WB 缓冲目的寄存器',3),
 ('gpr_write','实际 GPR 写使能',1),
 ('x3','寄存器 x3 的存储值',53)]
store_front=[
 ('dut.pc_addr','PC · 字节地址',None),
 ('dut.inst_raw','取出的指令',2139683),
 ('dut.lsu','选择访存路径',1),
 ('dut.opcode_lsu_1','预译码 opcode · STORE=23',35),
 ('dut.func10_lsu_1','访问大小 · SW 的 funct3=2',2),
 ('dut.rs1_1','地址基址寄存器 · x1',1),
 ('dut.rs2_1','写数据寄存器 · x2',2),
 ('dut.offset_store0_1','S 型立即数 · 12=0C',12),
 ('dut.opcode_lsu_2','缓冲后的 STORE opcode',35),
 ('dut.r1_data_lsu','同步读出的基地址',8388608),
 ('dut.r2_data_lsu','同步读出的写数据',305419896)]
store_back=[
 ('dut.r1_data_final_lsu','旁路选择后的基地址',8388608),
 ('dut.r2_data_final_lsu','旁路选择后的写数据',305419896),
 ('dut.offset_store0_2','缓冲后的偏移量',12),
 ('effective_byte_addr','LSU 有效字节地址 · 基址+12',8388620),
 ('bus_addr','总线字地址 · 字节地址 >> 2',2097155),
 ('bus_byte_addr','还原的总线字节地址',8388620),
 ('bus_data','总线写数据',305419896),
 ('bus_be','字节使能 · 1111=F',15),
 ('bus_we','总线写使能',1),
 ('memory_word','DTCM[3] 的存储值',305419896),
 ('gpr_write','实际 GPR 写使能 · 应为0',None),
 ('x3','无关寄存器 · 应保持',None)]

timelines={}
for name,inst in [('ADD',2130355),('STORE',2139683)]:
    v=VCD(HERE/'原始波形'/f'{name}.vcd')
    fetch=v.first('dut.inst_raw',inst)
    decode=v.first('dut.opcode_1',51 if name=='ADD' else 35)
    read=v.first('dut.r1_data_dec' if name=='ADD' else 'dut.r1_data_lsu',18 if name=='ADD' else 8388608)
    execute=v.first('dut.result_4' if name=='ADD' else 'bus_we',53 if name=='ADD' else 1)
    commit=v.first('x3' if name=='ADD' else 'memory_word',53 if name=='ADD' else 305419896)
    timelines[name]={'fetch_ns':fetch,'predecode_ns':decode,'register_read_ns':read,'execute_or_bus_ns':execute,'commit_ns':commit}
    if name=='ADD':timelines[name]['wb_buffer_ns']=v.first('dut.result_5',53)
(HERE/'timing.json').write_text(json.dumps(timelines,ensure_ascii=False,indent=2),encoding='utf-8')

def draw(name,rows,file,title,subtitle,full=False):
    v=VCD(HERE/'原始波形'/f'{name}.vcd')
    start,end=35,110
    rows=[('clk','上升沿推进时序',None)]+rows
    fig=plt.figure(figsize=(16,18 if full else 9),facecolor='white')
    fig.text(.025,.952,title,fontsize=23,fontweight='bold',color=INK)
    fig.text(.025,.911,subtitle,fontsize=12.5,color=GRAY)
    left,right=.295,.98;top=.809;bottom=.225 if not full else .115
    ts=timelines[name]
    bands=[(ts['fetch_ns'],'取指输出'),(ts['predecode_ns'],'预译码'),(ts['register_read_ns'],'读寄存器'),(ts['execute_or_bus_ns'],'ALU 运算' if name=='ADD' else '总线输出')]
    if name=='ADD':bands.extend([(ts['wb_buffer_ns'],'WB 缓冲'),(ts['commit_ns'],'写入 x3')])
    else:bands.append((ts['commit_ns'],'写入内存'))
    colors=['#EAF0F8','#F0EAF8','#E5F3F5','#FFF0D7','#E5F3E8','#ECF0F7']
    stageax=fig.add_axes([left,.847,right-left,.035])
    stageax.set_xlim(start,end);stageax.set_ylim(0,1);stageax.axis('off')
    for k,(t,label) in enumerate(bands):
        stageax.axvspan(t,t+10,color=colors[k])
        stageax.text(t+5,.5,f'{t:g} ns\n{label}',ha='center',va='center',fontsize=10,color=INK)
    fig.text(.025,.856,'目标指令推进顺序 →',fontsize=12,color=INK)
    rh=(top-bottom)/len(rows)
    relevant={
      'dut.inst_raw':(45,55),'dut.opcode_1':(55,65),'dut.rs1_1':(55,65),'dut.rs2_1':(55,65),'dut.rd_1':(55,65),'dut.func10_1':(55,65),
      'dut.opcode_2':(65,75),'dut.r1_data_dec':(65,75),'dut.r2_data_dec':(65,75),'dut.r1_data_final_dec':(65,75),'dut.r2_data_final_dec':(65,75),
      'dut.r1_data_3':(75,85),'dut.r2_data_3':(75,85),'dut.alu_func4':(75,85),'dut.result_4':(75,85),'dut.rd_4':(75,85),'dut.we_4':(75,85),
      'dut.result_5':(85,95),'dut.rd_5':(85,95),'gpr_write':(85,95) if name=='ADD' else (75,85),'x3':(95,105) if name=='ADD' else (35,110),
      'dut.lsu':(55,65),'dut.opcode_lsu_1':(55,65),'dut.func10_lsu_1':(55,65),'dut.offset_store0_1':(55,65),
      'dut.opcode_lsu_2':(65,75),'dut.r1_data_lsu':(65,75),'dut.r2_data_lsu':(65,75),'dut.r1_data_final_lsu':(65,75),'dut.r2_data_final_lsu':(65,75),'dut.offset_store0_2':(65,75),'effective_byte_addr':(65,75),
      'bus_addr':(75,85),'bus_byte_addr':(75,85),'bus_data':(75,85),'bus_be':(75,85),'bus_we':(75,85),'memory_word':(85,105)}
    for i,(sig,explain,target) in enumerate(rows):
        ax=fig.add_axes([left,top-(i+1)*rh+.004,right-left,rh-.008])
        ax.set_xlim(start,end);ax.set_ylim(-.12,1.17)
        for k,(t,label) in enumerate(bands):ax.axvspan(t,t+10,color=colors[k],alpha=.38,zorder=0)
        if sig in relevant:
            a,b=relevant[sig];ax.axvspan(a,b,color='#D6EDE5',alpha=.65,zorder=1)
        pts=v.points(sig,start,end);width=v.width['tb_instruction.'+sig]
        if width==1:
            ax.step([t for t,_ in pts],[val if isinstance(val,int) else float('nan') for _,val in pts],where='post',color=BLUE,lw=1.6,zorder=3)
            ax.text(-.013,.85,'1',transform=ax.transAxes,fontsize=8,ha='right',color=GRAY)
            ax.text(-.013,.08,'0',transform=ax.transAxes,fontsize=8,ha='right',color=GRAY)
        else:
            for (t,val),(t2,_) in zip(pts,pts[1:]):
                text=f'{val:0{(width+3)//4}X}' if isinstance(val,int) else val.upper()
                color=GREEN if val==target and target is not None else BLUE
                ax.plot([t,t2],[.18,.18],color=color,lw=1.1,zorder=3)
                ax.plot([t,t2],[.82,.82],color=color,lw=1.1,zorder=3)
                ax.plot([t,t],[.18,.82],color=color,lw=.9,zorder=3)
                if (t2-t)/(end-start)>.012*len(text):
                    ax.text((t+t2)/2,.5,text,fontsize=10.8 if len(text)>4 else 11.5,fontfamily='DejaVu Sans Mono',color=color,ha='center',va='center',zorder=4)
        ax.text(-.035,.72,sig.replace('dut.',''),transform=ax.transAxes,ha='right',va='center',fontsize=11,fontfamily='DejaVu Sans Mono',color=INK)
        ax.text(-.035,.22,explain,transform=ax.transAxes,ha='right',va='center',fontsize=10,color=GRAY)
        ax.set_xticks(range(35,111,10));ax.grid(axis='x',lw=.5,color='#BBCBD6')
        ax.set_yticks([]);ax.tick_params(axis='x',length=0,labelsize=10,colors=GRAY,labelbottom=i==len(rows)-1)
        for sp in ax.spines.values():sp.set_visible(False)
        if i==len(rows)-1:ax.set_xlabel('仿真时间 / ns · 数据为十六进制 · 绿色底色定位目标指令相关信号',fontsize=11,color=GRAY,labelpad=7)
    if not full:
        if name=='ADD':
            line1='45 ns 指令输出 → 55 ns 预译码 → 65 ns 同步读出 12 / 23 → 75 ns ALU 得到 35'
            line2='85 ns：WB 数据与目的寄存器有效；95 ns 上升沿：x3 从 DEADBEEF 更新为 00000035'
        else:
            line1='65 ns：00800000 + 0000000C = 0080000C；75 ns：地址、数据、BE 和 WE 同时输出'
            line2='85 ns 上升沿：DTCM[3] 从 DEADBEEF 更新为 12345678；STORE 没有 GPR 写回'
        fig.text(.025,.140,line1,fontsize=12.3,color=INK)
        fig.text(.025,.096,line2,fontsize=12.3,color=GREEN,fontweight='bold')
    fig.text(.025,.036,'真实 RTL / VCD · main @ 0bca94a · 时钟周期 10 ns · 测试台预置操作数，仅执行一条目标指令，其余为 NOP',fontsize=10.5,color=GRAY)
    for ext in ['png','svg']:fig.savefig(OUT/f'{file}.{ext}',dpi=200,facecolor='white')
    plt.close(fig)

draw('ADD',add_front,'01_ADD_取指译码与读取','ADD 指令运行过程（1/2）：取指、译码与读寄存器','add x3, x1, x2 · 指令 002081B3 · x1=00000012，x2=00000023 · PC=0')
draw('ADD',add_back,'02_ADD_执行与写回','ADD 指令运行过程（2/2）：ALU 运算与写回','跟踪同一条 ADD：操作数 → 执行端 → ALU → WB 缓冲 → 寄存器 x3')
draw('STORE',store_front,'03_STORE_取指译码与读取','STORE 指令运行过程（1/2）：译码、读基址与数据','sw x2, 12(x1) · 指令 0020A623 · x1=00800000，x2=12345678 · PC=0')
draw('STORE',store_back,'04_STORE_地址总线与内存写入','STORE 指令运行过程（2/2）：地址计算与内存写入','有效字节地址 0080000C → 项目总线字地址 00200003 → DTCM[3]')
draw('ADD',add_front+add_back,'05_ADD_完整信号总览','ADD 完整波形：从指令到寄存器写入','add x3,x1,x2 · 00000012 + 00000023 = 00000035 · 阶段时刻由真实 VCD 提取',full=True)
draw('STORE',store_front+store_back,'06_STORE_完整信号总览','STORE 完整波形：从指令到内存写入','sw x2,12(x1) · DTCM[3] ← 12345678 · 阶段时刻由真实 VCD 提取',full=True)
print('Rendered 4 PPT waveform pages and 2 full signal overviews, PNG + SVG')
