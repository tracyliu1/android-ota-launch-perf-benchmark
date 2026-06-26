#!/usr/bin/env python3
"""Classify launch attempts into strict/reference/excluded buckets."""

import argparse
import csv
import os
from collections import defaultdict


PERMISSION_OR_EXTERNAL_MARKERS = (
    "com.android.permissioncontroller",
    "com.android.packageinstaller",
)


def read_csv(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_csv(path, rows, fieldnames):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def index_by_pkg(rows):
    return {row.get("pkg") or row.get("package"): row for row in rows}


def is_positive_int(value):
    try:
        return int(value) > 0
    except (TypeError, ValueError):
        return False


def same_nonempty(values):
    vals = [v for v in values if v]
    return bool(vals) and len(vals) == len(values) and len(set(vals)) == 1


def classify_attempt(row, apk, sha, dex):
    reasons = []
    warnings = []

    pkg = row.get("package", "")
    status = row.get("status", "")
    launch_state = row.get("launch_state", "")
    total_time = row.get("total_time_ms", "")
    wait_time = row.get("wait_time_ms", "")
    displayed_activity = row.get("displayed_activity", "")
    displayed_time = row.get("displayed_time_ms", "")
    am_activity = row.get("am_activity", "")
    first_start = row.get("first_start_activity", "")
    final_start = row.get("final_start_activity", "")

    apk_row = apk.get(pkg, {})
    sha_row = sha.get(pkg, {})
    dex_row = dex.get(pkg, {})

    if apk_row and apk_row.get("installed") not in ("yes", "true", "1"):
        reasons.append("missing_package")
    if sha_row and sha_row.get("status") not in ("", "ok"):
        reasons.append("sha256_missing")
    if dex_row and dex_row.get("installed") not in ("yes", "true", "1"):
        reasons.append("dexopt_missing")

    if status != "ok":
        reasons.append("status_not_ok")
    if launch_state != "COLD":
        if launch_state == "UNKNOWN (0)" and displayed_activity and displayed_time:
            warnings.append("launch_state_unknown")
        else:
            reasons.append("not_cold")
    if total_time:
        if not is_positive_int(total_time):
            reasons.append("total_time_zero")
    else:
        if displayed_activity and displayed_time:
            warnings.append("total_time_missing")
        else:
            reasons.append("total_time_missing")
    if wait_time and not is_positive_int(wait_time):
        warnings.append("wait_time_zero")
    if not displayed_activity:
        reasons.append("displayed_missing")
    if displayed_activity and not displayed_time:
        reasons.append("displayed_time_parse_error")
    metadata_notes = []

    if am_activity and displayed_activity and am_activity != displayed_activity:
        # Some launchers intentionally report a pre-start Activity while Displayed is final.
        # Treat same-package alias/pre-start differences as metadata, not a comparability failure.
        if not displayed_activity.startswith(pkg + "/"):
            reasons.append("displayed_activity_mismatch")
        else:
            metadata_notes.append("am_activity_differs_from_displayed")
    if final_start and displayed_activity and final_start != displayed_activity:
        metadata_notes.append("final_start_differs_from_displayed")
    if first_start and final_start and first_start != final_start:
        metadata_notes.append("activity_chain_multi_step")
    for marker in PERMISSION_OR_EXTERNAL_MARKERS:
        if marker in am_activity or marker in displayed_activity:
            reasons.append("permission_or_external_activity")

    if reasons:
        bucket = "excluded"
    elif warnings:
        bucket = "reference_only"
    else:
        bucket = "strict_comparable"

    out = dict(row)
    out.update(
        {
            "classification": bucket,
            "filter_reason": ";".join(dict.fromkeys(reasons)),
            "warning_reason": ";".join(dict.fromkeys(warnings)),
            "metadata_note": ";".join(dict.fromkeys(metadata_notes)),
            "versionCode": apk_row.get("versionCode", ""),
            "versionName": apk_row.get("versionName", ""),
            "codePath": apk_row.get("codePath", ""),
            "apk_sha256": sha_row.get("sha256", ""),
            "dexopt_filter": dex_row.get("filter", ""),
            "dexopt_reason": dex_row.get("reason", ""),
        }
    )
    return out


def build_per_app_summary(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["package"], row["activity"])].append(row)

    out = []
    for (pkg, activity), attempts in sorted(grouped.items()):
        strict = [r for r in attempts if r["classification"] == "strict_comparable"]
        reference = [r for r in attempts if r["classification"] == "reference_only"]
        excluded = [r for r in attempts if r["classification"] == "excluded"]
        times = [int(r["total_time_ms"]) for r in strict if is_positive_int(r.get("total_time_ms"))]
        displayed = [int(r["displayed_time_ms"]) for r in strict if is_positive_int(r.get("displayed_time_ms"))]
        out.append(
            {
                "package": pkg,
                "activity": activity,
                "attempts": len(attempts),
                "strict_count": len(strict),
                "reference_count": len(reference),
                "excluded_count": len(excluded),
                "strict_total_avg_ms": round(sum(times) / len(times), 1) if times else "",
                "strict_displayed_avg_ms": round(sum(displayed) / len(displayed), 1) if displayed else "",
                "filter_reasons": ";".join(sorted({r["filter_reason"] for r in excluded if r["filter_reason"]})),
                "warning_reasons": ";".join(sorted({r["warning_reason"] for r in reference if r["warning_reason"]})),
            }
        )
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase-dir", required=True, help="evidence/<run>/<device_phase> directory")
    parser.add_argument("--phase", required=True)
    parser.add_argument("--suffix", default="before")
    args = parser.parse_args()

    phase_dir = args.phase_dir
    launch_dir = os.path.join(phase_dir, "launch_raw")
    detail_path = os.path.join(launch_dir, f"apps_launch_attempts_detail_{args.phase}.csv")
    apk_path = os.path.join(phase_dir, f"apk_versions_{args.suffix}.csv")
    sha_path = os.path.join(phase_dir, f"apk_sha256_{args.suffix}.csv")
    dex_path = os.path.join(phase_dir, f"dexopt_{args.suffix}.csv")

    attempts = read_csv(detail_path)
    if not attempts:
        raise SystemExit(f"missing or empty attempts detail CSV: {detail_path}")

    apk = index_by_pkg(read_csv(apk_path))
    sha = index_by_pkg(read_csv(sha_path))
    dex = index_by_pkg(read_csv(dex_path))

    classified = [classify_attempt(row, apk, sha, dex) for row in attempts]
    fieldnames = list(classified[0].keys())

    classified_path = os.path.join(launch_dir, f"apps_launch_attempts_classified_{args.phase}.csv")
    strict_path = os.path.join(launch_dir, f"included_strict_{args.phase}.csv")
    reference_path = os.path.join(launch_dir, f"reference_only_{args.phase}.csv")
    excluded_path = os.path.join(launch_dir, f"excluded_{args.phase}.csv")
    summary_path = os.path.join(launch_dir, f"per_app_classification_summary_{args.phase}.csv")

    write_csv(classified_path, classified, fieldnames)
    write_csv(strict_path, [r for r in classified if r["classification"] == "strict_comparable"], fieldnames)
    write_csv(reference_path, [r for r in classified if r["classification"] == "reference_only"], fieldnames)
    write_csv(excluded_path, [r for r in classified if r["classification"] == "excluded"], fieldnames)

    summary = build_per_app_summary(classified)
    write_csv(
        summary_path,
        summary,
        [
            "package",
            "activity",
            "attempts",
            "strict_count",
            "reference_count",
            "excluded_count",
            "strict_total_avg_ms",
            "strict_displayed_avg_ms",
            "filter_reasons",
            "warning_reasons",
        ],
    )

    print(classified_path)
    print(strict_path)
    print(reference_path)
    print(excluded_path)
    print(summary_path)


if __name__ == "__main__":
    main()
