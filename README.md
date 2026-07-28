# Android App Launch Performance Benchmark & Evidence Toolkit

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A reusable toolkit for Android **App cold-start benchmarking**, **multi-device comparison**, and **performance evidence collection**. It captures launch timing together with APK identity, dexopt state, power state, CPUFreq, thermal, memory, load, and I/O signals so performance differences can be explained instead of only observed.

OTA-vs-flash comparison is one supported scenario. The same workflow also applies to factory-reset baselines, cross-device comparison, ROM version comparison, and regression investigation.

[中文完整版 → README.zh.md](README.zh.md)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Project Background](#project-background)
- [Core Concepts](#core-concepts)
- [Recommended Comparison Patterns](#recommended-comparison-patterns)
- [Script Usage](#script-usage)
- [Output Format & Data Analysis](#output-format--data-analysis)
- [Known Limitations](#known-limitations)
- [AI Assistant Prompts](#ai-assistant-prompts)
- [Repository Layout](#repository-layout)

---

## Project Background

This toolkit originated from a real-world OTA-vs-flash investigation: **the App team questioned why the same ROM version produced different cold-start speeds between flash and OTA paths**.

During that work, the scripts evolved into a more general launch-performance evidence pipeline:
- Reproducible cold-start test scripts (`am start -W`)
- APK version and content-hash snapshots
- dexopt compilation state tracking (filter / reason / odex / vdex)
- Device system state collection (power, CPUFreq, thermal, memory, load, I/O)
- Per-attempt launch records that can be aligned with timeline samples
- Cross-device comparison reports for common successful Apps

The OTA 5-Test matrix remains documented as a recommended scenario, but it is no longer the only intended use.

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
# Optional: edit local config.sh for stable defaults
# Prefer environment variables for DEVICE_SERIAL / EVIDENCE_DEVICE_TAG in multi-device runs
```

### 4. Run a Single Test

Use `T`-prefixed test IDs such as `T1_Demo`, `T1_Baseline`, or `T2_AfterReset`. The `--phase` argument is only the output label.

```bash
# One command for env check, APK versions, dexopt before/after, timeline, launch test, and archive
bash 06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

Artifacts are grouped by date and device tag, for example:

```text
evidence/0617/<device-tag>_T1_Demo/
```

The `device-tag` is detected from adb device properties by default. You can override it per run:

```bash
EVIDENCE_DEVICE_TAG=MyDevice bash 06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

Multiple devices may run the same phase concurrently from one checkout. Each command must set its
own `ANDROID_SERIAL` (or `DEVICE_SERIAL`) and `EVIDENCE_DEVICE_TAG`. Devices may share the same
`EVIDENCE_RUN_TAG` and phase; host-side timeline PID, log, and temporary CSV files are namespaced
by run tag, device, and phase.

### 5. Analyze

```bash
cd examples/sample-output
python3 ../../scripts/analyze_launch.py
```

---

## Core Concepts

### Cold Start (Industry Definition)

Aligned with Google Macrobenchmark and mainstream APM tools:

- `am force-stop <pkg>` followed by first `am start -W` **TotalTime**
- Process cleared, but pagecache **partially warm**
- **Not** the "true cold start" after reboot (pagecache fully cold) — that metric is **not** used for cross-device comparisons in the industry either

### Evidence Alignment

Before comparing launch time, align or archive at least:

- Same App list and common successful Apps
- APK `versionCode` / `versionName` / `sha256`
- dexopt `filter` / `reason` and oat/vdex existence
- Charging source, current limit, battery level, and battery temperature
- CPUFreq, governor, and thermal state
- `dex2oat` activity and `iowait` during the test window
- Device identity, build fingerprint, slot state, and uptime

### Transient vs Steady State

| State | Definition | Why it matters |
|-------|-----------|---------------|
| **Transient** | The "system not yet stable" period right after OTA or flash | Testing during this period introduces unfair bias |
| **Steady State** | After ≥72h of charging + screen-off idle, background tasks converged | Only steady-state comparisons are meaningful |

> **Key insight**: The transient cost of OTA path is typically **1.7~3.6×** that of flash path (cold-start delta), because the system still has VAB merge, bg-dexopt, and other post-OTA work to finish.

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

## Recommended Comparison Patterns

### 1. Same Device, Before vs After

Use the same physical device to compare two phases, for example before/after OTA, before/after reset, or before/after a system configuration change.

### 2. Two Devices, Same Build

Use two devices on the same ROM build and App set to investigate hardware, configuration, dexopt, power, or thermal differences. This is the common pattern for `DeviceA` vs `DeviceB` style analysis.

### 3. Factory-Reset Baseline

Factory reset all target devices, align App list and power setup, then run the same phase label on each device. This is useful when previous runs already diverged in dexopt state or background setup.

### 4. OTA vs Flash Scenario

The original OTA investigation can still use the 5-Test matrix:

| ID | Device | ROM | Timing | Meaning |
|----|--------|-----|--------|---------|
| T1 | A | vOld (flash) | Immediately after flash | Pre-upgrade baseline |
| T2 | A | vNew (OTA) | ~3 min after OTA reboot | **Reproduce the "OTA is slow" scenario** |
| T3 | A | vNew (OTA) | Steady state (≥72h) | OTA path steady state |
| T4 | B | vNew (flash) | Immediately after flash | Flash path immediate state |
| T5 | B | vNew (flash) | Steady state (≥72h) | Flash path steady state |

> **Hardware requirement**: for strict OTA-vs-flash attribution, Devices A and B should be **same model, same batch** to control hardware variables.

### Three Core Comparisons

| Group | Controlled Variables | Question Answered |
|-------|---------------------|-------------------|
| **Group 1**: T1 → T2 → T3 | Same device A, same OTA path | Overall upgrade effect |
| **Group 2**: T2 vs T4 | Same vNew, same immediate timing, different path | OTA transient cost vs flash transient cost |
| **Group 3**: T3 vs T5 | Same vNew, same steady timing, different path | Does OTA steady state catch up with flash? |

---

## Script Usage

### Configuration

All scripts read defaults from `scripts/config.sh` when it exists. This file is local runtime configuration copied from `config.template.sh` and is intentionally ignored by git. Do not store team-wide hardcoded device serials or device tags in it; use environment variables for multi-device runs. Key items:

```bash
DEVICE_SERIAL=""              # Empty = auto-detect single device
EVIDENCE_DEVICE_TAG=""        # Empty = auto-detect output device tag from adb properties
EVIDENCE_RUN_TAG=""           # Optional; empty = current MMDD, e.g. 0617
APP_LIST_FILE="apps.txt"      # Path to app list; can point to a validated project list
LAUNCH_COUNT=5                # Launches per app
LAUNCH_INTERVAL=10            # Interval in seconds
BETWEEN_ATTEMPT_SLEEP_SEC=10  # Sleep between attempts; falls back to LAUNCH_INTERVAL
LOGCAT_CAPTURE_SEC=5          # Seconds to capture launch-window logcat after am start returns
FULL_LOGCAT=0                 # 0=low-cost filtered evidence; 1=full per-attempt logcat
KEYWORD_PATTERNS="bytehook|rmonitor|shadowhook|bugly|eup|webview|chromium|SurfaceFlinger|C2MtkBufferManager"  # Candidate signals, not attribution conclusions
HOOK_KEYWORDS="bytehook|rmonitor|shadowhook"  # Hook thread-level attribution (in-window main/worker hits, time span)
TIMELINE_INTERVAL_SEC=10      # Timeline sampling interval
DEVICE_TMPDIR="/data/local/tmp/ota_perf_benchmark"
HAS_VAB=true                  # Whether device uses VAB partitions
```

`BETWEEN_ATTEMPT_SLEEP_SEC` and `LOGCAT_CAPTURE_SEC` are separate knobs. The former waits between attempts for process cleanup and stability; the latter controls how long launch-window logcat is captured after `am start -W` returns. Keep `FULL_LOGCAT=0` for large runs, and enable `FULL_LOGCAT=1` only when drilling into a smaller App set.

`KEYWORD_PATTERNS` is only a candidate-signal filter. Matches such as `bytehook/rmonitor/shadowhook/bugly/eup/webview/chromium/SurfaceFlinger/C2MtkBufferManager` mean those logs appeared in the launch window. They do not participate in success/strict classification and are not automatic root-cause conclusions.

The default artifact directory is `evidence/<MMDD>/<device-tag>_<PHASE>/`. For repeated runs of the same phase on the same day, set `EVIDENCE_RUN_TAG=0617_run2` to avoid overwriting previous output.

All key settings can be overridden per command without editing `config.sh`:

```bash
ANDROID_SERIAL=<serial> \
DEVICE_SERIAL=<serial> \
EVIDENCE_DEVICE_TAG=MyDevice \
APP_LIST_FILE="$PWD/scripts/apps.txt" \
TIMELINE_INTERVAL_SEC=5 \
bash scripts/06_run_phase_with_timeline.sh --phase T1_Demo -- -c 5 -s 10
```

### Script Reference

| Script | Purpose | Platform Notes |
|--------|---------|---------------|
| `00_env_check.sh` | Pre-flight env check + device identity archive | Universal |
| `01_dump_apk_versions.sh` | Collect APK versionCode / versionName | Universal |
| `01_dump_apk_sha256.sh` | Collect APK content hash | Universal |
| `02_dump_dexopt_state.sh` | Collect dexopt filter / odex / vdex state | Supports common Android 12/14 dumpsys formats |
| `03_timeline_sampler.sh` | Host-side polling of system load, power, CPUFreq, thermal | Universal |
| `04_logcat_recorder.sh` | Rolling logcat recording | Universal |
| `05_run_launch_test.sh` | Built-in `am start -W` launch loop | Universal |
| `06_run_phase_with_timeline.sh` | Single-test wrapper that binds timeline lifecycle and archive checks | Universal |
| `07_classify_launch_results.py` | Classifies attempts into strict/reference/excluded buckets | Universal |
| `lib_common.sh` | Common functions + archive verification | Universal |

### Data Collection Details

#### 1. System Load Timeline (`03_timeline_sampler.sh`)

| Field | Source Command | Purpose |
|-------|---------------|---------|
| `loadavg_1m/5m/15m` | `cat /proc/loadavg` | Judge overall system load stability |
| `mem_total_kb` / `mem_avail_kb` | `cat /proc/meminfo` | Judge memory sufficiency / leaks |
| `dex2oat_count` | `pidof dex2oat` | **Critical**: whether bg dexopt is running |
| `dex2oat_cpu_pct` | `top -n1 -p <pid>` | How much CPU dex2oat consumes |
| `iowait_pct` | `/proc/stat` delta | **Critical**: whether VAB merge or dexopt is grabbing I/O |
| `merge_status` | `cmd update_engine merge_status` | Whether VAB merge is complete |
| `ac_powered` / `usb_powered` | `dumpsys battery` | Compare AC vs USB charging state |
| `max_charging_current` / `battery_level` / `battery_temp` | `dumpsys battery` | Track power and battery state during the run |
| `policy*_cur_freq/min_freq/max_freq/governor` | `/sys/devices/system/cpu/cpufreq/policy*` | Track CPUFreq and governor behavior |
| `thermal_max_temp` / `thermal_max_type` | `/sys/class/thermal/thermal_zone*` | Detect thermal pressure or throttling clues |

- **Sampling frequency**: controlled by `TIMELINE_INTERVAL_SEC` (default: 10 seconds)
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
| `sha256` | Rule out same versionCode but different APK content (`01_dump_apk_sha256.sh`) |

- **Collection timing**: once before each test
- **Why it matters**: without recording versionCode and content hash, you cannot distinguish "ROM/system difference" from "App version/content difference".

#### 4. Device Identity Archive (`00_env_check.sh`)

| Field | Source | Purpose |
|-------|--------|---------|
| `ro.serialno` | `getprop` | Identify device |
| `ro.product.model` / `ro.build.fingerprint` | `getprop` | Confirm ROM version and build info |
| `ro.boot.slot_suffix` | `getprop` | Confirm VAB slot (should switch after OTA) |
| `ro.virtual_ab.enabled` | `getprop` | Confirm whether device uses VAB |
| `uptime` | `uptime` / `/proc/uptime` | Record how long device has been running |

- **Why it matters**: ensure comparison devices and builds are identifiable; in OTA scenarios, also prove slot switching actually happened

#### 5. Full Logcat (`04_logcat_recorder.sh`)

- **Captured content**: full buffer (`main` / `system` / `crash`, etc.), `threadtime` format
- **Why it matters**: core evidence chain for post-hoc attribution
  - VAB merge progress in OTA scenarios (`update_engine` / `snapuserd` logs)
  - dex2oat trigger records (`dex2oat` / `BackgroundDexOptService` logs)
  - App launch anomalies (crash, ANR)

### Continuous Timeline Across Tests

For long-running transient-to-steady comparisons, **do not stop timeline** after the first phase. Let the device charge with screen-off to enter steady state; timeline continues running until the next phase:

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

`05_run_launch_test.sh` also writes a per-attempt CSV:

```csv
package,activity,attempt,attempt_start_epoch,attempt_start_iso,attempt_end_epoch,attempt_end_iso,total_time_ms,status,error
```

Use this file to align each `am start -W` attempt with timeline samples.

The launch script also writes structured low-cost evidence:

```text
launch_raw/am_start_raw/                         # Raw am start -W output
launch_raw/logcat_evidence/                      # Filtered launch-window logcat evidence
launch_raw/logcat_full/                          # Only when FULL_LOGCAT=1
launch_raw/apps_launch_attempts_detail_<T>.csv   # Per-attempt structured fields
launch_raw/apps_launch_keyword_summary_<T>.csv   # Full-window and target-pid candidate-signal counts
launch_raw/run_size_summary.txt                  # Output size summary
```

`06_run_phase_with_timeline.sh` automatically runs `07_classify_launch_results.py` after launch and dexopt collection, producing:

```text
launch_raw/apps_launch_attempts_classified_<T>.csv
launch_raw/included_strict_<T>.csv
launch_raw/reference_only_<T>.csv
launch_raw/excluded_<T>.csv
launch_raw/per_app_classification_summary_<T>.csv
```

Use `included_strict` for primary conclusions. Use `reference_only` only as supporting evidence, for example when `Displayed` exists but `TotalTime` is missing. Exclude non-cold starts, permission pages, missing/zero `TotalTime`, missing `Displayed`, and external-activity pollution. Different device models are not a filter condition by themselves; App identity, APK hash, dexopt state, launch component, final Activity, and Displayed Activity are the key comparability checks.

### 2. dexopt State Output

`02_dump_dexopt_state.sh` produces CSV:

```csv
pkg,installed,isa,filter,reason,base_apk_path,oat_odex_size,...
"com.example.device.appstore","yes","arm64","verify","prebuilt","/system/app/appstore/appstore.apk","205744",...
```

### 3. Analysis Framework

After collecting one or more test datasets, analyze in this order:

1. Compare only common successful Apps.
2. Check APK version and sha256 before interpreting launch deltas.
3. Compare dexopt filter/reason and oat/vdex state before and after the run.
4. Check whether dex2oat, iowait, thermal, or charging state changed during the run.
5. Interpret launch-time deltas only after the evidence alignment above.

For the OTA 5-Test scenario, continue with the deeper framework below:

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

**Cross-device comparison report**:

```bash
python3 scripts/08_compare_launch_results.py \
  --device DeviceA=evidence/0624_tri/DeviceA_T0 \
  --device DeviceB=evidence/0624_tri/DeviceB_T0 \
  --device DeviceC=evidence/0624_tri/DeviceC_T0 \
  --out evidence/0624_tri/launch_compare.xlsx
```

**The first `--device` is the baseline**; all deltas are relative to it. The report always contains 4 sheets:

| sheet | Content | Scope |
|-------|---------|-------|
| **overview** | All common apps: per device `t1 / 5-run avg / CV% / dexopt / main-thread hook / hookSpan`; non-baseline devices get `Δms / Δ%`; plus `version-aligned / strict-comparable` flags | Broad (all 5 runs) |
| **strict** | Strict-comparable common apps (primary conclusion view) + detail columns: component/displayed/dexopt(filter+reason)/version/sha, and per device strict count/avg/CV/min/max/t1/warm/displayed/cold_window/main-thread hook/worker hook/span/keyword hits, plus Δ for non-baseline devices | Only apps that are strict on every device with aligned launch component / Displayed / version / sha / dexopt |
| **system_state** | Per-device timeline summary (governor / cur_freq / iowait / thermal / dex2oat) to rule out throttling / thermal / background dexopt | Phase-level |
| **summary** | Common count, strict count, per-device means and Δ vs baseline (mean/median) | Aggregate |

`main-thread hook / hookSpan` are filled only when attempt-detail data is present (empty for projects without hook). Use the **strict** sheet for primary conclusions; overview is a broad-scope reference.

---

## Known Limitations

1. **dexopt output varies by Android version**: `02_dump_dexopt_state.sh` supports common Android 12/14 `dumpsys package` formats. If parsing fails on a new platform, add patterns for that device's actual output.

2. **merge_status depends on device command**: The `merge_status` column in `03_timeline_sampler.sh` relies on `cmd update_engine merge_status`. Some devices do not support this command; when unsupported, the column will show `UNKNOWN` without affecting other fields.

3. **CPU and thermal sysfs paths vary by platform**: timeline captures common `/sys/devices/system/cpu/cpufreq/policy*` and `/sys/class/thermal/thermal_zone*` paths. Missing fields are left empty when a device blocks or does not expose a node.

4. **`am start -W` limitation for Launcher**: `com.android.launcher3` (the default Home Activity) is immediately restarted by SystemServer after `force-stop`, causing `TotalTime` to be 0 or abnormal. This is an inherent limitation of the `am start -W` tool, **not a script bug**. It is recommended to exclude Launcher from statistics.

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
