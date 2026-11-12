#!/usr/bin/env python3
"""Which records of a bench run the Mac's load disturbed, and how (docs/CLI.md, "System load").

Usage:
  scripts/cli-load.py RUN/release.jsonl RUN/next.jsonl [--clean-dir RUN/clean] [--min-clean 3]
                      [--base release] [--tolerance 3] [--prefill-tolerance 8] [--out RUN/load.txt]
                      [--device iPhone]

A build gives the same reply to the same case every time (greedy decoding), so its runs of a
case do the same work: the same decode steps, the same prompt. Load only ever makes that work
slower. So the fastest run of a case is the build's speed on a quiet Mac, and a run is
undisturbed when its decode step and its prefill cost within a few percent of that best
(--tolerance, --prefill-tolerance). Each build is held to its own best, never to another's.

The runtime's telemetry says where a disturbed run lost its time: a decode step is the time
the GPU took (`gpu.wait.decode`) plus the host's side (sampling, copies, the stream). Something
else on the GPU stretches the first; a busy CPU, or the scheduler moving the runtime's threads
to efficiency cores, stretches the second. Records without span timings (telemetry level 1, the
scripted engine) are judged on their speeds alone.

It also prints each build's best run of each case, against the base build's (--base, default
the first file's): the speed on a quiet Mac, which holds even when most runs were disturbed.

--device iPhone reads an iPhone run (scripts/phone-bench.sh) the same way, in the phone's words:
there, heat is what stretches the GPU's side.

--clean-dir writes each file again without its disturbed records, for the comparison.
--self-test checks the reading on made-up records (scripts/cli-check.sh runs it).
--min-clean N makes the exit code 3 when a build has fewer than N undisturbed runs of a case,
so the caller can run more rounds. A case run once has nothing to be held to: its records
count as undisturbed unless the tool flagged them itself (`suspect`).
"""
import argparse
import json
import os
import sys
from collections import Counter, defaultdict


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def span(record, name):
    spans = (record.get("telemetry") or {}).get("spans") or {}
    entry = spans.get(name) or {}
    return entry.get("total_ms") or 0.0, entry.get("count") or 0


def costs(record):
    """A record's costs: ms per decode step (with the GPU's and the host's share when the
    telemetry has them) and ms per prompt token."""
    step_ms, steps = span(record, "decode.step")
    gpu_ms, _ = span(record, "gpu.wait.decode")
    prefill_ms, _ = span(record, "turn.prefill")
    out: dict = {"gpu": None, "host": None}
    if steps and step_ms:
        out["step"] = step_ms / steps
        if gpu_ms:
            out["gpu"] = gpu_ms / steps
            out["host"] = max(0.0, (step_ms - gpu_ms) / steps)
    else:
        speed = record.get("decodeTPS") or 0
        out["step"] = 1000 / speed if speed else None
    tokens = record.get("prefill") or 0
    if prefill_ms and tokens:
        out["prefill"] = prefill_ms / tokens
    else:
        speed = record.get("prefillTPS") or 0
        out["prefill"] = 1000 / speed if speed else None
    return out


def self_test():
    """Made-up runs of one case: two quiet, one slowed on the host's side, one on the GPU's."""
    import io
    import tempfile
    from contextlib import redirect_stdout

    def record(step, gpu, prefill_ms=500.0, warmup=False):
        return {
            "label": "a", "id": "case", "warmup": warmup, "prefill": 1000, "decode": 100,
            "decodeTPS": 2.5 * 1000 / step, "prefillTPS": 1000 / prefill_ms * 1000, "ttft": 0.3,
            "telemetry": {"spans": {
                "decode.step": {"total_ms": step * 40, "count": 40},
                "gpu.wait.decode": {"total_ms": gpu * 40, "count": 40},
                "turn.prefill": {"total_ms": prefill_ms, "count": 1}}},
        }

    runs = [record(25, 23, warmup=True), record(25.0, 23.4), record(25.3, 23.6), record(30.0, 23.5), record(50.0, 48.0),
            record(25.2, 23.5, prefill_ms=600.0)]
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "a.jsonl")
        with open(path, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in runs)
        out = io.StringIO()
        sys.argv = [sys.argv[0], path, "--clean-dir", os.path.join(folder, "clean"), "--min-clean", "3"]
        try:
            with redirect_stdout(out):
                main()
        except SystemExit as stop:
            code = stop.code
        text = out.getvalue()
        kept = load(os.path.join(folder, "clean", "a.jsonl"))
    problems = []
    if "+20 % host" not in text:
        problems.append("the host's slowdown isn't named")
    if "+100 % GPU" not in text:
        problems.append("the GPU's slowdown isn't named")
    if "+20 % prefill" not in text:
        problems.append("the slow prefill isn't named")
    if len(kept) != 3 or not kept[0].get("warmup"):
        problems.append(f"{len(kept)} records kept, 3 expected (the warm-up and the two quiet runs)")
    if code != 3:
        problems.append(f"exit code {code}, 3 expected (two undisturbed runs, three wanted)")
    if problems:
        print("cli-load.py self-test FAILED: " + "; ".join(problems))
        print(text)
        sys.exit(1)
    print("cli-load.py self-test passed.")
    sys.exit(0)


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    parser.add_argument("files", nargs="+")
    parser.add_argument("--tolerance", type=float, default=3.0, help="percent over the best decode step (default 3)")
    parser.add_argument("--prefill-tolerance", type=float, default=8.0, help="percent over the best prefill (default 8)")
    parser.add_argument("--base", help="the build the best runs are compared with (default: the first file's)")
    parser.add_argument("--clean-dir", help="write each file here without its disturbed records")
    parser.add_argument("--min-clean", type=int, default=0, help="exit 3 when a build has fewer undisturbed runs of a case")
    parser.add_argument("--out", help="also write the report here")
    parser.add_argument("--device", default="Mac", help="where the records were made (Mac, the default, or iPhone)")
    args = parser.parse_args()
    on_mac = args.device == "Mac"

    files = {path: load(path) for path in args.files}
    groups = defaultdict(list)  # (build, case) -> [(path, index, record, costs)]
    for path, records in files.items():
        for index, record in enumerate(records):
            if record.get("warmup") or record.get("error"):
                continue
            groups[(record.get("label", "?"), record.get("id", "?"))].append((path, index, record, costs(record)))

    disturbed = set()  # (path, index)
    lines = []
    causes = Counter()
    per_build = defaultdict(lambda: [0, 0])  # build -> [undisturbed, runs]
    short = []
    also = Counter()
    lines.append(
        f"== Load: a run is undisturbed within {args.tolerance:g} % of its build's best decode step "
        f"and {args.prefill_tolerance:g} % of its best prefill")
    lines.append(f"  {'build':<10} {'case':<16} {'runs':>4} {'clean':>5}  {'best step ms (GPU + host)':<27} disturbed runs")
    for (build, case), runs in groups.items():
        steps = [c["step"] for _, _, _, c in runs if c["step"]]
        prefills = [c["prefill"] for _, _, _, c in runs if c["prefill"]]
        best_step = min(steps) if steps else None
        best_prefill = min(prefills) if prefills else None
        best = min((c for _, _, _, c in runs if c["step"]), key=lambda c: c["step"], default=None)
        notes = []
        clean = 0
        for path, index, record, cost in runs:
            reasons = []
            if len(runs) < 2:
                # Nothing to hold it to: only what the tool saw itself.
                if record.get("suspect"):
                    reasons.append("flagged by the tool")
            else:
                if cost["step"] and best_step and cost["step"] > best_step * (1 + args.tolerance / 100):
                    over = 100 * (cost["step"] / best_step - 1)
                    where = "decode"
                    if cost["host"] is not None and best and best["host"] is not None:
                        extra_host = cost["host"] - best["host"]
                        extra_gpu = cost["gpu"] - best["gpu"]
                        total = extra_host + extra_gpu
                        if total > 0:
                            share = extra_host / total
                            where = "host" if share >= 0.67 else "GPU" if share <= 0.33 else "host and GPU"
                    causes[where] += 1
                    reasons.append(f"+{over:.0f} % {where}")
                if cost["prefill"] and best_prefill and cost["prefill"] > best_prefill * (1 + args.prefill_tolerance / 100):
                    over = 100 * (cost["prefill"] / best_prefill - 1)
                    if not reasons:
                        causes["prefill"] += 1
                    reasons.append(f"+{over:.0f} % prefill")
            for reason in record.get("suspect") or []:
                also[reason.split(" used ")[0] if " used " in reason else reason.split(" was ")[0]] += 1
            if reasons:
                disturbed.add((path, index))
                notes.append(", ".join(reasons))
            else:
                clean += 1
        per_build[build][0] += clean
        per_build[build][1] += len(runs)
        if clean < args.min_clean:
            short.append((build, case, clean))
        if best and best["gpu"] is not None:
            best_text = f"{best['step']:.1f} ({best['gpu']:.1f} + {best['host']:.1f})"
        else:
            best_text = f"{best_step:.1f}" if best_step else "?"
        lines.append(f"  {build:<10} {case:<16} {len(runs):>4} {clean:>5}  {best_text:<27} {'; '.join(notes) or '-'}")

    total_clean = sum(v[0] for v in per_build.values())
    total = sum(v[1] for v in per_build.values())
    lines.append("  " + "; ".join(f"{build}: {v[0]} of {v[1]} undisturbed" for build, v in per_build.items()))
    if causes:
        names = {
            "host": "the host's side of a step (a busy CPU, or the runtime's threads on efficiency cores)",
            "GPU": "the GPU's side (something else on the GPU)" if on_mac else "the GPU's side (heat, or something else on the GPU)",
            "host and GPU": "both sides", "decode": "decode (no span timings to say where)",
            "prefill": "prefill only",
        }
        lines.append("  Disturbed by: " + "; ".join(f"{names[k]} {n}" for k, n in causes.most_common()))
    if also:
        lines.append("  The tool's own flags: " + "; ".join(f"{k} ({n})" for k, n in also.most_common()))
    rates = {build: 1 - v[0] / v[1] for build, v in per_build.items() if v[1]}
    if len(rates) > 1 and max(rates.values()) - min(rates.values()) >= 0.25 and total >= 16:
        worst = max(rates, key=lambda build: rates[build])
        lines.append(
            f"  ! {worst} was disturbed much more often than the others ({100 * rates[worst]:.0f} % of its runs). "
            f"The builds took turns, so if that repeats it's the build, not the {args.device}: read its slow runs.")
    if total and total_clean / total < 0.5:
        lines.append(
            "  ! More than half the runs were disturbed: the Mac wasn't quiet. Run it again (scripts/mac-ready.sh)." if on_mac
            else f"  ! More than half the runs were disturbed: the {args.device} was warm or busy. Run it again cool, plugged in, nothing else open.")
    for build, case, clean in short:
        lines.append(f"  ! {build} has {clean} undisturbed run(s) of {case}: fewer than {args.min_clean}.")

    # Each build's best run of each case: its speed on a quiet Mac.
    builds = list(dict.fromkeys(build for build, _ in groups))
    base = args.base if args.base in builds else (builds[0] if builds else None)
    cases = list(dict.fromkeys(case for _, case in groups))
    metrics = [("decode tok/s", "decodeTPS", max), ("prefill tok/s", "prefillTPS", max), ("first token s", "ttft", min)]
    lines.append("")
    quiet = "a quiet Mac" if on_mac else f"a cool {args.device}"
    lines.append(f"== On {quiet}: each build's best run of each case (change against {base})")
    for title, key, pick in metrics:
        lines.append(f"  {title:<14} " + " ".join(f"{build:>22}" for build in builds))
        changes = defaultdict(list)
        for case in cases:
            cells = []
            best_base = None
            values = {}
            for build in builds:
                found = [r.get(key) for _, _, r, _ in groups.get((build, case), []) if r.get(key)]
                values[build] = pick(found) if found else None
            best_base = values.get(base)
            for build in builds:
                value = values[build]
                if value is None:
                    cells.append(f"{'-':>22}")
                elif build == base or not best_base:
                    cells.append(f"{value:>22.2f}" if key == "ttft" else f"{value:>22.1f}")
                else:
                    change = 100 * (value / best_base - 1)
                    changes[build].append(value / best_base)
                    number = f"{value:.2f}" if key == "ttft" else f"{value:.1f}"
                    cells.append(f"{number + f' ({change:+.1f} %)':>22}")
            lines.append(f"  {case:<14} " + " ".join(cells))
        for build, ratios in changes.items():
            product = 1.0
            for ratio in ratios:
                product *= ratio
            lines.append(f"  {build} against {base}: {100 * (product ** (1 / len(ratios)) - 1):+.1f} % (geometric mean, {len(ratios)} cases)")

    report = "\n".join(lines)
    print(report)
    if args.out:
        with open(args.out, "w") as f:
            f.write(report + "\n")
    if args.clean_dir:
        os.makedirs(args.clean_dir, exist_ok=True)
        for path, records in files.items():
            with open(os.path.join(args.clean_dir, os.path.basename(path)), "w") as f:
                for index, record in enumerate(records):
                    if (path, index) not in disturbed:
                        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    sys.exit(3 if short else 0)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        self_test()
    main()
