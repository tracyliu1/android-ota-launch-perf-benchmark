# Complete Runbook

## Pre-Flight Checklist

- [ ] Two identical devices (same model, same batch)
- [ ] Both fully charged before starting
- [ ] Host machine with `adb`, `python3`, and `openpyxl`
- [ ] App list prepared (`scripts/apps.txt`) — strict intersection of packages present on both ROMs
- [ ] `scripts/config.sh` created from `config.template.sh`

## Phase T1: vOld Flash Baseline (Device A)

1. Flash vOld ROM to device A
2. Wait for boot completion (`getprop sys.boot_completed == 1`)
3. Run `bash 00_env_check.sh --phase T1_Demo`
4. Start timeline and logcat
5. Snapshot APK versions and dexopt (before)
6. Run launch test: `bash 05_run_launch_test.sh --phase T1_Demo`
7. Snapshot dexopt (after)
8. Stop timeline/logcat and archive

## Phase T2: OTA Immediate (Device A)

1. Trigger OTA upgrade to vNew on device A
2. Wait for OTA installation and automatic reboot
3. Wait ~3 minutes after `sys.boot_completed == 1`
4. Do **NOT** stop timeline if it is meant to span T2→T3
5. Run launch test: `bash 05_run_launch_test.sh --phase T2_Demo`
6. Snapshot dexopt (after)
7. Archive (skip timeline/logcat if they continue)

## Phase T3: OTA Steady State (Device A)

1. Plug in charger, turn screen off, place in cool area
2. **Do NOT touch the device** for ≥72 hours
3. Host can poll steady-state conditions periodically:
   ```bash
   adb shell pidof dex2oat
   adb shell cat /proc/loadavg
   ```
4. After 72h, wake device and verify steady-state checklist
5. Run launch test: `bash 05_run_launch_test.sh --phase T3_Demo`
6. Stop continuous timeline/logcat
7. Run `split-continuous` to slice timeline into T2 and T3 windows
8. Archive

## Phase T4: vNew Flash Immediate (Device B)

1. Flash vNew ROM to device B
2. Wait for boot completion
3. Start timeline and logcat
4. Run launch test: `bash 05_run_launch_test.sh --phase T4_Demo`
5. Archive

## Phase T5: vNew Flash Steady State (Device B)

Same as T3, but for device B.

## Platform Compatibility Notes

### dexopt Parsing (Android Version Dependency)

`02_dump_dexopt_state.sh` parses `dumpsys package` output using patterns validated on **Android 12 (API 31)**. If you run on Android 13/14/15 and see empty filter/reason columns:
- Run `adb shell dumpsys package <your.pkg>` manually
- Compare the actual output with the parser regexes in the script
- Adjust `grep` / `sed` patterns as needed

### merge_status (Device Command Dependency)

`03_timeline_sampler.sh` attempts to read VAB merge status via `cmd update_engine merge_status`. If your device does not support this command, the `merge_status` column will show `UNKNOWN`. This is expected and does not affect other timeline fields.

### Launcher Measurement Limitation

`am start -W` cannot reliably measure `com.android.launcher3` because SystemServer restarts it immediately after `force-stop`. This is an Android tool limitation, not a script bug. Exclude Launcher from your statistics.

## Common Failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `am start -W` returns no TotalTime | Activity name mismatch or app crash | Verify activity name in `apps.txt` |
| Multiple devices error | More than one Android device connected | `export ANDROID_SERIAL=xxx` |
| `dexopt_before.csv` empty or malformed | `dumpsys package` format differs | Check Android version; adjust parser |
| Timeline sampler stops early | Host sleep or adb disconnect | Run on a host that does not sleep |
| CV very high (>20%) at steady state | Thermal throttling or background app | Check temperature; ensure no other apps running |
