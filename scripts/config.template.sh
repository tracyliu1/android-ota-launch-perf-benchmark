#!/bin/bash
# config.template.sh — 设备与测试配置模板
#
# 用法:
#   1. cp config.template.sh config.sh
#   2. 按需修改 config.sh
#   3. 所有其他脚本会自动 source 同目录下的 config.sh
#
# 平台说明:
#   本套脚本最初在 Android 12 + MTK 平台上验证。
#   以下命令若涉及平台特有属性，已标注 "[MTK/Android12]"，
#   请根据你的实际设备调整。

# ---------- 设备连接 ----------
# 留空表示自动检测唯一连接的设备（adb devices 只返回1台）
# 多设备时，请填写目标 serial，或 export ANDROID_SERIAL=xxx
DEVICE_SERIAL="${DEVICE_SERIAL:-}"

# ---------- 证据目录设备名 ----------
# 可选：留空时脚本会从 adb 设备属性自动生成；需要固定命名时再手动填写。
# 输出目录会使用 evidence/<MMDD>/<device-tag>_<PHASE>/。
# 例如设置 EVIDENCE_DEVICE_TAG="MyDevice" 且 --phase T0 时：
#   evidence/0617/MyDevice_T0/
EVIDENCE_DEVICE_TAG="${EVIDENCE_DEVICE_TAG:-}"

# ---------- App 清单 ----------
# 每行格式: package/activity
# activity 可写相对路径（如 .MainActivity）或绝对路径
APP_LIST_FILE="${APP_LIST_FILE:-${SCRIPT_DIR}/apps.txt}"

# ---------- 启动测试参数 ----------
# c = 每个 app 启动次数（业界常用 5）
# s = 每次启动间隔秒数（至少 10s，让进程完全回收）
LAUNCH_COUNT="${LAUNCH_COUNT:-5}"
LAUNCH_INTERVAL="${LAUNCH_INTERVAL:-10}"

# ---------- 屏幕控制 ----------
# 测试期间是否强制保持亮屏
# 原因: am start -W TotalTime 测量到首帧绘制，灭屏状态下首帧不画，数据不稳定
# 7 = 充电时保持亮屏（bit0=USB bit1=AC bit2=无线）
STAY_ON_WHILE_PLUGGED="${STAY_ON_WHILE_PLUGGED:-7}"

# ---------- 设备端工作目录 ----------
# 用于存放 timeline、logcat 等临时数据
# 需要设备有写入权限，且空间 >= 2GB
DEVICE_TMPDIR="${DEVICE_TMPDIR:-/data/local/tmp/ota_perf_benchmark}"

# ---------- 平台特性开关 ----------
# 设备是否使用 Virtual A/B (VAB) 分区方案
# 若关闭，脚本会跳过 VAB merge 状态检查
HAS_VAB="${HAS_VAB:-true}"

# 是否采集 dexopt 编译状态 (dumpsys package)
CHECK_DEXOPT="${CHECK_DEXOPT:-true}"

# 是否采集 APK 版本信息 (dumpsys package)
CHECK_APK_VERSIONS="${CHECK_APK_VERSIONS:-true}"

# 是否采集 APK sha256，用于排除同 versionCode 但 APK 内容不同。
CHECK_APK_SHA256="${CHECK_APK_SHA256:-true}"

# 是否采集完整 logcat
CHECK_LOGCAT="${CHECK_LOGCAT:-true}"

# 是否采集系统负载 timeline
CHECK_TIMELINE="${CHECK_TIMELINE:-true}"

# ---------- Timeline 采样 ----------
# Host 端轮询间隔。定位 CPU/IO/供电瞬态时建议 5~10 秒。
TIMELINE_INTERVAL_SEC="${TIMELINE_INTERVAL_SEC:-10}"

# 采集哪几个 CPUFreq policy。MTK 常见为 policy0/policy6；其他平台可按需覆盖。
TIMELINE_CPU_POLICIES=(${TIMELINE_CPU_POLICIES:-0 6})

# 是否在 timeline 中追加电池/充电、CPUFreq、thermal 摘要。
TIMELINE_CAPTURE_BATTERY="${TIMELINE_CAPTURE_BATTERY:-true}"
TIMELINE_CAPTURE_CPUFREQ="${TIMELINE_CAPTURE_CPUFREQ:-true}"
TIMELINE_CAPTURE_THERMAL="${TIMELINE_CAPTURE_THERMAL:-true}"

# ---------- 稳态判定条件 ----------
# 等待稳态时的最小开机时长（分钟）
STEADY_STATE_UPTIME_MIN="${STEADY_STATE_UPTIME_MIN:-60}"

# 连续几轮 loadavg 稳定视为稳态（每轮间隔秒数）
STEADY_STATE_WINDOW_SEC="${STEADY_STATE_WINDOW_SEC:-600}"
STEADY_STATE_LOADAVG_THRESHOLD="${STEADY_STATE_LOADAVG_THRESHOLD:-0.5}"

# ---------- 额外 prop ----------
# 除默认 prop 外，如需 dump 设备特有属性，在此追加
EXTRA_PROPS=(
    # "ro.your.company.hardware.version"
    # "ro.your.company.custom.prop"
)

# ---------- 主机端路径 ----------
# 脚本会自动推导，通常无需修改
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVESTIGATION_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_DIR="$INVESTIGATION_ROOT/evidence"
REPORTS_DIR="$INVESTIGATION_ROOT/reports"

# ---------- 证据归档批次 ----------
# 默认由 scripts/lib_common.sh 使用当天日期 MMDD，例如 evidence/0617/<device-tag>_T0/。
# 同一天重复跑同一批测试时，可设置 EVIDENCE_RUN_TAG 避免覆盖：
#   EVIDENCE_RUN_TAG=0617_run2 bash scripts/06_run_phase_with_timeline.sh --phase T0 -- -c 5 -s 10
# EVIDENCE_RUN_TAG="0617"
