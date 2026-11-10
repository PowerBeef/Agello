#!/usr/bin/env python3
"""Judge the replies of `agello bench` runs (docs/CLI.md) with the bench's answer checks.

Usage: scripts/cli-report.py RUN.jsonl [RUN.jsonl ...] [--out REPORT.md]

Reads the records the Mac command line wrote (one JSON line per reply), runs each reply through
scripts/bench/checks.py (the checks the iPhone bench uses), and writes a report beside the first
file: REPORT.md and REPORT.json. A reply seen before (same case, same text) keeps its verdict, so
repeated greedy runs cost one check.

The report gives, per build (`label`) and case: how the replies ended, their speed, and how often
each check passed over the runs. Exits 1 when a reply didn't end by itself.

Run it after the measuring is done: the checks load a web view, a compiler and pytest, and would
disturb speeds measured at the same time.
"""
import collections, hashlib, json, os, statistics, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(root, "scripts", "bench"))
import checks  # noqa: E402

arguments = sys.argv[1:]
out = None
if "--out" in arguments:
    index = arguments.index("--out")
    out = arguments[index + 1]
    del arguments[index:index + 2]
if not arguments:
    sys.exit(__doc__)
out = out or os.path.splitext(arguments[0])[0] + ".report.md"

records = []
for path in arguments:
    for line in open(path):
        if line.strip():
            record = json.loads(line)
            if not record.get("warmup"):
                records.append(record)
if not records:
    sys.exit("No records.")

# Verdicts kept from an earlier report of the same files, by case and text.
cache_path = os.path.splitext(out)[0] + ".json"
verdicts = {}
if os.path.exists(cache_path):
    verdicts = json.load(open(cache_path)).get("verdicts", {})

problems = []
for record in records:
    case, _, turn = record["id"].partition("/")
    key = hashlib.sha256((record["id"] + "\0" + record["output"]).encode()).hexdigest()[:20]
    if key not in verdicts:
        verdict, failed = checks.judge(case, int(turn or 1), record["output"])
        verdicts[key] = {"verdict": verdict, "failed": failed}
    record["verdictKey"] = key
    record["failedChecks"] = verdicts[key]["failed"]
    if record.get("ended") != "model":
        problems.append(f"{record['label']} {record['id']} (rep {record['rep']}): ended by {record.get('ended')}")

groups = collections.OrderedDict()
for record in records:
    groups.setdefault((record["label"], record["id"]), []).append(record)


def median(values):
    values = [value for value in values if value]
    return statistics.median(values) if values else 0


def interval(passed, total):
    """A 95 % Wilson interval for a pass rate, in percent."""
    if total == 0:
        return (0, 0)
    z, rate = 1.96, passed / total
    centre = (rate + z * z / (2 * total)) / (1 + z * z / total)
    half = z * ((rate * (1 - rate) / total + z * z / (4 * total * total)) ** 0.5) / (1 + z * z / total)
    return (round(100 * max(0, centre - half)), round(100 * min(1, centre + half)))


summary = []
lines = [f"# Mac command line bench: {', '.join(os.path.basename(path) for path in arguments)}", ""]
machine = records[0].get("machine", {})
build = (machine.get("runtimeBuild") or {}).get("build_id", "no build id")
lines += [f"{machine.get('chip', '?')}, {machine.get('os', '?')}; first record's runtime build {build}.", ""]
lines += ["| Build | Case | Runs | Ended | Tokens | tok/s | First token | Checks passed | Failing |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
for (label, case), rows in groups.items():
    ended = collections.Counter(row.get("ended", "?") for row in rows)
    clean = sum(1 for row in rows if not row["failedChecks"])
    failing = collections.Counter(check for row in rows for check in row["failedChecks"])
    low, high = interval(clean, len(rows))
    entry = {
        "label": label, "id": case, "runs": len(rows), "ended": dict(ended),
        "outputTokens": median(row.get("decode") for row in rows),
        "decodeTPS": round(median(row.get("decodeTPS") for row in rows), 1),
        "ttft": round(median(row.get("ttft") for row in rows), 2),
        "passed": clean, "passRateInterval": [low, high], "failing": dict(failing),
        "distinctReplies": len({row["verdictKey"] for row in rows}),
        "suspect": sum(1 for row in rows if row.get("suspect")),
    }
    summary.append(entry)
    rate = f"{clean}/{len(rows)}" + (f" ({low}–{high} %)" if len(rows) > 1 else "")
    lines.append(
        f"| {label} | {case} | {len(rows)} | {', '.join(f'{name} {count}' if len(ended) > 1 else name for name, count in ended.items())} | "
        f"{entry['outputTokens']:.0f} | {entry['decodeTPS']:.1f} | {entry['ttft']:.2f} s | {rate} | "
        f"{'; '.join(f'{check} ×{count}' if len(rows) > 1 else check for check, count in failing.items()) or 'none'} |")
lines.append("")
if any(entry["runs"] > 1 for entry in summary):
    lines += ["Speeds are medians over the runs. The interval after a pass rate is its 95 % range (Wilson).", ""]
if problems:
    lines += ["## Replies that didn't end by themselves", ""] + [f"- {problem}" for problem in problems] + [""]

open(out, "w").write("\n".join(lines))
json.dump({"files": arguments, "summary": summary, "problems": problems, "verdicts": verdicts}, open(cache_path, "w"), indent=1, sort_keys=True)
print("\n".join(lines))
print(f"Report: {out}")
sys.exit(1 if problems else 0)
