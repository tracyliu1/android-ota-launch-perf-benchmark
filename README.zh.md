# Android App 冷启动性能测试与证据采集工具

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

一套用于 Android **App 冷启动测试**、**多设备对比**和**性能证据采集**的工具。它不仅采集启动耗时，也同时归档 APK 版本/哈希、dexopt 状态、供电状态、CPUFreq、thermal、内存、负载、I/O 等信息，用来解释“为什么慢”，而不是只记录“慢了多少”。

OTA 前后对比是本工具支持的一个典型场景；同一套流程也适用于恢复出厂基线、多设备对比、ROM 版本对比和性能回归分析。

---

## 项目背景

本工具起源于一次真实的 OTA 升级 vs 线刷路径冷启动差异调查：**App 团队质疑"相同版本 ROM，线刷和 OTA 升级后，同一组 App 的冷启动速度不一致"**。

随着排查深入，脚本逐步演进成一套更通用的启动性能证据流水线：
- 可复现的冷启动测试脚本（`am start -W`）
- APK version 和内容哈希快照
- dexopt 编译状态追踪（filter / reason / odex / vdex）
- 设备系统状态采集（供电、CPUFreq、thermal、内存、负载、I/O）
- 可与 timeline 对齐的逐次启动明细
- 面向多设备共同成功 App 的对比报告

OTA 5-Test 矩阵仍然保留为一个推荐场景，但不再是本项目唯一主线。

---

## 目录

- [Quick Start](#quick-start)
- [项目背景](#项目背景)
- [核心概念](#核心概念)
- [推荐对比模式](#推荐对比模式)
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
# 可选：编辑本地 config.sh 作为固定默认值
# 多设备测试时，推荐通过环境变量传入 DEVICE_SERIAL / EVIDENCE_DEVICE_TAG
```

### 4. 执行单轮测试

推荐使用 `T` 开头的测试编号，例如 `T1_Demo`、`T1_Baseline`、`T2_AfterReset`。`--phase` 参数只是输出目录标签。

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

多台设备可以在同一 checkout 中并发执行同一个 phase。每个命令必须显式设置各自的
`ANDROID_SERIAL`（或 `DEVICE_SERIAL`）和 `EVIDENCE_DEVICE_TAG`。两台设备可以共用
同一个 `EVIDENCE_RUN_TAG` 和 phase；timeline 的 host 端 PID、日志和临时 CSV 会按
run tag、设备和 phase 隔离。

这里的并行能力仅指本仓库的一轮 App Launch phase 及其 host 端 timeline/logcat 采样；
它不代表上层 ADPB 的所有测试模块（例如 Compound）都已具备并行执行能力。

并行运行的前置条件：

- 每个进程绑定一个不同的在线设备 serial；推荐只设置 `ANDROID_SERIAL`。如果同时设置
  `ANDROID_SERIAL` 和 `DEVICE_SERIAL`，两者必须指向同一台设备。
- 每个设备使用不同且在本轮运行期间保持不变的 `EVIDENCE_DEVICE_TAG`。它既用于正式
  evidence 目录，也参与 host 临时文件隔离。
- `EVIDENCE_RUN_TAG` 和 phase 可以相同；需要区分重复批次时，再更换
  `EVIDENCE_RUN_TAG`。

例如，在两个终端中分别执行：

```bash
ANDROID_SERIAL=<A_SN> EVIDENCE_DEVICE_TAG=<A_SN> EVIDENCE_RUN_TAG=0729_parallel \
  bash 06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10

ANDROID_SERIAL=<B_SN> EVIDENCE_DEVICE_TAG=<B_SN> EVIDENCE_RUN_TAG=0729_parallel \
  bash 06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

#### 并行采样升级与兼容性说明

并行隔离只改变 host 端 timeline/logcat 采样器的临时文件名，不改变正式 evidence
目录、App Launch 执行次数、统计口径或指标。标准的
`06_run_phase_with_timeline.sh` 会在同一条命令内启动和停止采样，原有单设备用法无需
调整，历史 evidence 也无需迁移。

升级后需要注意以下边界：

- 临时文件现在使用 `<EVIDENCE_RUN_TAG>__<DEVICE_TAG或SN>__<PHASE>` 命名空间，
  不再只按 phase 命名。
- 如果手动分开执行采样器的 `--start` 和 `--stop`，两次操作必须使用相同的
  `EVIDENCE_RUN_TAG`、`EVIDENCE_DEVICE_TAG`（未设置时使用设备 serial）和 phase，
  否则 `--stop` 无法找到对应的 PID 文件。
- 不要在 timeline 或 logcat 采样器运行期间切换到包含此变更的新旧版本；应先用启动
  该采样器的版本停止采样，再更新代码。
- 仓库外如果有脚本直接读取旧的 `.timeline_sampler_<PHASE>.pid`、
  `.timeline_<PHASE>.csv` 或 `.logcat_recorder_<PHASE>.pid`，需要改为使用新的设备
  命名空间，或者改由仓库提供的标准脚本管理采样生命周期。
- 未显式设置 `EVIDENCE_DEVICE_TAG` 或设备 serial 时，脚本需要从在线设备推导命名空间。
  因此建议始终显式设置设备 serial；否则设备在手动 `--stop` 前掉线时，脚本可能无法
  重新计算与 `--start` 相同的临时文件名。

### 5. 分析

```bash
cd examples/sample-output
python3 ../../scripts/analyze_launch.py
```

---

## 核心概念

### 冷启动（工业定义）

本工具采用的口径与 Google Macrobenchmark、主流 APM 工具一致：

- `am force-stop <pkg>` 后，第一次 `am start -W` 的 `TotalTime`
- 进程被清空，但 pagecache **部分热**
- **不是** reboot 后的"真冷启动"（那个口径业界也不用于对比测试）

### 证据对齐

比较启动耗时前，至少需要对齐或归档：

- 相同 App 清单，以及共同成功启动的 App 集合
- APK `versionCode` / `versionName` / `sha256`
- dexopt `filter` / `reason` 以及 oat/vdex 是否存在
- AC/USB 供电状态、限流信息、电量、电池温度
- CPUFreq、governor、thermal 状态
- 测试期间 dex2oat 和 iowait 是否活跃
- 设备身份、build fingerprint、slot 状态、uptime

### 瞬态 vs 稳态

| 状态 | 定义 | 为什么重要 |
|------|------|-----------|
| **瞬态** | OTA 或线刷完成后的"系统未稳定"期 | 此时测试会引入不公平偏置 |
| **稳态** | 充电+灭屏静置 ≥ 72 小时后，系统后台任务收敛 | 只有稳态对比才有意义 |

> **关键经验**：OTA 路径的瞬态成本通常是线刷路径的 **1.7~3.6 倍**（冷启动差异），因为 OTA 后系统需要完成 VAB merge、bg-dexopt 等额外工作。

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

## 推荐对比模式

### 1. 同设备前后对比

使用同一台物理设备对比两个阶段，例如 OTA 前后、恢复出厂前后、系统配置变更前后。

### 2. 双设备同版本对比

使用相同 ROM 构建和相同 App 集合的两台设备，排查硬件、配置、dexopt、供电、thermal 等差异。这是 DeviceA vs DeviceB 这类分析的常见模式。

### 3. 恢复出厂基线

将目标设备全部恢复出厂，统一 App 清单和供电方式，再在每台设备上执行相同 phase。当前序测试已经导致 dexopt 或后台状态发散时，这个模式尤其有用。

### 4. OTA vs 线刷场景

原始 OTA 调查仍然可以使用 5-Test 对比矩阵：

| 代号 | 设备 | ROM | 测试时机 | 业务含义 |
|------|------|-----|---------|---------|
| **T1** | A | vOld（线刷）| 线刷后立即 | 升级前基线 |
| **T2** | A | vNew（OTA）| OTA reboot 后立即 | **复现"OTA 后慢"的场景** |
| **T3** | A | vNew（OTA）| OTA 后稳态（≥72h）| OTA 路径稳态 |
| **T4** | B | vNew（线刷）| 线刷后立即 | 线刷路径立即态 |
| **T5** | B | vNew（线刷）| 线刷后稳态（≥72h）| 线刷路径稳态 |

> **设备要求**：若要严格归因 OTA vs 线刷路径，A、B 两台应尽量是**同型号、同批次**设备，以控制硬件变量。

### 三组核心对比

| 对比组 | 控制变量 | 回答的问题 | 数据用法 |
|--------|---------|-----------|---------|
| **组 1**：T1 → T2 → T3 | 同 A 设备、同 OTA 路径 | 升级带来的整体变化 | 看趋势：瞬态 → 稳态 |
| **组 2**：T2 vs T4 | 同 vNew、同立即时机、不同路径 | OTA 瞬态成本 vs 线刷瞬态成本 | **支持/反驳"OTA 更慢"的感受** |
| **组 3**：T3 vs T5 | 同 vNew、同稳态时机、不同路径 | OTA 稳态是否真的追平线刷稳态 | **反驳"OTA ROM 有问题"的核心证据** |

---

## 脚本使用说明

### 配置

所有脚本会在存在时读取 `scripts/config.sh`。该文件是从 `config.template.sh` 复制出来的本地运行配置，默认被 git 忽略。不要在其中保存团队默认的设备 SN 或设备标签硬编码；多设备运行应通过环境变量传入。关键配置项：

```bash
DEVICE_SERIAL=""              # 留空=自动检测唯一设备
EVIDENCE_DEVICE_TAG=""        # 留空=从 adb 设备属性自动生成输出目录设备标签
EVIDENCE_RUN_TAG=""           # 可选；留空=当天 MMDD，例如 0617
APP_LIST_FILE="apps.txt"      # App 清单路径；也可以指向项目验证清单
LAUNCH_COUNT=5                # 每个 App 启动次数
LAUNCH_INTERVAL=10            # 启动间隔（秒）
BETWEEN_ATTEMPT_SLEEP_SEC=10  # 两次启动 attempt 之间等待；未设置时回退 LAUNCH_INTERVAL
LOGCAT_CAPTURE_SEC=5          # am start 返回后继续抓启动窗口 logcat 的秒数
FULL_LOGCAT=0                 # 0=默认低成本 filtered logcat；1=深挖时保存完整 per-attempt logcat
KEYWORD_PATTERNS="bytehook|rmonitor|shadowhook|bugly|eup|webview|chromium|SurfaceFlinger|C2MtkBufferManager"  # 候选怀疑项，不是归因结论
HOOK_KEYWORDS="bytehook|rmonitor|shadowhook"  # hook 线程级归因专用（窗口内主线程/子线程命中、时间跨度）
TIMELINE_INTERVAL_SEC=10      # timeline 采样间隔（秒）
DEVICE_TMPDIR="/data/local/tmp/ota_perf_benchmark"
HAS_VAB=true                  # 设备是否使用 VAB 分区
```

`BETWEEN_ATTEMPT_SLEEP_SEC` 和 `LOGCAT_CAPTURE_SEC` 不是一回事：

- `BETWEEN_ATTEMPT_SLEEP_SEC` 控制两次启动之间的等待，用于让 `force-stop`、进程回收和系统状态稳定。
- `LOGCAT_CAPTURE_SEC` 控制一次 `am start -W` 之后继续抓多久启动窗口日志，用于覆盖 `Displayed` 后的短窗口日志。

大规模测试默认建议保持 `FULL_LOGCAT=0`。此时脚本只保存低成本 filtered logcat evidence 和结构化统计；需要深挖少量 App 时再设置 `FULL_LOGCAT=1` 保存完整启动窗口 logcat。

`KEYWORD_PATTERNS` 只是候选怀疑项过滤器。`bytehook/rmonitor/shadowhook/bugly/eup/webview/chromium/SurfaceFlinger/C2MtkBufferManager` 这些命中只表示对应日志在启动窗口出现了多少次，不能自动等同于原因成立，也不参与 `strict_comparable` 或成功/失败判断。是否能归因，需要结合 DeviceA/DeviceB 对比、target pid 归属、启动耗时差异和原始日志内容人工判断。

默认输出目录为 `evidence/<MMDD>/<device-tag>_<PHASE>/`。同一天重复跑同一 phase 时，可用 `EVIDENCE_RUN_TAG=0617_run2` 避免覆盖。

关键配置都支持命令级环境变量覆盖，不需要为多设备测试反复改 `config.sh`：

```bash
ANDROID_SERIAL=<serial> \
DEVICE_SERIAL=<serial> \
EVIDENCE_DEVICE_TAG=MyDevice \
APP_LIST_FILE="$PWD/scripts/apps.txt" \
TIMELINE_INTERVAL_SEC=5 \
bash scripts/06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

### 脚本一览

| 脚本 | 用途 | 平台说明 |
|------|------|---------|
| `00_env_check.sh` | 实验前环境检查 + 设备身份归档 | 通用 |
| `01_dump_apk_versions.sh` | 采集 APK versionCode / versionName | 通用 |
| `01_dump_apk_sha256.sh` | 采集 APK 内容哈希 | 通用 |
| `02_dump_dexopt_state.sh` | 采集 dexopt filter / odex / vdex 状态 | 支持常见 Android 12/14 dumpsys 格式 |
| `03_timeline_sampler.sh` | Host 端轮询系统负载、供电、CPUFreq、thermal | 通用 |
| `04_logcat_recorder.sh` | Logcat 滚动录制 | 通用 |
| `05_run_launch_test.sh` | 内置 `am start -W` 启动测试循环 | 通用 |
| `06_run_phase_with_timeline.sh` | 单轮测试 wrapper，绑定 timeline 生命周期并自动归档 | 通用 |
| `07_classify_launch_results.py` | 按可比性规则输出 strict/reference/excluded 样本 | 通用 |
| `lib_common.sh` | 公共函数库 + 归档校验 | 通用 |

### 数据采集详情

#### 1. 系统负载 Timeline（`03_timeline_sampler.sh`）

| 字段 | 来源命令 | 用途 |
|------|---------|------|
| `loadavg_1m/5m/15m` | `cat /proc/loadavg` | 判断系统整体负载是否稳定 |
| `mem_total_kb` / `mem_avail_kb` | `cat /proc/meminfo` | 判断内存是否充足、有无泄漏 |
| `dex2oat_count` | `pidof dex2oat` | **关键**：后台是否在偷偷编译 dex |
| `dex2oat_cpu_pct` | `top -n1 -p <pid>` | dex2oat 占用了多少 CPU |
| `iowait_pct` | `/proc/stat` delta | **关键**：VAB merge 或 dexopt 是否在抢 I/O |
| `merge_status` | `cmd update_engine merge_status` | VAB merge 是否完成 |
| `ac_powered` / `usb_powered` | `dumpsys battery` | 对比 AC/USB 供电状态 |
| `max_charging_current` / `battery_level` / `battery_temp` | `dumpsys battery` | 追踪测试期间供电和电池状态 |
| `policy*_cur_freq/min_freq/max_freq/governor` | `/sys/devices/system/cpu/cpufreq/policy*` | 追踪 CPU 频率和 governor |
| `thermal_max_temp` / `thermal_max_type` | `/sys/class/thermal/thermal_zone*` | 观察 thermal 压力或限频线索 |

- **采集频率**：由 `TIMELINE_INTERVAL_SEC` 控制，默认 10 秒
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
| `sha256` | 排除 versionCode 相同但 APK 内容不同（由 `01_dump_apk_sha256.sh` 采集） |

- **采集时机**：每轮测试前一次
- **为什么重要**：如果不记录 versionCode 和内容哈希，就无法区分"ROM/系统差异"和"App 版本/内容差异"

#### 4. 设备身份归档（`00_env_check.sh`）

| 字段 | 来源 | 用途 |
|------|------|------|
| `ro.serialno` | `getprop` | 标识设备身份 |
| `ro.product.model` / `ro.build.fingerprint` | `getprop` | 确认 ROM 版本和构建信息 |
| `ro.boot.slot_suffix` | `getprop` | 确认 VAB slot（OTA 后应切换） |
| `ro.virtual_ab.enabled` | `getprop` | 确认设备是否使用 VAB |
| `uptime` | `uptime` / `/proc/uptime` | 记录测试时设备已运行多久 |

- **为什么重要**：确保对比设备和构建信息可识别；在 OTA 场景下，也用于证明 slot 切换确实发生

#### 5. 完整 Logcat（`04_logcat_recorder.sh`）

- **采集内容**：全 buffer（`main` / `system` / `crash` 等），`threadtime` 格式
- **为什么重要**：事后归因的核心证据链
  - OTA 场景下的 VAB merge 进度（`update_engine` / `snapuserd` 日志）
  - dex2oat 触发记录（`dex2oat` / `BackgroundDexOptService` 日志）
  - App 启动异常（crash、ANR）

### 多轮连续采集

对于瞬态到稳态的长周期对比，第一阶段测试完成后，**不要停止 timeline**，让设备继续充电+灭屏进入稳态，等下一阶段测试时 timeline 仍在跑：

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

同时会输出每次启动的明细 CSV：

```csv
package,activity,attempt,attempt_start_epoch,attempt_start_iso,attempt_end_epoch,attempt_end_iso,total_time_ms,status,error
```

这个文件用于把每次 `am start -W` 和 timeline 采样点按时间对齐。

新版启动脚本还会输出更细的证据文件：

```text
launch_raw/am_start_raw/                         # 每次 am start -W 原始输出
launch_raw/logcat_evidence/                      # 默认保存的 filtered logcat evidence
launch_raw/logcat_full/                          # 仅 FULL_LOGCAT=1 时生成
launch_raw/apps_launch_attempts_detail_<T>.csv   # attempt 级结构化字段
launch_raw/apps_launch_keyword_summary_<T>.csv   # keyword 全窗口/target pid 统计
launch_raw/run_size_summary.txt                  # 本轮输出目录大小和最大 logcat 文件
```

`apps_launch_attempts_detail_<T>.csv` 包含：

```text
Status / LaunchState / Activity / TotalTime / WaitTime
Displayed Activity / Displayed time
first START / final START / Activity chain
target pid
候选怀疑项关键字全窗口命中和 target pid 命中
```

默认 filtered logcat evidence 会保留 `ActivityTaskManager`、`ActivityManager: Start proc` 和 `KEYWORD_PATTERNS` 命中的日志行；完整 raw logcat 只在 `FULL_LOGCAT=1` 时保存。`KEYWORD_PATTERNS` 命中是辅助证据，不是脚本自动归因。

### 1.1 可比性分类输出

`06_run_phase_with_timeline.sh` 会在启动测试和 dexopt after 后自动调用 `07_classify_launch_results.py`，输出：

```text
launch_raw/apps_launch_attempts_classified_<T>.csv
launch_raw/included_strict_<T>.csv
launch_raw/reference_only_<T>.csv
launch_raw/excluded_<T>.csv
launch_raw/per_app_classification_summary_<T>.csv
```

分类口径：

- `strict_comparable`：用于主结论。要求 `Status=ok`、`LaunchState=COLD`、`TotalTime>0`、`Displayed` 存在、解析正常，且没有权限页/外部 Activity 干扰。
- `reference_only`：只能做旁证。例如 `Files` 这类 `TotalTime` 缺失但 `Displayed` 可用，或二跳 Activity chain 需要单独解释。
- `excluded`：不进入主结论。例如非 COLD、`TotalTime=0`、权限页、Displayed 缺失、外部 Activity 干扰等。

设备型号不同不是不可比条件；多设备对比时应优先对齐 App 维度：共同包名、version、sha256、dexopt `filter/reason`、启动入口、最终 Activity 和 Displayed Activity。

### 2. dexopt 状态输出

`02_dump_dexopt_state.sh` 产出 CSV：

```csv
pkg,installed,isa,filter,reason,base_apk_path,oat_odex_size,...
"com.example.device.appstore","yes","arm64","verify","prebuilt","/system/app/appstore/appstore.apk","205744",...
```

### 3. 数据分析框架

拿到一轮或多轮测试数据后，建议先按以下顺序分析：

1. 只比较共同成功启动的 App。
2. 先确认 APK version 和 sha256，再解释启动耗时差异。
3. 对比测试前后的 dexopt filter/reason 以及 oat/vdex 状态。
4. 检查测试期间 dex2oat、iowait、thermal、供电状态是否异常。
5. 完成上述证据对齐后，再解释 launch time delta。

如果是 OTA 5-Test 场景，再继续按下面的框架深入分析：

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

**跨设备对比报告**：

```bash
python3 scripts/08_compare_launch_results.py \
  --device DeviceA=evidence/0624_tri/DeviceA_T0 \
  --device DeviceB=evidence/0624_tri/DeviceB_T0 \
  --device DeviceC=evidence/0624_tri/DeviceC_T0 \
  --out evidence/0624_tri/launch_compare.xlsx
```

**第一个 `--device` 为基准**，所有差值都相对基准。报告固定输出 4 个 sheet：

| sheet | 内容 | 口径 |
|------|------|------|
| **overview** | 全部共同 app 总览：每台 `首启t1 / 5次均值 / CV% / dexopt / 主线程hook / hookSpan`，非基准设备附 `Δms / Δ%`，并标 `版本一致 / 严格可比` | 宽口径（5 次全算） |
| **strict** | 严格可比共同 app（主结论口径）+ 详细列：component/displayed/dexopt(filter+reason)/version/sha、每台 strict 数/均值/CV/min/max/首启/温启/displayed/cold_window/主线程hook/子线程hook/span/关键字命中，非基准设备附 Δ | 仅各设备都满足 strict、且启动入口/Displayed/version/sha/dexopt 全对齐的 app |
| **system_state** | 每台 timeline 窗口内 governor / cur_freq / iowait / thermal / dex2oat 汇总，判断是否降频/限温/后台编译 | phase 级 |
| **summary** | 共同数、strict 数、各设备均值与相对基准 Δ（mean/median） | 汇总 |

`主线程hook / hookSpan` 只有当 attempt detail 里有对应数据时才填（无 hook 的项目自然为空）。做主结论请优先看 **strict** sheet；overview 是宽口径参考。

---

## 已知限制

1. **dexopt 输出格式因 Android 版本而异**：`02_dump_dexopt_state.sh` 已兼容常见 Android 12/14 `dumpsys package` 格式；若新平台解析失败，需根据实际输出补充 `grep` / `sed` 模式。

2. **merge_status 依赖设备命令**：`03_timeline_sampler.sh` 中的 `merge_status` 字段依赖 `cmd update_engine merge_status`。部分设备不支持此命令，不支持时该列会显示 `UNKNOWN`，不影响其他字段采集。

3. **CPU 和 thermal sysfs 路径存在平台差异**：timeline 会读取常见的 `/sys/devices/system/cpu/cpufreq/policy*` 和 `/sys/class/thermal/thermal_zone*`。如果设备不暴露或权限受限，对应字段会留空。

4. **`am start -W` 对 Launcher 的固有局限**：`com.android.launcher3`（默认 Home Activity）在 `force-stop` 后会被 SystemServer 立即重启，导致 `TotalTime` 为 0 或异常。这是 `am start -W` 工具本身的限制，**不是脚本 bug**。建议将 Launcher 排除在统计之外。

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
│   ├── 01_dump_apk_sha256.sh
│   ├── 02_dump_dexopt_state.sh
│   ├── 03_timeline_sampler.sh
│   ├── 04_logcat_recorder.sh
│   ├── 05_run_launch_test.sh
│   ├── 06_run_phase_with_timeline.sh
│   ├── 08_compare_launch_results.py
│   ├── analyze_launch.py
│   └── analyze_timeline.py
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
