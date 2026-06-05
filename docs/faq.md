# Frequently Asked Questions

## Q1: Can I do this with only one device?

Technically yes, but you lose the **cross-path comparison** (P2 vs P4, P3 vs P5). With one device you can only measure:
- Upgrade effect: P1 → P2 → P3
- Transient cost: P2 vs P3

You **cannot** isolate whether OTA is inherently slower than flash.

## Q2: Do I really have to wait 72 hours?

Yes, if you want a fair comparison. bg-dexopt triggers at most once per 24h, and only when charging + idle. Waiting 72h ensures at least 1~3 cycles have run.

If you test immediately after OTA, you are measuring **transient** state, which is expected to be slower and does not reflect normal user experience after a few days.

## Q3: Can I manually trigger dexopt to avoid waiting?

You can try:
```bash
adb shell cmd package bg-dexopt-job
```
But this may not fully replicate the natural steady state, because:
- It may use different compiler filters than natural bg-dexopt
- It does not account for pagecache warmup and other system settling

For **methodological rigor**, natural waiting is preferred.

## Q4: My device does not use VAB. Is this benchmark still valid?

Yes. The core methodology (transient vs steady, OTA vs flash) applies to any update mechanism. Simply set `HAS_VAB=false` in `config.sh` and skip VAB-related checks.

## Q5: Why not use Systrace / Perfetto instead of `am start -W`?

`am start -W` is the **industry-standard** metric for cold-start comparison. It is:
- Reproducible across devices and teams
- Easy to automate
- Directly comparable with APM tools and Google Macrobenchmark

Systrace/Perfetto are excellent for **root-causing** specific slowdowns, but they are overkill for **comparative benchmarking** and harder to automate at scale.

## Q6: Launcher data is always 0ms. Is this a bug?

No. `am start -W` measures TotalTime until first frame draw. Launcher is the default Home Activity; after `force-stop`, SystemServer immediately restarts it. The measurement window is effectively zero. This is a known limitation of `am start -W`, not a bug. Exclude Launcher from statistics.

## Q7: Why does dexopt parsing fail on my Android 14 device?

`02_dump_dexopt_state.sh` parses `dumpsys package` output using patterns validated on **Android 12 (API 31)**. Google occasionally changes the indentation, field names, or line breaks in `dumpsys package` output across Android versions.

If you see empty filter/reason columns or malformed CSV:
1. Run `adb shell dumpsys package <your.pkg>` manually
2. Inspect the `dexopt` / `compiler filter` section
3. Adjust the `grep` / `sed` patterns in `02_dump_dexopt_state.sh` accordingly

We welcome PRs that add multi-version parsing support.

## Q8: Why is merge_status always UNKNOWN?

`03_timeline_sampler.sh` attempts to read merge status via:
```bash
adb shell cmd update_engine merge_status
```

Not all devices implement this command. If your device returns `UNKNOWN`:
- The timeline CSV will still contain all other fields (loadavg, mem, dex2oat, iowait)
- You can verify VAB merge completion alternatively via `getprop ro.boot.slot_suffix`
- If your device does not use VAB at all, set `HAS_VAB=false` in `config.sh`

## Q9: Can this framework be used for non-OTA scenarios?

Absolutely. The 5-Phase design can be adapted for:
- ROM A vs ROM B (any two ROMs)
- Before/after kernel upgrade
- Before/after framework change
- Any scenario where you need **transient vs steady** and **cross-device** comparison
