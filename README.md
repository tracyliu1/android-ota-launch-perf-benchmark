# Android OTA Launch Performance Benchmark

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A reusable benchmark **toolkit** for comparing **App cold-start performance** between **OTA upgrade** and **fresh flash** paths on Android devices. Includes automation scripts, recommended experiment design, data analysis framework, and AI assistant prompts.

> **One-sentence pitch**: This toolkit answers the core question — *"Is my App slower after OTA because the ROM itself is bad, or is it just a transient side-effect of the OTA process?"*

[中文完整版 → README.zh.md](README.zh.md)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Project Background](#project-background)
- [Core Concepts](#core-concepts)
- [Recommended Experiment Design](#recommended-experiment-design)
- [Script Usage](#script-usage)
- [Output Format & Data Analysis](#output-format--data-analysis)
- [Known Limitations](#known-limitations)
- [AI Assistant Prompts](#ai-assistant-prompts)
- [Repository Layout](#repository-layout)

---

## Project Background

This toolkit originated from a real-world problem: **the App team questioned why the same ROM version produced different cold-start speeds between flash and OTA paths**.

To independently verify this claim, we gradually built up:
- Reproducible cold-start test scripts (`am start -W`)
- Device system state collection (CPU, memory, load, I/O)
- dexopt compilation state tracking (filter / odex / vdex)
- A complete 5-Test comparative experiment design

These accumulations were eventually packaged into a **reusable open-source testing toolkit**.

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/your-org/android-ota-launch-perf-benchmark.git
cd android-ota-launch-perf-benchmark
```

### 2. Prerequisites

- **Host**: macOS / Linux with `adb` and `python3`
- **Python** (optional, for xlsx output):
  ```bash
  pip3 install openpyxl
  ```
- **Device**: Android device with USB debugging enabled

### 3. Configure

```bash
cd scripts
cp config.template.sh config.sh
cp apps.template.txt apps.txt

# Edit apps.txt: fill in your target packages and activities
# Edit config.sh (usually just confirm DEVICE_SERIAL and APP_LIST_FILE)
```

### 4. Run a Single Test

Use `T`-prefixed test IDs such as `T1_Demo` or `T2_OTA_Immediate`. The `--phase` argument is the output label; using `T*` labels keeps new runs distinct from older P-based examples.

```bash
# One command for env check, APK versions, dexopt before/after, timeline, launch test, and archive
bash 06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

### 5. Analyze

```bash
cd examples/sample-output
python3 ../../scripts/analyze_launch.py
```

---

## Core Concepts

### Transient vs Steady State

| State | Definition | Why it matters |
|-------|-----------|---------------|
| **Transient** | The "system not yet stable" period right after OTA or flash | Testing during this period introduces unfair bias |
| **Steady State** | After ≥72h of charging + screen-off idle, background tasks converged | Only steady-state comparisons are meaningful |

> **Key insight**: The transient cost of OTA path is typically **1.7~3.6×** that of flash path (cold-start delta), because the system still has VAB merge, bg-dexopt, and other post-OTA work to finish.

### Cold Start (Industry Definition)

Aligned with Google Macrobenchmark and mainstream APM tools:

- `am force-stop <pkg>` followed by first `am start -W` **TotalTime**
- Process cleared, but pagecache **partially warm**
- **Not** the "true cold start" after reboot (pagecache fully cold) — that metric is **not** used for cross-device comparisons in the industry either

### The 5-Launch Convention

| Launch | Meaning | Usage |
|--------|---------|-------|
| 1st | Cold start (industry definition) | **Primary metric** for cross-device/path comparison |
| 2nd~5th | Warm starts | Reflect stable performance with pagecache hot |
| Average of 5 | Composite metric | User's average experience when reopening the same App |
| CV (coefficient of variation) | Stability | `std/mean`; CV 2% = "same speed every time", CV 24% = "sometimes instant, sometimes laggy" |

### Steady-State Pre-Flight Checklist

```bash
# 1. No dex2oat running (must be empty output)
adb shell pidof dex2oat

# 2. VAB merge finished (if device supports VAB)
adb shell getprop ro.boot.slot_suffix

# 3. dexopt converged (must NOT contain run-from-apk)
for pkg in $(cat apps.txt); do
    adb shell "dumpsys package $pkg | grep -m1 '\[.*\]'"
done

# 4. Device charging
adb shell dumpsys battery | grep -E "AC powered|USB powered|level"
```

Pass criteria:
- ✅ dex2oat process absent
- ✅ slot_suffix stable
- ✅ All App filters are `verify` or `speed-profile`, **no `run-from-apk` or `run-from-apk-fallback`**
- ✅ Device charging

---

## Recommended Experiment Design

### The 5-Test Matrix

| ID | Device | ROM | Timing | Meaning |
|----|--------|-----|--------|---------|
| T1 | A | vOld (flash) | Immediately after flash | Pre-upgrade baseline |
| T2 | A | vNew (OTA) | ~3 min after OTA reboot | **Reproduce the "OTA is slow" scenario** |
| T3 | A | vNew (OTA) | Steady state (≥72h) | OTA path steady state |
| T4 | B | vNew (flash) | Immediately after flash | Flash path immediate state |
| T5 | B | vNew (flash) | Steady state (≥72h) | Flash path steady state |

> **Hardware requirement**: Devices A and B must be **same model, same batch** to control hardware variables.

### Three Core Comparisons

| Group | Controlled Variables | Question Answered |
|-------|---------------------|-------------------|
| **Group 1**: T1 → T2 → T3 | Same device A, same OTA path | Overall upgrade effect |
| **Group 2**: T2 vs T4 | Same vNew, same immediate timing, different path | OTA transient cost vs flash transient cost |
| **Group 3**: T3 vs T5 | Same vNew, same steady timing, different path | Does OTA steady state catch up with flash? |

---

## Script Usage

### Configuration

All scripts share `scripts/config.sh` (copied from `config.template.sh`). Key items:

```bash
DEVICE_SERIAL=""              # Empty = auto-detect single device
APP_LIST_FILE="apps.txt"      # Path to app list
LAUNCH_COUNT=5                # Launches per app
LAUNCH_INTERVAL=10            # Interval in seconds
DEVICE_TMPDIR="/data/local/tmp/ota_perf_benchmark"
HAS_VAB=true                  # Whether device uses VAB partitions
```

### Script Reference

| Script | Purpose | Platform Notes |
|--------|---------|---------------|
| `00_env_check.sh` | Pre-flight env check + device identity archive | Universal |
| `01_dump_apk_versions.sh` | Collect APK versionCode / versionName | Universal |
| `02_dump_dexopt_state.sh` | Collect dexopt filter / odex / vdex state | Supports common Android 12/14 dumpsys formats |
| `03_timeline_sampler.sh` | Host-side polling of system load (every 30s) | Universal |
| `04_logcat_recorder.sh` | Rolling logcat recording | Universal |
| `05_run_launch_test.sh` | Built-in `am start -W` launch loop | Universal |
| `06_run_phase_with_timeline.sh` | Single-test wrapper that binds timeline lifecycle and archive checks | Universal |
| `lib_common.sh` | Common functions + archive verification | Universal |

### Data Collection Details

#### 1. System Load Timeline (`03_timeline_sampler.sh`)

| Field | Source Command | Purpose |
|-------|---------------|---------|
| `loadavg_1m/5m/15m` | `cat /proc/loadavg` | Judge overall system load stability |
| `mem_total_kb` / `mem_avail_kb` | `cat /proc/meminfo` | Judge memory sufficiency / leaks |
| `dex2oat_count` | `pidof dex2oat` | **Critical**: whether bg dexopt is running |
| `dex2oat_cpu_pct` | `top -n1 -p <pid>` | How much CPU dex2oat consumes |
| `iowait_pct` | `top` summary line | **Critical**: whether VAB merge or dexopt is grabbing I/O |
| `merge_status` | `cmd update_engine merge_status` | Whether VAB merge is complete |

- **Sampling frequency**: every 30 seconds
- **Sampling method**: host-side polling via `adb shell`, no device-side daemon needed
- **Why it matters**: if `dex2oat_count > 0` or `iowait > 5%` during testing, background tasks are interfering and the comparison is unfair

#### 2. dexopt Compilation State (`02_dump_dexopt_state.sh`)

| Field | Source | Purpose |
|-------|--------|---------|
| `filter` | `dumpsys package` `[compiler filter: xxx]` | Judge current compilation level |
| `reason` | `dumpsys package` `reason:` | Judge trigger reason of last compilation |
| `oat_odex_size` / `oat_vdex_size` | `ls -l <oatDir>/<isa>/` | Judge whether precompiled artifacts exist |
| `profile_size` | `ls -l /data/misc/profiles/ref/<pkg>/` | Judge whether runtime profile exists |

- **Collection timing**: once before and once after each test
- **Why it matters**: a common cause of slowness after OTA is `run-from-apk` (no odex/vdex). This script provides **smoking-gun evidence**.

#### 3. APK Version Snapshot (`01_dump_apk_versions.sh`)

| Field | Purpose |
|-------|---------|
| `versionCode` / `versionName` | Rule out "same package name but different version" causing startup time differences |
| `codePath` | Confirm whether app is installed on system partition or data partition |

- **Collection timing**: once before each test
- **Why it matters**: OTA usually upgrades pre-installed apps simultaneously. Without recording versionCode, you cannot distinguish "ROM difference" from "App version difference".

#### 4. Device Identity Archive (`00_env_check.sh`)

| Field | Source | Purpose |
|-------|--------|---------|
| `ro.serialno` | `getprop` | Identify device |
| `ro.product.model` / `ro.build.fingerprint` | `getprop` | Confirm ROM version and build info |
| `ro.boot.slot_suffix` | `getprop` | Confirm VAB slot (should switch after OTA) |
| `ro.virtual_ab.enabled` | `getprop` | Confirm whether device uses VAB |
| `uptime` | `uptime` / `/proc/uptime` | Record how long device has been running |

- **Why it matters**: ensure the two comparison devices have identical hardware model; prove OTA actually performed slot switching

#### 5. Full Logcat (`04_logcat_recorder.sh`)

- **Captured content**: full buffer (`main` / `system` / `crash`, etc.), `threadtime` format
- **Why it matters**: core evidence chain for post-hoc attribution
  - VAB merge progress (`update_engine` / `snapuserd` logs)
  - dex2oat trigger records (`dex2oat` / `BackgroundDexOptService` logs)
  - App launch anomalies (crash, ANR)

### Continuous Timeline Across Tests (e.g. T2 → T3)

After T2 test, **do not stop timeline**. Let the device charge with screen-off to enter steady state; timeline continues running until T3 test:

```bash
# T2 test
bash 05_run_launch_test.sh --phase T2_A
bash lib_common.sh archive T2_A --skip-timeline --skip-logcat

# Device charges + screen-off, wait for steady state (≥72h)

# T3 test (timeline still running)
bash 05_run_launch_test.sh --phase T3_A
bash 03_timeline_sampler.sh --phase A_continuous --stop
bash lib_common.sh split-continuous A_continuous --into T2_A T3_A
```

---

## Output Format & Data Analysis

### 1. Launch Time Output

`05_run_launch_test.sh` produces CSV:

```csv
package,activity,t1,t2,t3,t4,t5,avg,status
com.example.device.appstore,.news.presentation.activity.SplashActivity,1450,1280,1260,1250,1240,1296,ok
com.example.device.reader,.main.ui.MainActivity,1120,980,970,960,955,997,ok
```

If `openpyxl` is installed, an `.xlsx` with the same name is generated automatically.

### 2. dexopt State Output

`02_dump_dexopt_state.sh` produces CSV:

```csv
pkg,installed,isa,filter,reason,base_apk_path,oat_odex_size,...
"com.example.device.appstore","yes","arm64","verify","prebuilt","/system/app/appstore/appstore.apk","205744",...
```

### 3. Analysis Framework

After collecting all 5 test datasets, analyze as follows:

**Launch time**:
- Compute per-test mean of "1st launch" and "avg of 5"
- Compute the three core deltas (Group 1/2/3)
- Compute per-App CV%; steady-state CV should be < 5%

**dexopt attribution** (critical):
- Compare `filter` distribution between T2 and T4
- If T2 has `run-from-apk` while T4 does not → OTA transient lacks pre-compiled artifacts
- Track those Apps into T3; if they advance to `verify`/`speed-profile` → proves transient self-healing

**Timeline load**:
- Check `iowait_pct` during the first ~5 minutes of T2 test window
- If 5~20% spikes appear while T1/T4 show 0% at the same period → VAB merge or dexopt is consuming I/O

---

## Known Limitations

1. **dexopt output varies by Android version**: `02_dump_dexopt_state.sh` supports common Android 12/14 `dumpsys package` formats. If parsing fails on a new platform, add patterns for that device's actual output.

2. **merge_status depends on device command**: The `merge_status` column in `03_timeline_sampler.sh` relies on `cmd update_engine merge_status`. Some devices do not support this command; when unsupported, the column will show `UNKNOWN` without affecting other fields.

3. **`am start -W` limitation for Launcher**: `com.android.launcher3` (the default Home Activity) is immediately restarted by SystemServer after `force-stop`, causing `TotalTime` to be 0 or abnormal. This is an inherent limitation of the `am start -W` tool, **not a script bug**. It is recommended to exclude Launcher from statistics.

---

## AI Assistant Prompts

This repo provides two ready-to-use Prompts:

- [`prompts/executor.md`](prompts/executor.md) — **Execution Assistant**: let AI guide you step-by-step through the testing workflow
- [`prompts/analyzer.md`](prompts/analyzer.md) — **Analysis Assistant**: feed raw data to AI and get an attribution analysis report automatically

---

## Repository Layout

```
android-ota-launch-perf-benchmark/
├── README.md                  # English quick-start (this file)
├── README.zh.md               # Full Chinese version
├── LICENSE                    # Apache-2.0
├── prompts/
│   ├── executor.md            # AI Execution Assistant Prompt
│   └── analyzer.md            # AI Analysis Assistant Prompt
├── docs/
│   ├── methodology.md         # Detailed experiment design methodology
│   ├── runbook.md             # Complete runbook with troubleshooting
│   ├── glossary.md            # Terminology quick reference
│   └── faq.md                 # Frequently asked questions
├── scripts/
│   ├── config.template.sh     # Configuration template
│   ├── apps.template.txt      # App list template
│   ├── lib_common.sh          # Common functions
│   ├── 00_env_check.sh
│   ├── 01_dump_apk_versions.sh
│   ├── 02_dump_dexopt_state.sh
│   ├── 03_timeline_sampler.sh
│   ├── 04_logcat_recorder.sh
│   ├── 05_run_launch_test.sh
│   └── 06_run_phase_with_timeline.sh
└── examples/
    ├── sample-apps.txt        # Minimal app list example
    └── sample-output/         # Output format examples (CSV)
```

---

## Contributing

Issues and PRs welcome! Especially:
- Adapting dexopt parsing logic for Android 13/14/15
- Sharing steady-state criteria experiences from other chip platforms (Qualcomm, Unisoc, etc.)
- Improving cross-platform compatibility of timeline sampler

## License

[Apache-2.0](LICENSE)
