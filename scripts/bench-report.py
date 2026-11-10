#!/usr/bin/env python3
"""Join a bench run's three layers into one report (docs/HARNESS.md).

Usage: scripts/bench-report.py OUT STARTED
  OUT      the harness folder (build/device-harness): attachments/bench/ holds what the UI
           driver saw, bench/traces/ the app's traces pulled from the phone.
  STARTED  the run's start, ISO 8601 UTC: older traces belong to other runs.

Writes OUT/bench/report.json, report.md and each reply as Markdown. Exits 1 when a case has no
trace, didn't end by itself, or the screen and the trace disagree.
"""
import datetime, json, os, re, shutil, subprocess, sys, tempfile

out, started = sys.argv[1], sys.argv[2]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
    if "bench-surface.json" in files:
        surface = json.load(open(files["bench-surface.json"]))

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
    """Letters and digits only: the screen's text is the reply as VoiceOver reads it."""
    return re.sub(r"[^0-9a-z]", "", text.lower())


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


def pytest_python():
    """A Python with pytest: this one, or a small environment under build/ (scratch)."""
    probe = subprocess.run([sys.executable, "-c", "import pytest"], capture_output=True)
    if probe.returncode == 0:
        return sys.executable
    venv = os.path.join(root, "build", "bench-venv")
    python = os.path.join(venv, "bin", "python")
    if not os.path.exists(python):
        subprocess.run([sys.executable, "-m", "venv", venv], capture_output=True)
        subprocess.run([python, "-m", "pip", "install", "-q", "pytest"], capture_output=True)
    probe = subprocess.run([python, "-c", "import pytest"], capture_output=True)
    return python if probe.returncode == 0 else None


def run_pytest(python, work, target):
    result = subprocess.run(
        [python, "-I", "-m", "pytest", "-q", "--no-header", "-p", "no:cacheprovider", target],
        cwd=work, capture_output=True, text=True, timeout=180)
    lines = [line for line in result.stdout.strip().split("\n") if line.strip()]
    summary = lines[-1] if lines else result.stderr.strip()[-200:]
    passed = int((re.search(r"(\d+) passed", summary) or [0, 0])[1])
    failed = int((re.search(r"(\d+) failed", summary) or [0, 0])[1]) + int((re.search(r"(\d+) error", summary) or [0, 0])[1])
    return {
        "passed": passed, "failed": failed, "summary": summary,
        "failures": [line[:200] for line in lines if line.startswith(("FAILED", "ERROR"))],
    }


def check_ttl_cache(reply):
    """The three-part coding case: every part there, and the code run against the spec."""
    blocks = re.findall(r"```python\n(.*?)```", reply, re.S)
    verdict = {
        "partsNamed": [bool(re.search(rf"Part {n}", reply)) for n in (1, 2, 3)],
        "pythonBlocks": len(blocks),
    }
    cache = next((block for block in blocks if "class TTLCache" in block), None)
    merge = next((block for block in blocks if "def merge_intervals" in block), None)
    tests = next((block for block in blocks if "def test_" in block), None)
    verdict["found"] = {"TTLCache": bool(cache), "merge_intervals": bool(merge), "tests": bool(tests)}
    python = pytest_python()
    if python is None:
        verdict["code"] = "not run: no pytest on this Mac"
        return verdict
    specs = os.path.join(root, "scripts", "bench", "ttl-cache")
    # The reply's code is the model's: run in a throwaway folder, isolated from this environment.
    work = tempfile.mkdtemp(prefix="agello-bench-")
    try:
        if cache:
            open(os.path.join(work, "ttl_cache.py"), "w").write(cache)
            shutil.copy(os.path.join(specs, "spec_ttl_cache.py"), os.path.join(work, "test_spec.py"))
            verdict["part1AgainstSpec"] = run_pytest(python, work, "test_spec.py")
            if tests:
                open(os.path.join(work, "test_own.py"), "w").write(tests)
                verdict["part3OwnTests"] = run_pytest(python, work, "test_own.py")
        if merge:
            open(os.path.join(work, "merge.py"), "w").write("from typing import *\n" + merge)
            shutil.copy(os.path.join(specs, "spec_merge.py"), os.path.join(work, "test_merge.py"))
            verdict["part2AgainstSpec"] = run_pytest(python, work, "test_merge.py")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return verdict


CHECKERS = {"ttl-cache": check_ttl_cache}

cases, problems = [], []
for row in surface["rows"]:
    case = {"id": row["id"], "surface": row}
    sent = when(row["sentAt"]) if row.get("sentAt") else None
    near = [t for t in traces if sent and abs((when(t["startedAt"]) - sent).total_seconds()) < 15]
    if not near:
        problems.append(f"{row['id']}: no trace from the app")
        cases.append(case)
        continue
    trace = min(near, key=lambda t: abs((when(t["startedAt"]) - sent).total_seconds()))
    reply = trace.get("text", "")
    fences = [line for line in reply.split("\n") if line.strip().startswith("```")]
    screen = open(files[f"bench-{row['id']}-screen.txt"]).read() if f"bench-{row['id']}-screen.txt" in files else ""
    case.update({
        "replyID": trace.get("replyID"), "settings": trace.get("settings", {}),
        "ended": trace.get("ended"), "seconds": trace.get("seconds"), "stats": trace.get("stats", {}),
        "events": trace.get("events", []), "error": trace.get("error", ""), "notice": trace.get("notice", ""),
        "replyCharacters": len(reply), "reasoningCharacters": len(trace.get("thought", "")),
        "fencesClosed": len(fences) % 2 == 0,
        "engine": engine_summary(trace.get("engineTelemetry", {})),
        # The screen shows the reply: the end of what VoiceOver reads is the end of the trace's text.
        "screenAgrees": bool(screen) and spoken(screen)[-60:] == spoken(reply)[-60:],
    })
    if row["id"] in CHECKERS:
        case["verdict"] = CHECKERS[row["id"]](reply)
    if case["ended"] != "model":
        problems.append(f"{row['id']}: ended by {case['ended']}")
    if not case["screenAgrees"]:
        problems.append(f"{row['id']}: the screen and the trace disagree")
    open(os.path.join(bench, f"{row['id']}.md"), "w").write(
        f"# {row['id']}\n\n**Prompt:**\n\n{trace.get('prompt', '')}\n\n**Reasoning:**\n\n{trace.get('thought', '')}\n\n**Reply:**\n\n{reply}\n")
    cases.append(case)

json.dump({"started": started, "cases": cases, "problems": problems}, open(os.path.join(bench, "report.json"), "w"), indent=1, sort_keys=True)

lines = [f"# Bench run of {started}", ""]
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
        f"{'matching' if case['screenAgrees'] else 'NOT matching'} the trace; top of the chat {'reached' if surface_row.get('topReached') else 'not reached'}",
        "", "| Step | Seconds | Footprint | Available | Details |", "| --- | --- | --- | --- | --- |",
    ]
    for event in case["events"]:
        details = ", ".join(f"{key} {str(value)[:80]}" for key, value in event.items() if key not in ("name", "seconds", "footprintGB", "availableGB"))
        lines.append(f"| {event['name']} | {event['seconds']:.2f} | {event['footprintGB']:.2f} GB | {event['availableGB']:.2f} GB | {details} |")
    engine = case["engine"]
    if engine:
        spans = ", ".join(f"{name} {span['total_ms']:.0f} ms" for name, span in list(engine["spans"].items())[:5])
        lines += ["", f"- **Engine** (telemetry level {engine.get('level')}): {spans or 'no spans'}; anomalies: {', '.join(engine.get('anomalies', [])) or 'none'}; peak footprint {engine.get('memory', {}).get('peak_footprint_mb', 0) / 1000:.2f} GB"]
    verdict = case.get("verdict")
    if verdict:
        lines += ["", f"- **Parts named:** {verdict['partsNamed']}; Python blocks: {verdict['pythonBlocks']}"]
        for key, label in (("part1AgainstSpec", "Part 1 against the spec"), ("part2AgainstSpec", "Part 2 against the spec"), ("part3OwnTests", "Part 3, its own tests")):
            if key in verdict:
                lines.append(f"- **{label}:** {verdict[key]['passed']} passed, {verdict[key]['failed']} failed" + "".join(f"\n  - {failure}" for failure in verdict[key]["failures"]))
        if "code" in verdict:
            lines.append(f"- **Code:** {verdict['code']}")
    lines.append("")
if problems:
    lines += ["## Problems", ""] + [f"- {problem}" for problem in problems] + [""]
open(os.path.join(bench, "report.md"), "w").write("\n".join(lines))
print("\n".join(lines))
print(f"Report: {os.path.join(bench, 'report.md')}")
sys.exit(1 if problems else 0)
