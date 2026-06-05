#!/usr/bin/env python3
"""
启动数据分析脚本：从 01_launch_data/*.xlsx 计算冷/温启动多口径对比 + 方差。

用法：cd final_dataset && python3 08_analysis_scripts/analyze_launch.py
"""
import openpyxl
import statistics
import os

LAUNCH_DIR = '01_launch_data'

def load_full(path):
    wb = openpyxl.load_workbook(path, data_only=True)
    ws = wb.active
    data = {}
    for r in list(ws.iter_rows(values_only=True))[1:]:
        pkg = r[0]
        try:
            t1, t2, t3, t4, t5 = [float(r[i]) for i in (2,3,4,5,6)]
            avg = float(r[7])
            data[pkg] = {
                't1': t1,
                't2_5_avg': (t2+t3+t4+t5)/4,
                'all5_avg': avg,
                'all': [t1, t2, t3, t4, t5],
            }
        except (TypeError, ValueError):
            data[pkg] = None
    return data

phases = {'P1': 'P1_A.xlsx', 'P2_A': 'P2_A.xlsx', 'P3_A': 'P3_A.xlsx',
          'P4_B': 'P4_B.xlsx', 'P5_B': 'P5_B.xlsx'}
data = {k: load_full(os.path.join(LAUNCH_DIR, v)) for k, v in phases.items()}

# 有效 app: 所有 phase 都有 >0 数据
all_pkgs = set().union(*[set(d.keys()) for d in data.values()])
valid = []
for pkg in all_pkgs:
    ok = True
    for k in phases:
        v = data[k].get(pkg)
        if v is None or v['all5_avg'] == 0 or v['t1'] == 0:
            ok = False
            break
    if ok:
        valid.append(pkg)
valid.sort()

print(f"=== 有效 app: {len(valid)} (排除任一 phase 为 0/None 的项) ===\n")

# 三口径平均
print("【口径对比】")
print(f"{'指标':<14}", "".join(f"{k:>9}" for k in phases))
print('-' * 65)
for key, label in [('t1', '第1次启动'), ('all5_avg', '5次平均'), ('t2_5_avg', '2~5次温启动')]:
    means = {k: statistics.mean([data[k][p][key] for p in valid]) for k in phases}
    print(f"{label:<14}", "".join(f"{means[k]:>9.0f}" for k in phases))

print("\n【Δ 对 P1 基线】")
print(f"{'指标':<14} {'ΔP2-P1':>10} {'ΔP3-P1':>10} {'ΔP4-P1':>10} {'ΔP5-P1':>10}")
print('-' * 60)
for key, label in [('t1', '第1次启动'), ('all5_avg', '5次平均'), ('t2_5_avg', '2~5次温启动')]:
    means = {k: statistics.mean([data[k][p][key] for p in valid]) for k in phases}
    base = means['P1']
    print(f"{label:<14}", "  ".join(f"{means[k]-base:>+7.0f} ms" for k in ['P2_A', 'P3_A', 'P4_B', 'P5_B']))

print("\n【关键 Δ：OTA vs 线刷路径】")
for key, label in [('t1', '第1次启动'), ('all5_avg', '5次平均')]:
    means = {k: statistics.mean([data[k][p][key] for p in valid]) for k in phases}
    print(f"  {label}:")
    print(f"    P3_A vs P5_B (同稳态, OTA vs 线刷): {means['P3_A']-means['P5_B']:+.0f} ms")
    print(f"    P3_A vs P2_A (OTA 瞬态成本):       {means['P3_A']-means['P2_A']:+.0f} ms")
    print(f"    P5_B vs P4_B (线刷瞬态成本):       {means['P5_B']-means['P4_B']:+.0f} ms")

# 方差
print("\n【方差（每 app 5次启动 CV%）】")
print(f"  {'Phase':<8} {'平均 CV%':>10}")
print('  ' + '-' * 22)
for k in phases:
    cvs = []
    for p in valid:
        vals = data[k][p]['all']
        m = statistics.mean(vals)
        s = statistics.stdev(vals)
        cvs.append(s/m if m > 0 else 0)
    print(f"  {k:<8} {statistics.mean(cvs)*100:>10.1f}")
