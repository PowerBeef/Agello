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


def html_document(reply):
    """The first HTML document in a reply, fenced or not."""
    lower = reply.lower()
    start = min((i for i in (lower.find("<!doctype html"), lower.find("<html")) if i >= 0), default=-1)
    if start < 0:
        return None
    end = lower.find("</html>", start)
    return reply[start:end + 7] if end >= 0 else reply[start:].split("`")[0]


def check_webapp(kind):
    """The reply holds a web app: load it and try it (scripts/bench/webapp-check.swift)."""
    def check(reply):
        html = html_document(reply)
        if html is None:
            return {"webApp": {"found": False}}
        work = tempfile.mkdtemp(prefix="agello-bench-")
        try:
            page = os.path.join(work, "app.html")
            open(page, "w").write(html)
            result = subprocess.run(
                ["swift", os.path.join(root, "scripts", "bench", "webapp-check.swift"), page, kind],
                capture_output=True, text=True, timeout=180)
            line = (result.stdout.strip().split("\n") or [""])[-1]
            return {"webApp": json.loads(line) if line.startswith("{") else {"found": True, "error": result.stderr.strip()[-200:]}}
        except (subprocess.TimeoutExpired, ValueError) as error:
            return {"webApp": {"found": True, "error": str(error)[:200]}}
        finally:
            shutil.rmtree(work, ignore_errors=True)
    return check


def check_swift(reply):
    """Swift in the reply, type-checked against the iOS SDK."""
    blocks = re.findall(r"```swift\n(.*?)```", reply, re.S)
    if not blocks:
        return {"swift": "no Swift block"}
    work = tempfile.mkdtemp(prefix="agello-bench-")
    try:
        source = os.path.join(work, "reply.swift")
        open(source, "w").write("\n\n".join(blocks))
        result = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "swiftc", "-typecheck", "-target", "arm64-apple-ios27.0", "-swift-version", "5", source],
            capture_output=True, text=True, timeout=300)
        errors = sorted({line.split("error: ", 1)[1] for line in result.stderr.split("\n") if "error: " in line})
        return {"swift": {"errors": len(errors), "first": errors[:5]}}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def check_python(reply):
    """Python in the reply, byte-compiled (not run)."""
    blocks = re.findall(r"```python\n(.*?)```", reply, re.S)
    if not blocks:
        return {"python": "no Python block"}
    work = tempfile.mkdtemp(prefix="agello-bench-")
    try:
        source = os.path.join(work, "reply.py")
        open(source, "w").write("\n\n".join(blocks))
        result = subprocess.run([sys.executable, "-I", "-m", "py_compile", source], capture_output=True, text=True)
        return {"python": "compiles" if result.returncode == 0 else "fails: " + result.stderr.strip().split("\n")[-1][:160]}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def expect(*patterns):
    """The reply holds each pattern."""
    def check(reply):
        return {"expected": {pattern: bool(re.search(pattern, reply)) for pattern in patterns}}
    return check


# Each case's checks, one list per turn (cases are in AgelloUITests/BenchCases.swift).
CHECKS = {
    "calculator-search": [[check_webapp("calculator")]],
    "todo": [[check_webapp("todo")]],
    "swiftui-search": [[check_swift]],
    "python": [[check_python]],
    "facts-search": [[expect(r"\[\d+\]")]],
    "explain": [[expect(r"(?i)certificate|key")]],
    "email": [[expect(r"(?i)subject")]],
    "trip-search": [[expect(r"\|.*\|", r"(?i)montr[eé]al")]],
    "ttl-cache": [[check_ttl_cache]],
    "followup-search": [[expect(r"Poga[cč]ar", r"\[\d+\]")], [expect(r"\b6\s*(minutes?|min\b|:|′|')")]],
    "file-report": [[], [expect(r"(?i)water quality", r"(?i)district\s*4|\b4\b")]],
}


def failed_checks(verdict):
    """The names of a verdict's failed checks, for the summary."""
    failed = []
    for pattern, found in verdict.get("expected", {}).items():
        if not found:
            failed.append(f"missing /{pattern}/")
    app = verdict.get("webApp")
    if app is not None:
        if not app.get("found"):
            failed.append("no web app in the reply")
        if app.get("jsErrors"):
            failed.append(f"{len(app['jsErrors'])} JavaScript errors")
        if app.get("seven-times-eight", "shows 56") != "shows 56":
            failed.append(f"7 × 8: {app['seven-times-eight']}")
        if app.get("add-task", "task shows") != "task shows":
            failed.append(f"add a task: {app['add-task']}")
        if app.get("error"):
            failed.append(f"web check: {app['error']}")
    if isinstance(verdict.get("swift"), dict) and verdict["swift"]["errors"]:
        failed.append(f"{verdict['swift']['errors']} Swift errors")
    if isinstance(verdict.get("swift"), str) or (isinstance(verdict.get("python"), str) and verdict["python"] != "compiles"):
        failed.append(verdict.get("swift") if isinstance(verdict.get("swift"), str) else verdict["python"])
    for key, label in (("part1AgainstSpec", "Part 1"), ("part2AgainstSpec", "Part 2"), ("part3OwnTests", "its own tests")):
        if verdict.get(key, {}).get("failed"):
            failed.append(f"{label}: {verdict[key]['failed']} failed")
    return failed


cases, problems = [], []
for row in surface["rows"]:
    for turn in row.get("turns", []):
        name = row["id"] if turn["turn"] == 1 else f"{row['id']}/{turn['turn']}"
        case = {"id": name, "surface": turn, "think": row.get("think"), "search": row.get("search")}
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
            # The screen shows the reply: the end of what VoiceOver reads is the end of the trace's text.
            "screenAgrees": bool(screen) and spoken(screen)[-60:] == spoken(reply)[-60:],
        })
        verdict = {}
        checks = CHECKS.get(row["id"], [])
        for check in checks[turn["turn"] - 1] if turn["turn"] <= len(checks) else []:
            verdict.update(check(reply))
        case["verdict"] = verdict
        case["failedChecks"] = failed_checks(verdict) + ([] if case["fencesClosed"] else ["a code block isn't closed"])
        if case["ended"] != "model":
            problems.append(f"{name}: ended by {case['ended']}")
        if not case["screenAgrees"]:
            problems.append(f"{name}: the screen and the trace disagree")
        open(os.path.join(bench, name.replace("/", "-") + ".md"), "w").write(
            f"# {name}\n\n**Prompt:**\n\n{trace.get('prompt', '')}\n\n**Sources:**\n\n" + "\n".join(f"- {source}" for source in case["sources"])
            + f"\n\n**Reasoning:**\n\n{trace.get('thought', '')}\n\n**Reply:**\n\n{reply}\n")

json.dump({"started": started, "cases": cases, "problems": problems}, open(os.path.join(bench, "report.json"), "w"), indent=1, sort_keys=True)

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
print("\n".join(lines[: len(cases) + 5]))
if problems:
    print("Problems:\n" + "\n".join(f"- {problem}" for problem in problems))
print(f"Report: {os.path.join(bench, 'report.md')}")
sys.exit(1 if problems else 0)
