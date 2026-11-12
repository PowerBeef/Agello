#!/usr/bin/env python3
"""The Python side of scripts/phone-bench.sh (docs/HARNESS.md, "Runtime builds on the iPhone").

Usage:
  scripts/phone-bench.py case CASES_SWIFT ID [--cool on|off]
      How to launch one bench case with no driver: three lines, the launch environment (JSON),
      the app's arguments, and the most seconds to wait for its trace.
  scripts/phone-bench.py show TRACE
      One line on a reply's trace (speed, heat, build).
  scripts/phone-bench.py records OUT [--hardware NAME] [--labels a,b]
      The app's traces of a run (OUT/manifest.jsonl, OUT/traces/) as the records the Mac's tools
      read (OUT/<label>.jsonl, the format of `agello bench`: scripts/cli-load.py and the fork's
      compare.py read them unchanged), then whether the replies are identical (OUT/replies.txt).
  scripts/phone-bench.py --self-test

A trace holds the engine's telemetry totals before and after the reply; a record holds the
difference, the reply's own, as the Mac's records do.
"""
import datetime
import json
import os
import re
import sys
import tempfile
from collections import defaultdict

THERMAL = ["nominal", "fair", "serious", "critical"]
# The Mac command line's warm-up prompt: the first launch after an install loads the engine and
# writes its cache for that build, and isn't measured.
WARMUP = {"id": "warmup", "prompt": "Reply with one short sentence about the sea.", "think": False,
          "search": False, "followUps": False, "launchArguments": [], "timeout": 300}


def unescape(text):
    return re.sub(r'\\(["\\n])', lambda m: "\n" if m.group(1) == "n" else m.group(1), text)


def parse_case(source, case):
    """One BenchCase of AgelloUITests/BenchCases.swift: its prompt and how it's sent."""
    if case == "warmup":
        return dict(WARMUP)
    match = re.search(
        r'BenchCase\(\s*id: "' + re.escape(case) + r'",\s*prompt: (?:Prompts\.(\w+)|"((?:[^"\\]|\\.)*)")', source)
    if not match:
        raise SystemExit(f"No bench case {case} in BenchCases.swift")
    if match.group(1):
        literal = re.search(r'static let ' + match.group(1) + r' = #"""\n(.*?)\n\s*"""#', source, re.S).group(1)
        lines = literal.split("\n")
        indent = min(len(line) - len(line.lstrip()) for line in lines if line.strip())
        prompt = "\n".join(line[indent:] for line in lines)
    else:
        prompt = unescape(match.group(2))
    # The rest of this case's arguments: up to the next case, or the end of the list.
    rest = source[match.end():]
    end = re.search(r'BenchCase\(|\n\s*\]', rest)
    block = rest[:end.start()] if end else rest
    think = re.search(r'\bthink: (true|false)', block)
    arguments = re.search(r'launchArguments: \[([^\]]*)\]', block)
    timeout = re.search(r'timeout: (\d+)', block)
    return {
        "id": case, "prompt": prompt,
        "think": think.group(1) == "true" if think else True,
        "search": bool(re.search(r'\bsearch: true', block)),
        "followUps": bool(re.search(r'followUps:', block)),
        "launchArguments": re.findall(r'"([^"]+)"', arguments.group(1)) if arguments else [],
        "timeout": int(timeout.group(1)) if timeout else 300,
    }


def launch_spec(case, cool):
    """The environment, arguments and wait for one driverless launch of a case."""
    if case["search"]:
        raise SystemExit(f"{case['id']} uses Search: the live web answers differently each time, so the "
                         "phone comparison runs cases without it.")
    env = {"AGELLO_BENCH_DRAFT": case["prompt"], "AGELLO_BENCH_AUTOSEND": "1",
           "AGELLO_BENCH_THINK": "1" if case["think"] else "0"}
    if cool:
        env["AGELLO_BENCH_COOL"] = "1"
    # Memories would change the system prompt from one case to the next: off for these launches
    # only (the argument domain; the saved setting stays the user's).
    arguments = ["--trace", "-memoryEnabled", "NO"] + case["launchArguments"]
    # Loading (up to 300 s), cooling (up to 600 s), then the reply.
    wait = 300 + (600 if cool else 0) + case["timeout"] + 60
    return env, arguments, wait


def thermal_name(value):
    return THERMAL[value] if isinstance(value, int) and 0 <= value < len(THERMAL) else str(value)


def stamp_of(name):
    """2026-11-12T15-04-05Z-<id>.json → its time (the reply's send)."""
    match = re.match(r'(\d{4}-\d\d-\d\dT\d\d)-(\d\d)-(\d\dZ)', os.path.basename(name))
    if not match:
        return None
    return datetime.datetime.fromisoformat(f"{match.group(1)}:{match.group(2)}:{match.group(3)}".replace("Z", "+00:00"))


def parse_time(text):
    text = text.replace("Z", "+00:00")
    # A stamp from a file name (hyphens in the time).
    if re.match(r'\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d', text):
        text = text[:13] + ":" + text[14:16] + ":" + text[17:]
    return datetime.datetime.fromisoformat(text)


def delta(before, after, key):
    """The reply's own part of the totals: spans (total_ms, count) or counters."""
    old = (before or {}).get(key) or {}
    new = (after or {}).get(key) or {}
    out = {}
    for name, value in new.items():
        if key == "spans":
            previous = old.get(name) or {}
            total = (value.get("total_ms") or 0) - (previous.get("total_ms") or 0)
            count = (value.get("count") or 0) - (previous.get("count") or 0)
            if count > 0 or total > 0:
                out[name] = {"total_ms": round(total, 3), "count": count}
        elif isinstance(value, (int, float)):
            difference = value - (old.get(name) or 0)
            if difference:
                out[name] = difference
    return out


def record_of(trace, entry, hardware, trace_name):
    """A trace and its launch as the record `agello bench` writes on the Mac."""
    settings = trace.get("settings") or {}
    stats = trace.get("stats") or {}
    engine = trace.get("engineTelemetry") or {}
    before, after = engine.get("before") or {}, engine.get("after") or {}
    spans = delta(before, after, "spans")
    counters = delta(before, after, "counters")
    prefill = counters.get("tokens_prefilled") or stats.get("inputTokens") or 0
    decoded = counters.get("tokens_decoded") or stats.get("outputTokens") or 0
    prefill_ms = (spans.get("turn.prefill") or {}).get("total_ms") or 0
    facts = after.get("facts") or {}
    family = re.search(r'Apple(\d+)', facts.get("gpu", ""))
    at_send = settings.get("thermalState", 0)
    during = [sample.get("thermalState", 0) for sample in trace.get("timeline") or []]
    hottest = max([at_send] + during)
    suspect = []
    if at_send:
        suspect.append(f"sent warm ({thermal_name(at_send)})")
    if hottest > at_send:
        suspect.append(f"warmed to {thermal_name(hottest)} during the reply")
    ended = trace.get("ended")
    error = trace.get("error") or None
    if not error and ended not in ("model", "outputCap"):
        error = f"ended: {ended}"
    launched = parse_time(entry["launched"])
    started = parse_time(trace["startedAt"])
    build = settings.get("runtimeBuild", "?")
    return {
        "schema": 1, "kind": "app-reply", "label": entry["label"], "id": entry["case"],
        "rep": entry["round"], "run": f"{entry['label']}.{entry['round']}", "warmup": bool(entry.get("warmup")),
        "prompt": trace.get("prompt", ""), "output": trace.get("text", ""), "thought": trace.get("thought", ""),
        "prefill": prefill, "decode": decoded,
        "prefillTPS": prefill / prefill_ms * 1000 if prefill and prefill_ms else None,
        "decodeTPS": stats.get("decodeTokensPerSecond"), "ttft": stats.get("timeToFirstToken"),
        "seconds": trace.get("seconds"), "secondsBeforeSend": (started - launched).total_seconds(),
        "ended": ended, "error": error, "accepted": ended == "model", "reachedLimit": ended == "outputCap",
        "thermal": thermal_name(hottest), "thermalAtSend": thermal_name(at_send),
        "backend": "gpu", "activation": "default", "kv": settings.get("window"),
        "mtp": settings.get("speculativeDecoding"), "model": stats.get("modelID", "?"),
        "machine": {"hardware": hardware, "gpu": facts.get("gpu", "?"),
                    "gpuAppleFamily": int(family.group(1)) if family else 0,
                    "runtime": build, "runtimeSHA256": build, "isiOSAppOnMac": False},
        "settings": settings,
        "telemetry": {"spans": spans, "counters": counters, "facts": facts, "level": after.get("level")},
        "suspect": suspect, "trace": trace_name,
    }


def show(path):
    trace = json.load(open(path))
    settings, stats = trace.get("settings") or {}, trace.get("stats") or {}
    engine = trace.get("engineTelemetry") or {}
    spans = delta(engine.get("before"), engine.get("after"), "spans")
    counters = delta(engine.get("before"), engine.get("after"), "counters")
    prefill = counters.get("tokens_prefilled") or 0
    prefill_ms = (spans.get("turn.prefill") or {}).get("total_ms") or 0
    hottest = max([settings.get("thermalState", 0)] + [s.get("thermalState", 0) for s in trace.get("timeline") or []])
    parts = [f"{stats.get('outputTokens', '?')} tokens at {stats.get('decodeTokensPerSecond') or 0:.1f} tok/s"]
    if prefill and prefill_ms:
        parts.append(f"prefill {prefill} at {prefill / prefill_ms * 1000:.0f} tok/s")
    if stats.get("timeToFirstToken") is not None:
        parts.append(f"first token {stats['timeToFirstToken']:.2f} s")
    parts.append(f"{thermal_name(settings.get('thermalState', 0))} at send, {thermal_name(hottest)} at most")
    parts.append(f"build {settings.get('runtimeBuild', '?')}")
    ended = trace.get("ended")
    if ended != "model":
        parts.append(f"ENDED {ended}{': ' + trace['error'] if trace.get('error') else ''}")
    print("; ".join(parts))


def first_difference(a, b):
    for index, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return index
    return min(len(a), len(b))


def records(out, hardware, labels):
    manifest = [json.loads(line) for line in open(os.path.join(out, "manifest.jsonl")) if line.strip()]
    folder = os.path.join(out, "traces")
    problems = []
    by_label = defaultdict(list)
    for entry in manifest:
        name = entry.get("trace")
        if not name or not os.path.exists(os.path.join(folder, name)):
            problems.append(f"{entry['label']} round {entry['round']} {entry['case']}: no trace ({entry.get('status', 'missing')})")
            continue
        trace = json.load(open(os.path.join(folder, name)))
        record = record_of(trace, entry, hardware, name)
        if record["prompt"] != entry.get("prompt", record["prompt"]):
            problems.append(f"{entry['label']} round {entry['round']} {entry['case']}: the trace's message isn't the case's")
        by_label[entry["label"]].append(record)
    order = labels or list(by_label)
    for label in order:
        with open(os.path.join(out, f"{label}.jsonl"), "w") as f:
            for record in by_label.get(label, []):
                f.write(json.dumps(record, ensure_ascii=False) + "\n")

    lines = ["== Records"]
    lines.append(f"  {'build':<10} {'round':>5} {'case':<14} {'runtime':<13} {'decode':>8} {'prefill':>8} {'1st tok':>7}  heat")
    for label in order:
        for r in by_label.get(label, []):
            decode = f"{r['decodeTPS']:.1f}" if r.get("decodeTPS") else "-"
            prefill = f"{r['prefillTPS']:.0f}" if r.get("prefillTPS") else "-"
            ttft = f"{r['ttft']:.2f}" if r.get("ttft") is not None else "-"
            note = r["error"] or ""
            heat = r["thermalAtSend"] + ("" if r["thermal"] == r["thermalAtSend"] else f" to {r['thermal']}")
            case = r["id"] + (" (warm-up)" if r["warmup"] else "")
            lines.append(f"  {label:<10} {r['rep']:>5} {case:<14} {r['machine']['runtime']:<13} {decode:>8} {prefill:>8} {ttft:>7}  {heat} {note}".rstrip())

    # Each build ran one runtime; the trace says which.
    builds = {label: sorted({r["machine"]["runtime"] for r in by_label.get(label, [])}) for label in order}
    lines.append("")
    lines.append("  Runtimes: " + "; ".join(f"{label} {', '.join(ids) or '-'}" for label, ids in builds.items()))
    for label, ids in builds.items():
        if len(ids) > 1:
            problems.append(f"{label} ran more than one runtime ({', '.join(ids)}): an install went wrong; its records don't count")
    windows = sorted({r["kv"] for rs in by_label.values() for r in rs if not r["warmup"]})
    if len(windows) > 1:
        problems.append(f"the window changed between launches ({', '.join(map(str, windows))}): memory at load differed")

    # Greedy decoding: the same runtime gives the same reply every time, and the comparison asks
    # whether another runtime does too.
    replies = ["== Replies (greedy decoding: every run of a case should match the base build's first)"]
    base = order[0] if order else None
    os.makedirs(os.path.join(out, "replies"), exist_ok=True)
    cases = list(dict.fromkeys(r["id"] for rs in by_label.values() for r in rs if not r["warmup"]))
    for case in cases:
        runs = [r for label in order for r in by_label.get(label, []) if r["id"] == case and not r["error"]]
        if not runs:
            continue
        reference = next((r for r in runs if r["label"] == base), runs[0])
        with open(os.path.join(out, "replies", f"{case}.md"), "w") as f:
            f.write(f"# {case} ({reference['label']}, round {reference['rep']})\n\n")
            if reference["thought"]:
                f.write("## Reasoning\n\n" + reference["thought"] + "\n\n## Answer\n\n")
            f.write(reference["output"] + "\n")
        different = []
        for r in runs:
            if (r["output"], r["thought"]) != (reference["output"], reference["thought"]):
                where = "reasoning" if r["thought"] != reference["thought"] else "answer"
                a = r["thought"] if where == "reasoning" else r["output"]
                b = reference["thought"] if where == "reasoning" else reference["output"]
                position = first_difference(a, b)
                different.append(f"{r['label']} round {r['rep']} ({where} from character {position}; prompt {r['prefill']} tokens against {reference['prefill']})")
                name = f"{case}-{r['label']}-{r['rep']}.md"
                with open(os.path.join(out, "replies", name), "w") as f:
                    f.write(f"# {case} ({r['label']}, round {r['rep']})\n\n")
                    if r["thought"]:
                        f.write("## Reasoning\n\n" + r["thought"] + "\n\n## Answer\n\n")
                    f.write(r["output"] + "\n")
        if different:
            replies.append(f"  {case}: {len(runs) - len(different)} of {len(runs)} identical; differ: " + "; ".join(different))
        else:
            replies.append(f"  {case}: all {len(runs)} identical")
    text = "\n".join(lines + [""] + replies + ([""] + ["! " + p for p in problems] if problems else []))
    with open(os.path.join(out, "replies.txt"), "w") as f:
        f.write("\n".join(replies) + "\n")
    print(text)
    return 1 if any("more than one runtime" in p for p in problems) else 0


def self_test():
    """A made-up run: two builds, one case each, the second warmed during its reply."""
    with tempfile.TemporaryDirectory() as out:
        os.makedirs(os.path.join(out, "traces"))
        source = '''
  static let all: [BenchCase] = [
    BenchCase(id: "plain", prompt: "Say \\"hi\\"", think: false),
    BenchCase(id: "file", prompt: Prompts.long, think: false, followUps: ["More?"],
      launchArguments: ["--uitest-sample-report"]),
    BenchCase(id: "web", prompt: "News?", search: true),
  ]
  enum Prompts {
    static let long = #"""
      Line one.
        Line two.
      """#
  }
'''
        plain, long, web = parse_case(source, "plain"), parse_case(source, "file"), parse_case(source, "web")
        problems = []
        if plain["prompt"] != 'Say "hi"' or plain["think"] or plain["launchArguments"]:
            problems.append(f"plain case parsed as {plain}")
        if long["prompt"] != "Line one.\n  Line two." or long["launchArguments"] != ["--uitest-sample-report"] or not long["followUps"]:
            problems.append(f"file case parsed as {long}")
        if not web["search"]:
            problems.append("web case's Search missed")
        env, arguments, wait = launch_spec(plain, cool=True)
        if env["AGELLO_BENCH_THINK"] != "0" or env.get("AGELLO_BENCH_COOL") != "1" or "--trace" not in arguments or wait < 900:
            problems.append(f"launch spec {env} {arguments} {wait}")

        def telemetry(prefilled, decoded, prefill_ms, decode_ms, steps, gpu_ms):
            return {"level": 2, "facts": {"gpu": "Apple A19 Pro GPU, ML Drift family Apple10"},
                    "counters": {"tokens_prefilled": prefilled, "tokens_decoded": decoded},
                    "spans": {"turn.prefill": {"total_ms": prefill_ms, "count": 1},
                              "turn.decode": {"total_ms": decode_ms, "count": 1},
                              "decode.step": {"total_ms": decode_ms, "count": steps},
                              "gpu.wait.decode": {"total_ms": gpu_ms, "count": steps}}}
        manifest = []
        for index, (label, build, timeline) in enumerate([("a", "aaa111", [0, 0]), ("b", "bbb222", [0, 1])]):
            launched = f"2026-11-12T10-0{index}-00Z"
            name = f"2026-11-12T10-0{index}-20Z-{label.upper()}.json"
            trace = {
                "startedAt": f"2026-11-12T10:0{index}:20Z", "prompt": 'Say "hi"', "text": "Hi!", "thought": "",
                "ended": "model", "error": "", "seconds": 3.0,
                "settings": {"runtimeBuild": build, "thermalState": 0, "window": 32000, "speculativeDecoding": True},
                "stats": {"decodeTokensPerSecond": 40.0, "timeToFirstToken": 0.5, "modelID": "e4b"},
                "timeline": [{"thermalState": t} for t in timeline],
                "engineTelemetry": {"before": telemetry(1000, 500, 1000.0, 10000.0, 200, 8000.0),
                                    "after": telemetry(1300, 600, 1250.0, 12500.0, 240, 9600.0)},
            }
            json.dump(trace, open(os.path.join(out, "traces", name), "w"))
            manifest.append({"label": label, "round": 1, "case": "plain", "warmup": False,
                             "launched": launched, "trace": name, "prompt": 'Say "hi"', "status": "traced"})
        with open(os.path.join(out, "manifest.jsonl"), "w") as f:
            f.write("\n".join(json.dumps(m) for m in manifest) + "\n")
        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            code = records(out, "iPhone 17 Pro", ["a", "b"])
        a = [json.loads(line) for line in open(os.path.join(out, "a.jsonl"))]
        b = [json.loads(line) for line in open(os.path.join(out, "b.jsonl"))]
        if code != 0 or len(a) != 1 or len(b) != 1:
            problems.append(f"records: exit {code}, {len(a)} and {len(b)} records")
        else:
            r = a[0]
            if r["prefill"] != 300 or r["decode"] != 100 or abs(r["prefillTPS"] - 1200) > 0.01:
                problems.append(f"prefill and decode deltas: {r['prefill']} {r['decode']} {r['prefillTPS']}")
            if r["telemetry"]["spans"]["decode.step"] != {"total_ms": 2500.0, "count": 40}:
                problems.append(f"span delta {r['telemetry']['spans']['decode.step']}")
            if r["machine"]["gpuAppleFamily"] != 10 or r["secondsBeforeSend"] != 20 or r["suspect"]:
                problems.append(f"machine, wait or flags: {r['machine']} {r['secondsBeforeSend']} {r['suspect']}")
            if b[0]["suspect"] != ["warmed to fair during the reply"]:
                problems.append(f"heat flag: {b[0]['suspect']}")
        if "all 2 identical" not in open(os.path.join(out, "replies.txt")).read():
            problems.append("replies: " + open(os.path.join(out, "replies.txt")).read())
    if problems:
        print("phone-bench.py self-test FAILED: " + "; ".join(problems))
        sys.exit(1)
    print("phone-bench.py self-test passed.")
    sys.exit(0)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    command = sys.argv[1]
    if command == "--self-test":
        self_test()
    if command == "case":
        if len(sys.argv) < 4:
            raise SystemExit(__doc__)
        cool = not (len(sys.argv) > 5 and sys.argv[4] == "--cool" and sys.argv[5] == "off")
        case = parse_case(open(sys.argv[2]).read(), sys.argv[3])
        env, arguments, wait = launch_spec(case, cool)
        if case["followUps"]:
            print(f"Note: {case['id']} has follow-ups; only its first message is sent.", file=sys.stderr)
        print(json.dumps(env, ensure_ascii=False))
        print(" ".join(arguments))
        print(wait)
        print(json.dumps(case["prompt"], ensure_ascii=False))
        return 0
    if command == "show":
        show(sys.argv[2])
        return 0
    if command == "records":
        out = sys.argv[2]
        hardware, labels = "iPhone", []
        rest = sys.argv[3:]
        while rest:
            flag = rest.pop(0)
            if flag == "--hardware":
                hardware = rest.pop(0)
            elif flag == "--labels":
                labels = [label for label in rest.pop(0).split(",") if label]
            else:
                raise SystemExit(f"Unknown option {flag}")
        return records(out, hardware, labels)
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
