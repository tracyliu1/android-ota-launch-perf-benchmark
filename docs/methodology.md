# Experiment Design Methodology

## 1. Goal

Separate three factors that may affect App cold-start time:

1. **System transient activity** after OTA/flash (VAB merge, dexopt storm, warmup)
2. **ROM itself** (the difference between old and new ROM)
3. **App version change** (versionCode bump may alter startup path)

## 2. The 5-Phase Matrix

| Phase | Device | ROM | Timing | Business Meaning |
|-------|--------|-----|--------|------------------|
| P1 | A | vOld (flash) | Immediately after flash | Baseline before upgrade |
| P2 | A | vNew (OTA) | ~3 min after OTA reboot | Reproduce "OTA is slow" scenario |
| P3 | A | vNew (OTA) | Steady state (≥72h) | OTA path steady state |
| P4 | B | vNew (flash) | Immediately after flash | Clean vNew baseline (no OTA trace) |
| P5 | B | vNew (flash) | Steady state (≥72h) | Flash path steady state |

## 3. Three Core Comparisons

| Comparison | Controlled Variables | Question Answered |
|------------|---------------------|-------------------|
| P1 → P2 → P3 | Same device A, same OTA path | Overall upgrade effect |
| P2 vs P4 | Same vNew, same immediate timing, different path | OTA transient cost vs flash transient cost |
| P3 vs P5 | Same vNew, same steady timing, different path | Does OTA steady state catch up with flash? |

## 4. Why Wait 72 Hours?

Android `BackgroundDexOptJob` requires ALL of the following to trigger:

- `charging = true` (must be plugged in)
- `batteryNotLow` (> 15~20%)
- `deviceIdle = true` (screen off + no user interaction for extended period)
- Period = 24h (max once per day)

Therefore, from OTA completion to full dexopt convergence, **at least 24h of charging + screen-off is needed; 72h (3 days) is recommended** to allow 1~3 scheduling cycles.

## 5. Data Collection Requirements

Every Phase must contain:

- `device_id.txt` — device identity
- `apk_versions_before.csv` — APK version snapshot
- `dexopt_before.csv` / `dexopt_after.csv` — dexopt state before/after test
- `launch_raw/` — launch test raw output
- `timeline/` — system load samples
- `logcat/` — full logcat (optional but recommended)

## 6. Statistical Rigor

- 1 device per path, but **N Apps × 5 launches = many measurements**
- Validate stability via **CV (coefficient of variation)**:
  - CV < 5% → highly stable
  - CV 5~15% → moderate jitter
  - CV > 20% → serious inconsistency
