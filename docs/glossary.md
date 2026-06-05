# Glossary

| Term | Definition |
|------|-----------|
| **Cold start (industry)** | `force-stop` followed by first `am start -W` TotalTime. Process cleared, pagecache partially warm. |
| **True cold start** | First launch after `reboot`. Pagecache fully cold. **Not used** in this benchmark. |
| **Warm start** | Repeated launch within seconds. Pagecache fully hot. |
| **Transient** | Period right after OTA/flash when the system is still doing background work (merge, dexopt). |
| **Steady state** | After ≥72h of charging + idle. Background tasks converged. |
| **dexopt** | Android's process of compiling dex bytecode into native code (odex) and/or verified metadata (vdex). |
| **Compiler filter** | The optimization level chosen by dexopt. From slowest to fastest: `run-from-apk` < `extract` < `verify` < `speed-profile` < `speed` < `everything`. |
| **run-from-apk** | No odex/vdex exists. Runtime must extract dex from APK + interpret/JIT. Slowest state. |
| **VAB** | Virtual A/B — Android's seamless update mechanism. After OTA, a background "merge" copies changed blocks. |
| **bg-dexopt** | Background Dex Optimization — Android's periodic job that optimizes Apps while the device is charging and idle. |
| **CV** | Coefficient of Variation = `std/mean`. Measures consistency of repeated launches. |
