#!/usr/bin/env python3
"""
Timeline 分析脚本：对比 5 个测试期 + 2 个 transition 期的系统负载

用法：cd final_dataset && python3 08_analysis_scripts/analyze_timeline.py
"""
import csv
import statistics
import os

TL_DIR = '04_timeline'

def load_timeline(path, fmt):
    """fmt='new' 用 dex2oat_count 列；fmt='parsed' 用 dex2oat_active 列"""
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for r in reader:
            if fmt == 'new':
                rows.append({
                    'loadavg_1m': float(r['loadavg_1m']),
                    'mem_avail_kb': int(r['mem_avail_kb']),
                    'dex2oat': int(r['dex2oat_count']) > 0,
                })
            else:
                rows.append({
                    'loadavg_1m': float(r['loadavg_1m']),
                    'mem_avail_kb': int(r['mem_avail_kb']),
                    'dex2oat': int(r['dex2oat_active']) > 0,
                })
    return rows

# 5 个测试期
tests = {
    'T1':   ('T1_A_timeline.csv', 'parsed'),
    'T2_A': ('T2_A_timeline.csv', 'parsed'),
    'T3_A': ('T3_A_timeline.csv', 'new'),
    'T4_B': ('T4_B_timeline.csv', 'parsed'),
    'T5_B': ('T5_B_timeline.csv', 'new'),
}

print("=== 5 个测试期的系统负载对比 ===\n")
print(f"{'Test':<8} {'ticks':>6} {'la1m_avg':>10} {'la1m_max':>10} {'mem_min(MB)':>12} {'dex2oat_ticks':>15}")
print('-' * 70)
for k, (fname, fmt) in tests.items():
    rows = load_timeline(os.path.join(TL_DIR, fname), fmt)
    la = [r['loadavg_1m'] for r in rows]
    mem = [r['mem_avail_kb']/1024 for r in rows]
    dex = sum(1 for r in rows if r['dex2oat'])
    print(f"{k:<8} {len(rows):>6} {statistics.mean(la):>10.2f} {max(la):>10.2f} {min(mem):>12.0f} {dex:>10}/{len(rows)}")

# Transition 期
print("\n=== Transition 期负载（A: T2 → T3 间隔, B: T4 后稳态间隔）===\n")
for label, fname in [('A_transition', 'A_transition_timeline.csv'),
                      ('B_transition', 'B_transition_timeline.csv')]:
    rows = load_timeline(os.path.join(TL_DIR, fname), 'new')
    la = [r['loadavg_1m'] for r in rows]
    dex_ticks = sum(1 for r in rows if r['dex2oat'])
    print(f"  {label}: {len(rows)} ticks ({len(rows)*30/3600:.1f} 小时)")
    print(f"    loadavg_1m 平均 {statistics.mean(la):.2f} / max {max(la):.2f}")
    print(f"    dex2oat 活跃 tick 数: {dex_ticks}/{len(rows)}")
