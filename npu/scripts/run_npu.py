# run_npu.py — 编译并仿真 NPU RTL(Icarus Verilog)
# 用法: python run_npu.py
# 输出: ../sim/logs/npu_sim.log, ../sim/waves/npu_wave.vcd
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
RTL = os.path.join(PROJECT, "rtl")
TB = os.path.join(PROJECT, "tb")
SIM = os.path.join(PROJECT, "sim")
BUILD = os.path.join(SIM, "build")
LOG_DIR = os.path.join(SIM, "logs")
WAVE_DIR = os.path.join(SIM, "waves")


def find_iverilog():
    exe = shutil.which("iverilog")
    if exe:
        return exe
    cand = r"C:\msys64\mingw64\bin\iverilog.exe"
    if os.path.exists(cand):
        return cand
    sys.exit("未找到 iverilog,请安装 Icarus Verilog 并加入 PATH")


def main():
    os.makedirs(BUILD, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(WAVE_DIR, exist_ok=True)

    files = sorted(
        os.path.join(root, name)
        for root, _, names in os.walk(RTL)
        for name in names
        if name.endswith(".v")
    )
    files.append(os.path.join(TB, "tb_npu.v"))

    out = os.path.join(BUILD, "tb_npu.vvp")
    cmd = [find_iverilog(), "-g2001", "-I", os.path.join(RTL, "common"), "-o", out] + files
    print("编译:", " ".join(os.path.basename(c) for c in cmd[4:]))
    r = subprocess.run(
        cmd, cwd=PROJECT, capture_output=True, text=True,
        encoding="utf-8", errors="replace"
    )
    compile_log = os.path.join(LOG_DIR, "compile.log")
    with open(compile_log, "w", encoding="utf-8") as fh:
        fh.write(r.stdout + r.stderr)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit("编译失败,详见 " + compile_log)
    if r.stderr.strip():
        print("编译警告已写入", compile_log)

    print("仿真运行中 ...")
    r = subprocess.run(
        [os.path.join(BUILD, "tb_npu.vvp")],
        cwd=WAVE_DIR, capture_output=True, text=True, timeout=600,
        encoding="utf-8", errors="replace"
    )
    log = os.path.join(LOG_DIR, "npu_sim.log")
    with open(log, "w", encoding="utf-8") as fh:
        fh.write(r.stdout + r.stderr)
    print(r.stdout)
    ok = "ALL TESTS PASSED" in r.stdout
    print("日志:", log)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
