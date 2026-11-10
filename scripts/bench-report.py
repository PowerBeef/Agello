#!/usr/bin/env python3
"""Join a bench run's three layers into one report (docs/HARNESS.md).

Usage: scripts/bench-report.py OUT STARTED [PREVIOUS]
  OUT       the harness folder (build/device-harness): attachments/bench/ holds what the UI
            driver saw, bench/traces/ the app's traces pulled from the phone.
  STARTED   the run's start, ISO 8601 UTC: older traces belong to other runs.
  PREVIOUS  the report.json of the run this one resumes: its cases that weren't run again stay.

       scripts/bench-report.py --remaining REPORT.json BenchCases.swift
  Prints the case ids REPORT doesn't hold complete, comma-separated (for BENCH_RESUME=1).

Writes OUT/bench/report.json, report.md and each reply as Markdown, and compares the run with
scripts/bench/baseline.json (BENCH_ACCEPT=1 makes this run the baseline). Exits 1 when a case
has no trace, didn't end by itself, or the screen and the trace disagree.
"""
import datetime, json, os, re, shutil, subprocess, sys, tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def complete(case):
    """A turn the report holds whole: traced, ended by the model, on screen as traced."""
    return case.get("ended") == "model" and case.get("screenAgrees") and not case.get("interrupted")


if sys.argv[1] == "--remaining":
    previous = json.load(open(sys.argv[2]))
    done = {}
    for case in previous.get("cases", []):
        name = case["id"].split("/")[0]
        done[name] = done.get(name, True) and complete(case)
    ids = re.findall(r'BenchCase\(\s*id: "([^"]+)"', open(sys.argv[3]).read())
    print(",".join(name for name in ids if not done.get(name)))
    sys.exit(0)

out, started = sys.argv[1], sys.argv[2]
previous_report = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
bench = os.path.join(out, "bench")
os.makedirs(bench, exist_ok=True)


def when(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


# 1. The surface: the driver's rows, screen texts and screenshots (xcresult attachments).
surface, files = {"rows": []}, {}
folder = os.path.join(out, "attachments", "bench")
manifest = os.path.join(folder, "manifest.json")
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for attachment in test.get("attachments", []):
            name = re.sub(r"_\d+_[0-9A-F-]{36}(\.\w+)?$", r"\1", attachment["suggestedHumanReadableName"])
            files[name] = os.path.join(folder, attachment["exportedFileName"])
    # The driver attaches its rows after every case: the fullest copy is the run's.
    for test in json.load(open(manifest)):
        for attachment in test.get("attachments", []):
            if attachment["suggestedHumanReadableName"].startswith("bench-surface"):
                candidate = json.load(open(os.path.join(folder, attachment["exportedFileName"])))
                if len(candidate["rows"]) > len(surface["rows"]):
                    surface = candidate

# 2 and 3. The app's traces of this run, each with the engine's telemetry.
traces = []
trace_folder = os.path.join(bench, "traces")
for name in sorted(os.listdir(trace_folder)) if os.path.isdir(trace_folder) else []:
    try:
        trace = json.load(open(os.path.join(trace_folder, name)))
    except (OSError, ValueError):
        continue
    if when(trace["startedAt"]) >= when(started) - datetime.timedelta(seconds=5):
        traces.append(trace)


def spoken(text):
    """Letters and digits only, without citation markers: the screen's text is the reply as
    VoiceOver reads it."""
    return re.sub(r"[^0-9a-z]", "", re.sub(r"\[\d+\]", "", text).lower())


def engine_summary(telemetry):
    before, after = telemetry.get("before", {}), telemetry.get("after", {})
    if not after:
        return {}
    counters = {
        key: value - before.get("counters", {}).get(key, 0)
        for key, value in after.get("counters", {}).items()
        if isinstance(value, (int, float)) and value != before.get("counters", {}).get(key, 0)
    }
    spans = {}
    for key, span in after.get("spans", {}).items():
        total = span.get("total_ms", 0) - before.get("spans", {}).get(key, {}).get("total_ms", 0)
        count = span.get("count", 0) - before.get("spans", {}).get(key, {}).get("count", 0)
        if total >= 1:
            spans[key] = {"total_ms": round(total, 1), "count": count}
    return {
        "level": after.get("level"), "counters": counters,
        "spans": dict(sorted(spans.items(), key=lambda item: -item[1]["total_ms"])[:12]),
        "memory": after.get("memory", {}), "facts": after.get("facts", {}),
        "anomalies": sorted({anomaly.get("code", "?") for anomaly in after.get("anomalies", [])}),
    }


sys.path.insert(0, os.path.join(root, "scripts", "bench"))
import checks  # noqa: E402  (the answer checks, shared with scripts/cli-report.py)


def decode_rate(samples):
    """Chunks a second over a stretch of the timeline."""
    if len(samples) < 2 or samples[-1]["seconds"] <= samples[0]["seconds"]:
        return 0.0
    return (samples[-1]["chunks"] - samples[0]["chunks"]) / (samples[-1]["seconds"] - samples[0]["seconds"])


def layers(case):
    """Where a reply's time went and what each layer did (H3): which one to look at when it's slow."""
    lines = []
    events = {event["name"]: event["seconds"] for event in reversed(case["events"])}
    total = case["seconds"] or 0
    first_token = events.get("first token")
    first_text = events.get("first text on screen")
    if first_token is not None:
        parts = [f"before the first token {first_token:.1f} s"]
        if first_text is not None and first_text - first_token > 1:
            parts.append(f"reasoning {first_text - first_token:.1f} s")
        if first_text is not None:
            parts.append(f"answer {max(0, total - first_text):.1f} s")
        lines.append("- **Time:** " + ", ".join(parts))
    writing = [sample for sample in case["timeline"] if sample["chunks"] > 0]
    if len(writing) >= 9:
        third = len(writing) // 3
        thermal = sorted({sample["thermalState"] for sample in case["timeline"]})
        footprints = [sample["footprintGB"] for sample in case["timeline"]]
        lines.append(
            f"- **Engine over time:** {decode_rate(writing[:third]):.1f} chunks/s in the first third, "
            f"{decode_rate(writing[third:2 * third]):.1f} in the second, {decode_rate(writing[2 * third:]):.1f} in the last; "
            f"thermal state {' to '.join(str(state) for state in thermal)}; footprint {min(footprints):.2f} to {max(footprints):.2f} GB")
    work = case["work"]
    if work:
        described = []
        for kind in ("chat write", "markdown parse"):
            if kind in work:
                entry = work[kind]
                described.append(f"{int(entry['count'])} {kind}s, {entry['totalSeconds']:.2f} s in all, longest {entry['longestSeconds'] * 1000:.0f} ms")
        main = sum(entry["totalSeconds"] for entry in work.values())
        lines.append(f"- **Main thread:** {'; '.join(described)} ({100 * main / total if total else 0:.1f} % of the reply's time)")
    frames = case["frames"]
    if frames:
        lines.append(
            f"- **Frames:** {int(frames.get('hitches', 0))} late by 50 ms or more of {int(frames.get('frames', 0))}, "
            f"{frames.get('hitchSeconds', 0):.2f} s late in all, longest gap {frames.get('longestGapSeconds', 0) * 1000:.0f} ms")
    for step in case["after"]:
        output = " ".join(str(step.get("output", "")).split())[:80]
        lines.append(f"- **After the reply:** {step['name']} at +{step['secondsAfter']:.1f} s, took {step.get('helperSeconds', 0):.1f} s: {output}")
    return lines


cases, problems = [], []
for row in surface["rows"]:
    for turn in row.get("turns", []):
        name = row["id"] if turn["turn"] == 1 else f"{row['id']}/{turn['turn']}"
        case = {
            "id": name, "surface": turn, "think": row.get("think"), "search": row.get("search"),
            "device": {key: row.get(key) for key in ("thermalStateAtStart", "battery", "charging", "secondsCooling") if key in row},
            "attempts": row.get("attempts", 1), "firstAttempt": row.get("firstAttempt", ""),
        }
        cases.append(case)
        sent = when(turn["sentAt"]) if turn.get("sentAt") else None
        near = [t for t in traces if sent and abs((when(t["startedAt"]) - sent).total_seconds()) < 15]
        if not near:
            problems.append(f"{name}: no trace from the app")
            continue
        trace = min(near, key=lambda t: abs((when(t["startedAt"]) - sent).total_seconds()))
        reply = trace.get("text", "")
        fences = [line for line in reply.split("\n") if line.strip().startswith("```")]
        key = f"bench-{row['id']}-{turn['turn']}-screen.txt"
        screen = open(files[key]).read() if key in files else ""
        helpers = [event for event in trace.get("events", []) if event["name"] == "helper"]
        case.update({
            "replyID": trace.get("replyID"), "settings": trace.get("settings", {}),
            "ended": trace.get("ended"), "seconds": trace.get("seconds"), "stats": trace.get("stats", {}),
            "events": trace.get("events", []), "error": trace.get("error", ""), "notice": trace.get("notice", ""),
            "replyCharacters": len(reply), "reasoningCharacters": len(trace.get("thought", "")),
            "fencesClosed": len(fences) % 2 == 0, "sources": trace.get("sources", []),
            "citations": len(re.findall(r"\[\d+\]", reply)),
            "searchPlan": helpers[0].get("output", "") if helpers and row.get("search") else "",
            "engine": engine_summary(trace.get("engineTelemetry", {})),
            "timeline": trace.get("timeline", []), "work": trace.get("work", {}), "frames": trace.get("frames", {}),
            "after": trace.get("after", []),
            # The screen shows the reply: the end of what VoiceOver reads is the end of the trace's text.
            "screenAgrees": bool(screen) and spoken(screen)[-60:] == spoken(reply)[-60:],
        })
        # The app left the foreground while it replied: the reply isn't what a user would get.
        case["interrupted"] = any(event["name"] in ("scene background", "scene inactive") for event in trace.get("events", [])[1:])
        case["verdict"], case["failedChecks"] = checks.judge(row["id"], turn["turn"], reply)
        if case["interrupted"]:
            problems.append(f"{name}: interrupted (the app left the foreground); run it again with BENCH_RESUME=1")
        elif case["ended"] != "model":
            problems.append(f"{name}: ended by {case['ended']}")
        if not case["screenAgrees"]:
            problems.append(f"{name}: the screen and the trace disagree")
        open(os.path.join(bench, name.replace("/", "-") + ".md"), "w").write(
            f"# {name}\n\n**Prompt:**\n\n{trace.get('prompt', '')}\n\n**Sources:**\n\n" + "\n".join(f"- {source}" for source in case["sources"])
            + f"\n\n**Reasoning:**\n\n{trace.get('thought', '')}\n\n**Reply:**\n\n{reply}\n")

# A resumed run keeps the previous run's cases it didn't run again, in the bench's order.
if previous_report and os.path.exists(previous_report):
    rerun = {case["id"].split("/")[0] for case in cases}
    kept = [case for case in json.load(open(previous_report)).get("cases", []) if case["id"].split("/")[0] not in rerun]
    order = re.findall(r'BenchCase\(\s*id: "([^"]+)"', open(os.path.join(root, "AgelloUITests", "BenchCases.swift")).read())
    cases = sorted(kept + cases, key=lambda case: (order.index(case["id"].split("/")[0]) if case["id"].split("/")[0] in order else 99, case["id"]))

# What changed since the accepted baseline.
baseline_path = os.path.join(root, "scripts", "bench", "baseline.json")
summary = {
    case["id"]: {
        "ended": case.get("ended"), "outputTokens": case.get("stats", {}).get("outputTokens"),
        "tokPerSecond": round(case.get("stats", {}).get("decodeTokensPerSecond") or 0, 1),
        "failedChecks": case.get("failedChecks", []), "search": bool(case.get("search")),
    }
    for case in cases if "ended" in case
}
changes = []
baseline = json.load(open(baseline_path)) if os.path.exists(baseline_path) else None
if baseline:
    for name, now in summary.items():
        before = baseline["cases"].get(name)
        if before is None:
            changes.append(f"{name}: new case")
            continue
        if now["ended"] != before["ended"]:
            changes.append(f"{name}: ended by {now['ended']}, was {before['ended']}")
        fixed = [check for check in before["failedChecks"] if check not in now["failedChecks"]]
        broken = [check for check in now["failedChecks"] if check not in before["failedChecks"]]
        if broken:
            changes.append(f"{name}: now failing: {'; '.join(broken)}")
        if fixed:
            changes.append(f"{name}: no longer failing: {'; '.join(fixed)}")
        # Without Search a reply is the same every time: a different length is a different reply.
        if not now["search"] and now["outputTokens"] != before["outputTokens"]:
            changes.append(f"{name}: the reply changed ({before['outputTokens']} tokens, now {now['outputTokens']})")
        if before["tokPerSecond"] and abs(now["tokPerSecond"] - before["tokPerSecond"]) / before["tokPerSecond"] > 0.15:
            changes.append(f"{name}: {now['tokPerSecond']} tok/s, was {before['tokPerSecond']} (check the thermal state before reading this)")
    changes += [f"{name}: not in this run" for name in baseline["cases"] if name not in summary]

json.dump({"started": started, "cases": cases, "problems": problems, "sinceBaseline": changes}, open(os.path.join(bench, "report.json"), "w"), indent=1, sort_keys=True)
accepted = False
if os.environ.get("BENCH_ACCEPT") == "1":
    if problems:
        print("Not accepted as the baseline: the run has problems.")
    else:
        json.dump({"accepted": started, "cases": summary}, open(baseline_path, "w"), indent=1, sort_keys=True)
        print(f"Accepted as the baseline: {baseline_path}")
        accepted = True

lines = [f"# Bench run of {started}", "", "| Case | Ended | Tokens | tok/s | First token | On screen | Checks |", "| --- | --- | --- | --- | --- | --- | --- |"]
for case in cases:
    if "ended" not in case:
        lines.append(f"| {case['id']} | no trace | | | | | |")
        continue
    stats = case["stats"]
    lines.append(
        f"| {case['id']} | {case['ended']} | {stats.get('outputTokens', '?')} | {stats.get('decodeTokensPerSecond', 0):.1f} | "
        f"{stats.get('timeToFirstToken', 0):.1f} s | {'matches' if case['screenAgrees'] else 'DIFFERS'} | "
        f"{'; '.join(case['failedChecks']) or 'pass'} |")
lines.append("")
if baseline:
    lines += [f"## Since the baseline of {baseline['accepted']}", ""] + ([f"- {change}" for change in changes] or ["Nothing changed."]) + [""]
if accepted:
    lines += ["This run is the baseline from now on.", ""]
elif not baseline:
    lines += ["No baseline yet: run with BENCH_ACCEPT=1 to make a run the baseline.", ""]
for case in cases:
    surface_row = case["surface"]
    lines += [f"## {case['id']}", ""]
    if "ended" not in case:
        lines += ["No trace from the app.", ""]
        continue
    settings, stats = case["settings"], case["stats"]
    lines += [
        f"- **Ended:** {case['ended']} after {case['seconds']:.1f} s"
        + (f" (error: {case['error']})" if case["error"] else "") + (f" (notice: {case['notice']})" if case["notice"] else ""),
        f"- **Settings:** window {settings.get('window')}, Think {'on, ' + str(settings.get('thinkingBudget')) + ' tokens' if settings.get('think') else 'off'}, "
        f"Search {'on' if settings.get('search') else 'off'}, tools {'on' if settings.get('tools') else 'off'}, "
        f"{'optimized' if settings.get('optimized') else 'debug'} build, runtime {settings.get('runtimeBuild')}, "
        f"thermal state {settings.get('thermalState')} at the start",
        f"- **Reply:** {stats.get('outputTokens', '?')} tokens out, {stats.get('inputTokens', '?')} in, "
        f"{stats.get('decodeTokensPerSecond', 0):.1f} tok/s, first token {stats.get('timeToFirstToken', 0):.2f} s; "
        f"{case['replyCharacters']} characters, {case['reasoningCharacters']} of reasoning, code blocks {'closed' if case['fencesClosed'] else 'OPEN'}",
        f"- **On screen:** Stop shown after {surface_row.get('secondsToStop', 0):.1f} s, first text after {surface_row.get('secondsToFirstText', 0):.1f} s, "
        f"done after {surface_row.get('secondsToDone', 0):.1f} s; {surface_row.get('screenCharacters', 0)} characters read back, "
        f"{'matching' if case['screenAgrees'] else 'NOT matching'} the trace",
    ]
    device = case.get("device", {})
    if device:
        cooling = f", after {device['secondsCooling']:.0f} s of cooling" if device.get("secondsCooling") else ""
        lines.append(
            f"- **Phone:** thermal state {device.get('thermalStateAtStart')} at the start{cooling}, battery {100 * (device.get('battery') or 0):.0f} %"
            f"{', charging' if device.get('charging') else ''}"
            + (f"; second attempt ({case['firstAttempt']})" if case.get("attempts", 1) > 1 else ""))
    lines += layers(case)
    if case["search"]:
        lines.append(f"- **Search:** plan {' '.join(case['searchPlan'].split()) or 'none recorded'}; {len(case['sources'])} sources, {case['citations']} citations")
    lines += ["", "| Step | Seconds | Footprint | Available | Details |", "| --- | --- | --- | --- | --- |"]
    for event in case["events"]:
        details = ", ".join(f"{key} {' '.join(str(value).split())[:80]}" for key, value in event.items() if key not in ("name", "seconds", "footprintGB", "availableGB"))
        lines.append(f"| {event['name']} | {event['seconds']:.2f} | {event['footprintGB']:.2f} GB | {event['availableGB']:.2f} GB | {details} |")
    engine = case["engine"]
    if engine:
        spans = ", ".join(f"{name} {span['total_ms']:.0f} ms" for name, span in list(engine["spans"].items())[:5])
        lines += ["", f"- **Engine** (telemetry level {engine.get('level')}): {spans or 'no spans'}; anomalies: {', '.join(engine.get('anomalies', [])) or 'none'}; peak footprint {engine.get('memory', {}).get('peak_footprint_mb', 0) / 1000:.2f} GB"]
    verdict = case["verdict"]
    lines += ["", f"- **Checks:** {'; '.join(case['failedChecks']) or 'pass'}"]
    for key, label in (("part1AgainstSpec", "Part 1 against the spec"), ("part2AgainstSpec", "Part 2 against the spec"), ("part3OwnTests", "Part 3, its own tests")):
        if key in verdict:
            lines.append(f"- **{label}:** {verdict[key]['passed']} passed, {verdict[key]['failed']} failed" + "".join(f"\n  - {failure}" for failure in verdict[key]["failures"]))
    if "webApp" in verdict:
        lines.append(f"- **Web app:** {json.dumps(verdict['webApp'], sort_keys=True)[:300]}")
    if isinstance(verdict.get("swift"), dict) and verdict["swift"]["first"]:
        lines += [f"  - {error[:160]}" for error in verdict["swift"]["first"]]
    lines.append("")
if problems:
    lines += ["## Problems", ""] + [f"- {problem}" for problem in problems] + [""]
open(os.path.join(bench, "report.md"), "w").write("\n".join(lines))
print("\n".join(lines[: len(cases) + 7 + max(len(changes), 1)]))
if problems:
    print("Problems:\n" + "\n".join(f"- {problem}" for problem in problems))
print(f"Report: {os.path.join(bench, 'report.md')}")
sys.exit(1 if problems else 0)
