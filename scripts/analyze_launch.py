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

tests = {'T1': 'T1_A.xlsx', 'T2_A': 'T2_A.xlsx', 'T3_A': 'T3_A.xlsx',
          'T4_B': 'T4_B.xlsx', 'T5_B': 'T5_B.xlsx'}
data = {k: load_full(os.path.join(LAUNCH_DIR, v)) for k, v in tests.items()}

# 有效 app: 所有 test 都有 >0 数据
all_pkgs = set().union(*[set(d.keys()) for d in data.values()])
valid = []
for pkg in all_pkgs:
    ok = True
    for k in tests:
        v = data[k].get(pkg)
        if v is None or v['all5_avg'] == 0 or v['t1'] == 0:
            ok = False
            break
    if ok:
        valid.append(pkg)
valid.sort()

print(f"=== 有效 app: {len(valid)} (排除任一 test 为 0/None 的项) ===\n")

# 三口径平均
print("【口径对比】")
print(f"{'指标':<14}", "".join(f"{k:>9}" for k in tests))
print('-' * 65)
for key, label in [('t1', '第1次启动'), ('all5_avg', '5次平均'), ('t2_5_avg', '2~5次温启动')]:
    means = {k: statistics.mean([data[k][p][key] for p in valid]) for k in tests}
    print(f"{label:<14}", "".join(f"{means[k]:>9.0f}" for k in tests))

print("\n【Δ 对 T1 基线】")
print(f"{'指标':<14} {'ΔT2-T1':>10} {'ΔT3-T1':>10} {'ΔT4-T1':>10} {'ΔT5-T1':>10}")
print('-' * 60)
for key, label in [('t1', '第1次启动'), ('all5_avg', '5次平均'), ('t2_5_avg', '2~5次温启动')]:
    means = {k: statistics.mean([data[k][p][key] for p in valid]) for k in tests}
    base = means['T1']
    print(f"{label:<14}", "  ".join(f"{means[k]-base:>+7.0f} ms" for k in ['T2_A', 'T3_A', 'T4_B', 'T5_B']))

print("\n【关键 Δ：OTA vs 线刷路径】")
for key, label in [('t1', '第1次启动'), ('all5_avg', '5次平均')]:
    means = {k: statistics.mean([data[k][p][key] for p in valid]) for k in tests}
    print(f"  {label}:")
    print(f"    T3_A vs T5_B (同稳态, OTA vs 线刷): {means['T3_A']-means['T5_B']:+.0f} ms")
    print(f"    T3_A vs T2_A (OTA 瞬态成本):       {means['T3_A']-means['T2_A']:+.0f} ms")
    print(f"    T5_B vs T4_B (线刷瞬态成本):       {means['T5_B']-means['T4_B']:+.0f} ms")

# 方差
print("\n【方差（每 app 5次启动 CV%）】")
print(f"  {'Test':<8} {'平均 CV%':>10}")
print('  ' + '-' * 22)
for k in tests:
    cvs = []
    for p in valid:
        vals = data[k][p]['all']
        m = statistics.mean(vals)
        s = statistics.stdev(vals)
        cvs.append(s/m if m > 0 else 0)
    print(f"  {k:<8} {statistics.mean(cvs)*100:>10.1f}")
