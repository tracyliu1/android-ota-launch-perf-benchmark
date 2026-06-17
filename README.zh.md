# Android OTA Launch Performance Benchmark

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

一套可复用的 **Android OTA 升级 vs 线刷 冷启动性能对比测试工具**。包含自动化采集脚本、推荐实验设计、数据分析框架和 AI 助手 Prompt。

> **一句话**：本工具解决的核心问题 —— *“OTA 升级后 App 启动变慢，究竟是 ROM 本身的问题，还是 OTA 流程独有的瞬态副产物？”*

---

## 项目背景

本工具起源于一个真实问题：**App 团队质疑"相同版本 ROM，线刷和 OTA 升级后，同一组 App 的冷启动速度不一致"**。

为独立验证这一质疑，分析过程中逐步沉淀了：
- 可复现的冷启动测试脚本（`am start -W`）
- 设备系统状态采集（CPU、内存、负载、I/O）
- dexopt 编译状态追踪（filter / odex / vdex）
- 完整的 5-Test 对比实验设计

最终将这些积累汇总为一套**可复用的开源测试工具**。

---

## 目录

- [Quick Start](#quick-start)
- [项目背景](#项目背景)
- [核心概念](#核心概念)
- [推荐实验设计](#推荐实验设计)
- [脚本使用说明](#脚本使用说明)
- [输出格式与数据分析](#输出格式与数据分析)
- [已知限制](#已知限制)
- [AI 助手 Prompt](#ai-助手-prompt)
- [目录结构](#目录结构)

---

## Quick Start

### 1. 克隆

```bash
git clone https://github.com/your-org/android-ota-launch-perf-benchmark.git
cd android-ota-launch-perf-benchmark
```

### 2. 准备环境

- **Host**：macOS / Linux，已安装 `adb`、`python3`
- **Python 依赖**（可选，用于 xlsx 生成）：
  ```bash
  pip3 install openpyxl
  ```
- **设备**：Android 终端，已开启 USB 调试

### 3. 配置

```bash
cd scripts
cp config.template.sh config.sh
cp apps.template.txt apps.txt

# 编辑 apps.txt：填入你要测试的包名和 Activity
# 编辑 config.sh（通常只需确认 DEVICE_SERIAL 和 APP_LIST_FILE）
```

### 4. 执行单轮测试

推荐使用 `T` 开头的测试编号，例如 `T1_Demo`、`T2_OTA_Immediate`。`--phase` 参数只是输出目录标签，建议统一使用 `T*` 命名，避免和历史文档中的 P 编号混淆。

```bash
# 一键完成：环境检查、APK 版本、dexopt before/after、timeline、启动测试、归档
bash 06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

输出会按日期和设备标签归档，例如：

```text
evidence/0617/<device-tag>_T1_Demo/
```

`device-tag` 默认从 adb 设备属性自动生成；也可以临时指定：

```bash
EVIDENCE_DEVICE_TAG=MyDevice bash 06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

### 5. 分析

```bash
cd examples/sample-output
python3 ../../scripts/analyze_launch.py
```

---

## 核心概念

### 瞬态 vs 稳态

| 状态 | 定义 | 为什么重要 |
|------|------|-----------|
| **瞬态** | OTA 或线刷完成后的"系统未稳定"期 | 此时测试会引入不公平偏置 |
| **稳态** | 充电+灭屏静置 ≥ 72 小时后，系统后台任务收敛 | 只有稳态对比才有意义 |

> **关键经验**：OTA 路径的瞬态成本通常是线刷路径的 **1.7~3.6 倍**（冷启动差异），因为 OTA 后系统需要完成 VAB merge、bg-dexopt 等额外工作。

### 冷启动（工业定义）

本工具采用的口径与 Google Macrobenchmark、主流 APM 工具一致：

- `am force-stop <pkg>` 后，第一次 `am start -W` 的 `TotalTime`
- 进程被清空，但 pagecache **部分热**
- **不是** reboot 后的"真冷启动"（那个口径业界也不用于对比测试）

### 5 次启动的用途

| 次数 | 含义 | 用途 |
|------|------|------|
| 第 1 次 | 冷启动（工业定义） | **主指标**，用于跨设备/跨路径对比 |
| 第 2~5 次 | 温启动 | 反映 pagecache 命中后的稳定性能 |
| 5 次平均 | 综合指标 | 反映用户反复打开同一 App 的平均体验 |
| CV（变异系数）| 稳定性 | `std/mean`，CV 2% 表示"每次一样快"，CV 24% 表示"有时秒开有时卡" |

### 稳态判定条件（测试前必须自检）

```bash
# 1. dex2oat 不在跑（必须为空输出）
adb shell pidof dex2oat

# 2. VAB merge 已完成（若设备支持 VAB）
adb shell getprop ro.boot.slot_suffix

# 3. dexopt 状态收敛（不该有 run-from-apk）
for pkg in $(cat apps.txt); do
    adb shell "dumpsys package $pkg | grep -m1 '\[.*\]'"
done

# 4. 设备处于充电状态
adb shell dumpsys battery | grep -E "AC powered|USB powered|level"
```

通过标准：
- ✅ dex2oat 进程不存在
- ✅ slot_suffix 稳定
- ✅ 所有 App filter 是 `verify` 或 `speed-profile`，**没有 `run-from-apk` 或 `run-from-apk-fallback`**
- ✅ 设备处于充电状态

---

## 推荐实验设计

### 5-Test 对比矩阵

| 代号 | 设备 | ROM | 测试时机 | 业务含义 |
|------|------|-----|---------|---------|
| **T1** | A | vOld（线刷）| 线刷后立即 | 升级前基线 |
| **T2** | A | vNew（OTA）| OTA reboot 后立即 | **复现"OTA 后慢"的场景** |
| **T3** | A | vNew（OTA）| OTA 后稳态（≥72h）| OTA 路径稳态 |
| **T4** | B | vNew（线刷）| 线刷后立即 | 线刷路径立即态 |
| **T5** | B | vNew（线刷）| 线刷后稳态（≥72h）| 线刷路径稳态 |

> **设备要求**：A、B 两台必须是**同型号、同批次**的设备，以控制硬件变量。

### 三组核心对比

| 对比组 | 控制变量 | 回答的问题 | 数据用法 |
|--------|---------|-----------|---------|
| **组 1**：T1 → T2 → T3 | 同 A 设备、同 OTA 路径 | 升级带来的整体变化 | 看趋势：瞬态 → 稳态 |
| **组 2**：T2 vs T4 | 同 vNew、同立即时机、不同路径 | OTA 瞬态成本 vs 线刷瞬态成本 | **支持/反驳"OTA 更慢"的感受** |
| **组 3**：T3 vs T5 | 同 vNew、同稳态时机、不同路径 | OTA 稳态是否真的追平线刷稳态 | **反驳"OTA ROM 有问题"的核心证据** |

---

## 脚本使用说明

### 配置

所有脚本共享 `scripts/config.sh`（从 `config.template.sh` 复制）。关键配置项：

```bash
DEVICE_SERIAL=""              # 留空=自动检测唯一设备
EVIDENCE_DEVICE_TAG=""        # 留空=从 adb 设备属性自动生成输出目录设备标签
EVIDENCE_RUN_TAG=""           # 可选；留空=当天 MMDD，例如 0617
APP_LIST_FILE="apps.txt"      # App 清单路径
LAUNCH_COUNT=5                # 每个 App 启动次数
LAUNCH_INTERVAL=10            # 启动间隔（秒）
DEVICE_TMPDIR="/data/local/tmp/ota_perf_benchmark"
HAS_VAB=true                  # 设备是否使用 VAB 分区
```

默认输出目录为 `evidence/<MMDD>/<device-tag>_<PHASE>/`。同一天重复跑同一 phase 时，可用 `EVIDENCE_RUN_TAG=0617_run2` 避免覆盖。

### 脚本一览

| 脚本 | 用途 | 平台说明 |
|------|------|---------|
| `00_env_check.sh` | 实验前环境检查 + 设备身份归档 | 通用 |
| `01_dump_apk_versions.sh` | 采集 APK versionCode / versionName | 通用 |
| `02_dump_dexopt_state.sh` | 采集 dexopt filter / odex / vdex 状态 | 支持常见 Android 12/14 dumpsys 格式 |
| `03_timeline_sampler.sh` | Host 端轮询系统负载（每 30s） | 通用 |
| `04_logcat_recorder.sh` | Logcat 滚动录制 | 通用 |
| `05_run_launch_test.sh` | 内置 `am start -W` 启动测试循环 | 通用 |
| `06_run_phase_with_timeline.sh` | 单轮测试 wrapper，绑定 timeline 生命周期并自动归档 | 通用 |
| `lib_common.sh` | 公共函数库 + 归档校验 | 通用 |

### 数据采集详情

#### 1. 系统负载 Timeline（`03_timeline_sampler.sh`）

| 字段 | 来源命令 | 用途 |
|------|---------|------|
| `loadavg_1m/5m/15m` | `cat /proc/loadavg` | 判断系统整体负载是否稳定 |
| `mem_total_kb` / `mem_avail_kb` | `cat /proc/meminfo` | 判断内存是否充足、有无泄漏 |
| `dex2oat_count` | `pidof dex2oat` | **关键**：后台是否在偷偷编译 dex |
| `dex2oat_cpu_pct` | `top -n1 -p <pid>` | dex2oat 占用了多少 CPU |
| `iowait_pct` | `top` 汇总行 | **关键**：VAB merge 或 dexopt 是否在抢 I/O |
| `merge_status` | `cmd update_engine merge_status` | VAB merge 是否完成 |

- **采集频率**：每 30 秒一次
- **采集方式**：host 端轮询（通过 `adb shell`），不依赖设备端后台进程
- **为什么重要**：如果测试期间 `dex2oat_count > 0` 或 `iowait > 5%`，说明后台任务在干扰，对比结果不公平

#### 2. dexopt 编译状态（`02_dump_dexopt_state.sh`）

| 字段 | 来源 | 用途 |
|------|------|------|
| `filter` | `dumpsys package` 中 `[compiler filter: xxx]` | 判断 App 当前编译级别 |
| `reason` | `dumpsys package` 中 `reason:` | 判断上次编译的触发原因 |
| `oat_odex_size` / `oat_vdex_size` | `ls -l <oatDir>/<isa>/` | 判断预编译产物是否存在 |
| `profile_size` | `ls -l /data/misc/profiles/ref/<pkg>/` | 判断运行时 profile 是否生成 |

- **采集时机**：每轮测试前、测试后各一次
- **为什么重要**：OTA 后常见的"慢"直接原因是 `run-from-apk`（无 odex/vdex），这个脚本提供**冒烟枪证据**

#### 3. APK 版本快照（`01_dump_apk_versions.sh`）

| 字段 | 用途 |
|------|------|
| `versionCode` / `versionName` | 排除"同一个包名但版本不同"导致的启动时间差异 |
| `codePath` | 确认 App 安装在 system 分区还是 data 分区 |

- **采集时机**：每轮测试前一次
- **为什么重要**：OTA 通常会同步升级预装 App，如果不记录 versionCode，就无法区分"ROM 差异"和"App 版本差异"

#### 4. 设备身份归档（`00_env_check.sh`）

| 字段 | 来源 | 用途 |
|------|------|------|
| `ro.serialno` | `getprop` | 标识设备身份 |
| `ro.product.model` / `ro.build.fingerprint` | `getprop` | 确认 ROM 版本和构建信息 |
| `ro.boot.slot_suffix` | `getprop` | 确认 VAB slot（OTA 后应切换） |
| `ro.virtual_ab.enabled` | `getprop` | 确认设备是否使用 VAB |
| `uptime` | `uptime` / `/proc/uptime` | 记录测试时设备已运行多久 |

- **为什么重要**：确保两台对比设备的硬件型号一致；证明 OTA 确实发生了 slot 切换

#### 5. 完整 Logcat（`04_logcat_recorder.sh`）

- **采集内容**：全 buffer（`main` / `system` / `crash` 等），`threadtime` 格式
- **为什么重要**：事后归因的核心证据链
  - VAB merge 进度（`update_engine` / `snapuserd` 日志）
  - dex2oat 触发记录（`dex2oat` / `BackgroundDexOptService` 日志）
  - App 启动异常（crash、ANR）

### 多轮连续采集（如 T2 → T3）

T2 测试完成后，**不要停止 timeline**，让设备继续充电+灭屏进入稳态，等 T3 测试时 timeline 仍在跑：

```bash
# T2 阶段
bash 05_run_launch_test.sh --phase T2_A
bash lib_common.sh archive T2_A --skip-timeline --skip-logcat

# 设备插电+灭屏，等待稳态（≥72h）

# T3 阶段（timeline 继续）
bash 05_run_launch_test.sh --phase T3_A
bash 03_timeline_sampler.sh --phase A_continuous --stop
bash lib_common.sh split-continuous A_continuous --into T2_A T3_A
```

---

## 输出格式与数据分析

### 1. 启动耗时输出

`05_run_launch_test.sh` 产出 CSV：

```csv
package,activity,t1,t2,t3,t4,t5,avg,status
com.example.device.appstore,.news.presentation.activity.SplashActivity,1450,1280,1260,1250,1240,1296,ok
com.example.device.reader,.main.ui.MainActivity,1120,980,970,960,955,997,ok
```

若安装了 `openpyxl`，会自动生成同名的 `.xlsx`。

### 2. dexopt 状态输出

`02_dump_dexopt_state.sh` 产出 CSV：

```csv
pkg,installed,isa,filter,reason,base_apk_path,oat_odex_size,...
"com.example.device.appstore","yes","arm64","verify","prebuilt","/system/app/appstore/appstore.apk","205744",...
```

### 3. 数据分析框架

拿到 5 轮测试数据后，按以下框架分析：

**启动耗时**：
- 计算每轮测试的"第 1 次启动"均值、"5 次平均"均值
- 计算三组核心 Δ（组 1/2/3）
- 计算每 App 的 CV%，稳态期 CV 应 < 5%

**dexopt 归因**（关键）：
- 对比 T2 和 T4 的 `filter` 分布
- 若 T2 出现 `run-from-apk` 而 T4 没有 → OTA 瞬态缺少预编译产物
- 追踪这些 App 到 T3，看是否升级为 `verify`/`speed-profile` → 证明瞬态自愈

**Timeline 负载**：
- 查看 T2 测试期前 5 分钟的 `iowait_pct`
- 若出现 5~20% 峰值而 T1/T4 同时段为 0 → VAB merge 或 dexopt 抢占 I/O

---

## 已知限制

1. **dexopt 输出格式因 Android 版本而异**：`02_dump_dexopt_state.sh` 已兼容常见 Android 12/14 `dumpsys package` 格式；若新平台解析失败，需根据实际输出补充 `grep` / `sed` 模式。

2. **merge_status 依赖设备命令**：`03_timeline_sampler.sh` 中的 `merge_status` 字段依赖 `cmd update_engine merge_status`。部分设备不支持此命令，不支持时该列会显示 `UNKNOWN`，不影响其他字段采集。

3. **`am start -W` 对 Launcher 的固有局限**：`com.android.launcher3`（默认 Home Activity）在 `force-stop` 后会被 SystemServer 立即重启，导致 `TotalTime` 为 0 或异常。这是 `am start -W` 工具本身的限制，**不是脚本 bug**。建议将 Launcher 排除在统计之外。

---

## AI 助手 Prompt

本仓库提供两份可直接复制给 AI 的 Prompt：

- [`prompts/executor.md`](prompts/executor.md) —— **执行助手**：让 AI 一步步指导你完成测试操作
- [`prompts/analyzer.md`](prompts/analyzer.md) —— **分析助手**：把原始数据丢给 AI，自动产出归因分析报告

---

## 目录结构

```
android-ota-launch-perf-benchmark/
├── README.md                  # English quick-start
├── README.zh.md               # 中文完整版（本文档）
├── LICENSE                    # Apache-2.0
├── prompts/
│   ├── executor.md            # AI 执行助手 Prompt
│   └── analyzer.md            # AI 分析助手 Prompt
├── docs/
│   ├── methodology.md         # 实验设计方法论详解
│   ├── runbook.md             # 完整操作手册（含故障排查）
│   ├── glossary.md            # 术语速查表
│   └── faq.md                 # 常见问题
├── scripts/
│   ├── config.template.sh     # 配置模板
│   ├── apps.template.txt      # App 清单模板
│   ├── lib_common.sh          # 公共函数库
│   ├── 00_env_check.sh
│   ├── 01_dump_apk_versions.sh
│   ├── 02_dump_dexopt_state.sh
│   ├── 03_timeline_sampler.sh
│   ├── 04_logcat_recorder.sh
│   ├── 05_run_launch_test.sh
│   └── 06_run_phase_with_timeline.sh
└── examples/
    ├── sample-apps.txt        # 极简 App 列表示例
    └── sample-output/         # 输出格式示例（CSV）
```

---

## 贡献

欢迎提交 Issue 和 PR！特别是：
- 适配更多 Android 版本（Android 13/14/15）的 dexopt 解析逻辑
- 补充其他芯片平台（Qualcomm、Unisoc 等）的稳态判定经验
- 改进 timeline sampler 的跨平台兼容性

## License

[Apache-2.0](LICENSE)
