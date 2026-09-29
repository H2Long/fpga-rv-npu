from pathlib import Path
import subprocess,hashlib,json,shutil
HERE=Path(__file__).resolve().parent
SRC=HERE/'rtl_original'
BUILD=HERE/'build'
BUILD.mkdir(exist_ok=True)
for name in ['波形图片','原始波形','仿真日志']:(HERE/name).mkdir(exist_ok=True)
hashes={};changes=[]
for source in sorted(SRC.rglob('*.v')):
    rel=source.relative_to(SRC);hashes[str(rel)]=hashlib.sha256(source.read_bytes()).hexdigest()
    text=source.read_text(encoding='utf-8-sig')
    for old,new in [('e:/Vivado_Projects/project_risc_v/tools/hex/ins.hex','init_ins.hex'),('e:/Vivado_Projects/project_risc_v/tools/hex/data.hex','init_data.hex')]:
        if old in text:text=text.replace(old,new);changes.append({'file':str(rel),'old':old,'new':new})
    dest=BUILD/'rtl'/rel;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(text,encoding='utf-8')
(BUILD/'init_ins.hex').write_text('00000013\n'*8192)
(BUILD/'init_data.hex').write_text('00000000\n'*4096)
compiler=shutil.which('iverilog')
runtime=shutil.which('vvp')
if not compiler or not runtime:raise RuntimeError('Install Icarus Verilog and add iverilog / vvp to PATH')
cmd=[compiler,'-g2012','-s','tb_instruction','-o','instruction.vvp']+[str(f) for f in sorted((BUILD/'rtl').rglob('*.v'))]+[str(HERE/'tb_instruction.sv')]
r=subprocess.run(cmd,cwd=BUILD,capture_output=True,text=True)
(HERE/'仿真日志/compile.log').write_text(r.stdout+r.stderr,encoding='utf-8')
if r.returncode:raise RuntimeError(r.stdout+r.stderr)
tests=[]
for case,name in [(1,'ADD'),(2,'STORE')]:
    wave=HERE/'原始波形'/f'{name}.vcd'
    r=subprocess.run([runtime,'instruction.vvp',f'+case={case}',f'+wave={name}.vcd'],cwd=BUILD,capture_output=True,text=True,timeout=30)
    log=r.stdout+r.stderr
    (HERE/'仿真日志'/f'{name}.log').write_text(log,encoding='utf-8');print(log)
    if r.returncode or f'PASS {name}' not in log or 'ERROR:' in log or 'FATAL:' in log:raise RuntimeError(name+' failed')
    shutil.copy2(BUILD/f'{name}.vcd',wave)
    tests.append({'instruction':name,'pass':True,'vcd_sha256':hashlib.sha256(wave.read_bytes()).hexdigest()})
evidence={'repository':'https://github.com/ClIFFDY/project_risc_v','commit':'0bca94a11eb32105ce985aa95cf3a667c9e3ac22','clock_period_ns':10,'setup':'Testbench preloads registers; one target instruction at PC=0; NOP padding; reset released at 40ns','rtl_sha256':hashes,'path_only_changes':changes,'tests':tests}
(HERE/'evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
