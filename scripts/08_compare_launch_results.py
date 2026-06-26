#!/usr/bin/env python3
"""Compare launch-test evidence directories and generate an XLSX report."""

import argparse
import csv
import os
import statistics
import sys

try:
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter
except ImportError:
    print("openpyxl is required: pip3 install openpyxl", file=sys.stderr)
    sys.exit(2)


def read_csv_map(path, key):
    with open(path, newline="", encoding="utf-8") as f:
        return {row[key]: row for row in csv.DictReader(f)}


def read_csv_rows(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def read_launch(path):
    rows = read_csv_map(path, "package")
    for row in rows.values():
        for key in ("t1", "t2", "t3", "t4", "t5", "avg"):
            if key in row:
                row[key] = int(row[key]) if row.get(key) else None
    return rows


def find_single(directory, rel_dir, prefix, suffix):
    path = os.path.join(directory, rel_dir)
    matches = [
        os.path.join(path, name)
        for name in os.listdir(path)
        if name.startswith(prefix) and name.endswith(suffix)
    ]
    if prefix == "apps_launch_":
        matches = [name for name in matches if "apps_launch_attempts_" not in os.path.basename(name)]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one {prefix}*{suffix} under {path}, found {len(matches)}")
    return matches[0]


def mean(values):
    return round(sum(values) / len(values), 1) if values else None


def median(values):
    return round(statistics.median(values), 1) if values else None


def warm_avg(row):
    vals = [row.get(k) for k in ("t2", "t3", "t4", "t5") if row.get(k) is not None]
    return round(sum(vals) / len(vals), 1) if vals else None


def dex_state(device, pkg):
    row = device["dex"].get(pkg, {})
    parts = [row.get("filter", ""), row.get("reason", "")]
    return "/".join([p for p in parts if p])


def version_state(device, pkg):
    row = device["apk"].get(pkg, {})
    parts = [row.get("versionCode", ""), row.get("versionName", "")]
    return "/".join([p for p in parts if p])


def sha_state(device, pkg):
    return device["sha"].get(pkg, {}).get("sha256", "")


def first_nonempty(*values):
    for value in values:
        if value:
            return value
    return ""


def to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def find_optional_single(directory, rel_dir, prefix, suffix):
    path = os.path.join(directory, rel_dir)
    if not os.path.isdir(path):
        return None
    matches = [
        os.path.join(path, name)
        for name in os.listdir(path)
        if name.startswith(prefix) and name.endswith(suffix)
    ]
    return matches[0] if len(matches) == 1 else None


def build_strict_attempts(directory):
    path = find_optional_single(directory, "launch_raw", "included_strict_", ".csv")
    rows = read_csv_rows(path)
    grouped = {}
    for row in rows:
        pkg = row.get("package", "")
        if not pkg:
            continue
        grouped.setdefault(pkg, []).append(row)
    return grouped


def strict_pkg_summary(device, pkg):
    rows = device["strict"].get(pkg, [])
    totals = [v for v in (to_int(r.get("total_time_ms")) for r in rows) if v is not None and v > 0]
    displayed = [v for v in (to_int(r.get("displayed_time_ms")) for r in rows) if v is not None and v > 0]

    def avg_field(field):
        vals = [v for v in (to_int(r.get(field)) for r in rows) if v is not None]
        return mean(vals)

    first = rows[0] if rows else {}
    return {
        "strict_count": len(rows),
        "total_avg_ms": mean(totals),
        "displayed_avg_ms": mean(displayed),
        "activity": first.get("activity", ""),
        "component": first.get("component", ""),
        "displayed_activity": first.get("displayed_activity", ""),
        "final_start_activity": first.get("final_start_activity", ""),
        "version": first_nonempty(
            "/".join([p for p in (first.get("versionCode", ""), first.get("versionName", "")) if p]),
            version_state(device, pkg),
        ),
        "sha": first_nonempty(first.get("apk_sha256", ""), sha_state(device, pkg)),
        "dexopt": first_nonempty(
            "/".join([p for p in (first.get("dexopt_filter", ""), first.get("dexopt_reason", "")) if p]),
            dex_state(device, pkg),
        ),
        "keyword_target_pid_avg": avg_field("keyword_target_pid"),
        "bytehook_target_pid_avg": avg_field("bytehook_target_pid"),
        "rmonitor_target_pid_avg": avg_field("rmonitor_target_pid"),
        "shadowhook_target_pid_avg": avg_field("shadowhook_target_pid"),
        "bugly_target_pid_avg": avg_field("bugly_target_pid"),
        "metadata_note": ";".join(sorted({r.get("metadata_note", "") for r in rows if r.get("metadata_note", "")})),
    }


def values_aligned(values, require_nonempty=True):
    vals = [v for v in values if v]
    if require_nonempty and len(vals) != len(values):
        return False
    if not vals:
        return not require_nonempty
    return len(set(vals)) == 1


def add_rows(ws, rows):
    for row in rows:
        ws.append(row)


def style_workbook(wb):
    for ws in wb.worksheets:
        ws.freeze_panes = "A2"
        ws.auto_filter.ref = ws.dimensions
        for cell in ws[1]:
            cell.font = Font(bold=True)
            cell.fill = PatternFill("solid", fgColor="D9EAF7")
        for col in ws.columns:
            letter = get_column_letter(col[0].column)
            max_len = max(len("" if cell.value is None else str(cell.value)) for cell in col)
            ws.column_dimensions[letter].width = min(max(max_len + 2, 10), 55)
        for row in ws.iter_rows():
            for cell in row:
                cell.alignment = Alignment(vertical="top")


def build_device(label, directory):
    launch = read_launch(find_single(directory, "launch_raw", "apps_launch_", ".csv"))
    device = {
        "label": label,
        "dir": directory,
        "launch": launch,
        "dex": read_csv_map(os.path.join(directory, "dexopt_before.csv"), "pkg"),
        "apk": read_csv_map(os.path.join(directory, "apk_versions_before.csv"), "pkg"),
        "strict": build_strict_attempts(directory),
        "sha": {},
    }
    sha_path = os.path.join(directory, "apk_sha256_before.csv")
    if os.path.exists(sha_path):
        device["sha"] = read_csv_map(sha_path, "pkg")
    return device


def make_three_sheet(wb, devices):
    ws = wb.active
    ws.title = "三设备共同app"
    labels = [d["label"] for d in devices]
    ws.append([
        "package", "activity",
        f"{labels[0]}_avg", f"{labels[1]}_avg", f"{labels[2]}_avg",
        f"{labels[1]}-{labels[0]}_avg_delta",
        f"{labels[2]}-{labels[0]}_avg_delta",
        f"{labels[2]}-{labels[1]}_avg_delta",
        f"{labels[0]}_t1", f"{labels[1]}_t1", f"{labels[2]}_t1",
        f"{labels[1]}-{labels[0]}_t1_delta",
        f"{labels[0]}_warm_t2_t5", f"{labels[1]}_warm_t2_t5", f"{labels[2]}_warm_t2_t5",
        f"{labels[1]}-{labels[0]}_warm_delta",
        f"{labels[0]}_dexopt", f"{labels[1]}_dexopt", f"{labels[2]}_dexopt",
        f"{labels[0]}_version", f"{labels[1]}_version", f"{labels[2]}_version",
        "apk_sha256_same_all3",
    ])
    pkgs = set(devices[0]["launch"])
    for device in devices[1:]:
        pkgs &= set(device["launch"])
    common = [
        pkg for pkg in sorted(pkgs)
        if all(device["launch"][pkg].get("status") == "ok" for device in devices)
    ]
    for pkg in common:
        rows = [device["launch"][pkg] for device in devices]
        warm = [warm_avg(row) for row in rows]
        shas = [sha_state(device, pkg) for device in devices]
        ws.append([
            pkg, rows[0].get("activity", ""),
            rows[0]["avg"], rows[1]["avg"], rows[2]["avg"],
            rows[1]["avg"] - rows[0]["avg"],
            rows[2]["avg"] - rows[0]["avg"],
            rows[2]["avg"] - rows[1]["avg"],
            rows[0]["t1"], rows[1]["t1"], rows[2]["t1"],
            rows[1]["t1"] - rows[0]["t1"],
            warm[0], warm[1], warm[2],
            round(warm[1] - warm[0], 1) if warm[0] is not None and warm[1] is not None else None,
            dex_state(devices[0], pkg), dex_state(devices[1], pkg), dex_state(devices[2], pkg),
            version_state(devices[0], pkg), version_state(devices[1], pkg), version_state(devices[2], pkg),
            len(set(shas)) == 1 and bool(shas[0]),
        ])
    return common


def make_strict_aligned_sheet(wb, devices):
    ws = wb.create_sheet("严格可比共同app"[:31])
    labels = [d["label"] for d in devices]
    header = [
        "package",
        "activity",
        "component",
        "displayed_activity",
        "dexopt",
        "version",
        "apk_sha256",
    ]
    for label in labels:
        header.extend([
            f"{label}_strict_count",
            f"{label}_total_avg_ms",
            f"{label}_displayed_avg_ms",
            f"{label}_keyword_target_pid_avg",
            f"{label}_bytehook_target_pid_avg",
            f"{label}_rmonitor_target_pid_avg",
            f"{label}_shadowhook_target_pid_avg",
            f"{label}_bugly_target_pid_avg",
            f"{label}_metadata_note",
        ])
    if len(devices) >= 2:
        header.extend([
            f"{labels[1]}-{labels[0]}_total_delta",
            f"{labels[1]}-{labels[0]}_displayed_delta",
            f"{labels[1]}_vs_{labels[0]}_pct",
        ])
    ws.append(header)

    pkgs = set(devices[0]["strict"])
    for device in devices[1:]:
        pkgs &= set(device["strict"])

    strict_common = []
    for pkg in sorted(pkgs):
        summaries = [strict_pkg_summary(device, pkg) for device in devices]
        checks = [
            [s["activity"] for s in summaries],
            [s["component"] for s in summaries],
            [s["displayed_activity"] for s in summaries],
            [s["dexopt"] for s in summaries],
            [s["version"] for s in summaries],
            [s["sha"] for s in summaries],
        ]
        if not all(values_aligned(values) for values in checks):
            continue
        if any(s["total_avg_ms"] is None or s["displayed_avg_ms"] is None for s in summaries):
            continue

        strict_common.append(pkg)
        row = [
            pkg,
            summaries[0]["activity"],
            summaries[0]["component"],
            summaries[0]["displayed_activity"],
            summaries[0]["dexopt"],
            summaries[0]["version"],
            summaries[0]["sha"],
        ]
        for summary in summaries:
            row.extend([
                summary["strict_count"],
                summary["total_avg_ms"],
                summary["displayed_avg_ms"],
                summary["keyword_target_pid_avg"],
                summary["bytehook_target_pid_avg"],
                summary["rmonitor_target_pid_avg"],
                summary["shadowhook_target_pid_avg"],
                summary["bugly_target_pid_avg"],
                summary["metadata_note"],
            ])
        if len(devices) >= 2:
            total_delta = summaries[1]["total_avg_ms"] - summaries[0]["total_avg_ms"]
            displayed_delta = summaries[1]["displayed_avg_ms"] - summaries[0]["displayed_avg_ms"]
            row.extend([
                total_delta,
                displayed_delta,
                round(total_delta * 100 / summaries[0]["total_avg_ms"], 1) if summaries[0]["total_avg_ms"] else None,
            ])
        ws.append(row)

    return strict_common


def make_pair_sheet(wb, left, right, name):
    ws = wb.create_sheet(name[:31])
    ws.append([
        "package", "activity",
        f"{left['label']}_status", f"{right['label']}_status",
        f"{left['label']}_avg", f"{right['label']}_avg",
        f"{right['label']}-{left['label']}_avg_delta",
        f"{right['label']}_vs_{left['label']}_pct",
        f"{left['label']}_t1", f"{right['label']}_t1",
        f"{right['label']}-{left['label']}_t1_delta",
        f"{left['label']}_warm_t2_t5", f"{right['label']}_warm_t2_t5",
        f"{right['label']}-{left['label']}_warm_delta",
        f"{left['label']}_dexopt", f"{right['label']}_dexopt", "dexopt_same",
        f"{left['label']}_version", f"{right['label']}_version", "version_same",
        "apk_sha256_same",
    ])
    pkgs = set(left["launch"]) & set(right["launch"])
    common = [
        pkg for pkg in sorted(pkgs)
        if left["launch"][pkg].get("status") == "ok" and right["launch"][pkg].get("status") == "ok"
    ]
    for pkg in common:
        lrow = left["launch"][pkg]
        rrow = right["launch"][pkg]
        lwarm = warm_avg(lrow)
        rwarm = warm_avg(rrow)
        avg_delta = rrow["avg"] - lrow["avg"]
        ws.append([
            pkg, lrow.get("activity", ""),
            lrow.get("status"), rrow.get("status"),
            lrow["avg"], rrow["avg"],
            avg_delta,
            round(avg_delta * 100 / lrow["avg"], 1) if lrow["avg"] else None,
            lrow["t1"], rrow["t1"],
            rrow["t1"] - lrow["t1"],
            lwarm, rwarm,
            round(rwarm - lwarm, 1) if lwarm is not None and rwarm is not None else None,
            dex_state(left, pkg), dex_state(right, pkg), dex_state(left, pkg) == dex_state(right, pkg),
            version_state(left, pkg), version_state(right, pkg), version_state(left, pkg) == version_state(right, pkg),
            sha_state(left, pkg) == sha_state(right, pkg) and bool(sha_state(left, pkg)),
        ])
    return common


def make_summary(wb, devices, three_common, pair_common, strict_common):
    ws = wb.create_sheet("summary")
    labels = [d["label"] for d in devices]
    rows = [
        ["three_device_common_ok_count", len(three_common)],
        ["pair_common_ok_count", len(pair_common)],
        ["strict_aligned_common_count", len(strict_common)],
    ]
    if len(devices) >= 2:
        left, right = devices[0], devices[1]
        for metric in ("avg", "t1"):
            for device in (left, right):
                vals = [device["launch"][pkg][metric] for pkg in pair_common]
                rows.append([f"pair_common_{device['label']}_{metric}_mean", mean(vals)])
                rows.append([f"pair_common_{device['label']}_{metric}_median", median(vals)])
        deltas = [right["launch"][pkg]["avg"] - left["launch"][pkg]["avg"] for pkg in pair_common]
        rows.append([f"{right['label']}-{left['label']}_avg_mean_delta", mean(deltas)])
        rows.append([f"{right['label']}-{left['label']}_avg_median_delta", median(deltas)])
    if three_common:
        for metric in ("avg", "t1"):
            for device in devices:
                vals = [device["launch"][pkg][metric] for pkg in three_common]
                rows.append([f"three_common_{device['label']}_{metric}_mean", mean(vals)])
                rows.append([f"three_common_{device['label']}_{metric}_median", median(vals)])
    if strict_common and len(devices) >= 2:
        left, right = devices[0], devices[1]
        left_vals = [strict_pkg_summary(left, pkg)["total_avg_ms"] for pkg in strict_common]
        right_vals = [strict_pkg_summary(right, pkg)["total_avg_ms"] for pkg in strict_common]
        strict_deltas = [r - l for l, r in zip(left_vals, right_vals)]
        rows.append([f"strict_{left['label']}_total_mean", mean(left_vals)])
        rows.append([f"strict_{right['label']}_total_mean", mean(right_vals)])
        rows.append([f"strict_{right['label']}-{left['label']}_total_mean_delta", mean(strict_deltas)])
        rows.append([f"strict_{right['label']}-{left['label']}_total_median_delta", median(strict_deltas)])
    rows.append(["device_order", " -> ".join(labels)])
    add_rows(ws, rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--device",
        action="append",
        required=True,
        help="LABEL=/path/to/evidence_dir. Provide 2 or 3 devices.",
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    devices = []
    for item in args.device:
        if "=" not in item:
            parser.error("--device must be LABEL=/path")
        label, directory = item.split("=", 1)
        devices.append(build_device(label, directory))
    if len(devices) not in (2, 3):
        parser.error("provide 2 or 3 --device entries")

    wb = Workbook()
    if len(devices) == 3:
        three_common = make_three_sheet(wb, devices)
        pair_common = make_pair_sheet(wb, devices[0], devices[1], f"{devices[1]['label']}_{devices[0]['label']}共同app")
    else:
        wb.active.title = "placeholder"
        wb.remove(wb.active)
        three_common = []
        pair_common = make_pair_sheet(wb, devices[0], devices[1], f"{devices[1]['label']}_{devices[0]['label']}共同app")
    strict_common = make_strict_aligned_sheet(wb, devices)
    make_summary(wb, devices, three_common, pair_common, strict_common)
    style_workbook(wb)
    wb.save(args.out)
    print(args.out)


if __name__ == "__main__":
    main()
