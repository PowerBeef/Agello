#!/usr/bin/env python3
"""Where a reply's time went, stretch by stretch (docs/CLI.md).

Usage: scripts/cli-timeline.py RUN.jsonl [--case ID] [--label NAME] [--rep N] [--parts N] [--rows]

Reads the engine timeline `agello bench` keeps in each record (the runtime's totals sampled once
a second while the reply is written) and cuts the decoding into N equal parts by tokens (default
3). For each part: decode speed, what a decode step produced (tokens per step, drafts kept by
MTP) and what it cost (the whole step, the GPU's verify and drafter runs, waiting on the GPU,
host copies), and memory. The last line says what moved between the first and the last part.

A reply slows down either because each step yields fewer tokens (fewer drafts accepted: the
text got harder to predict) or because each step costs more (attention over a longer context,
heat, another process on the GPU). The two columns tell which.

--rows prints every sampled second instead of parts.
"""
import json, sys

arguments = sys.argv[1:]


def option(name, default=None):
    if name in arguments:
        index = arguments.index(name)
        value = arguments[index + 1]
        del arguments[index:index + 2]
        return value
    return default


case, label, rep = option("--case"), option("--label"), option("--rep")
parts = int(option("--parts", "3"))
show_rows = "--rows" in arguments
if show_rows:
    arguments.remove("--rows")
if not arguments:
    sys.exit(__doc__)

records = [json.loads(line) for path in arguments for line in open(path) if line.strip()]
records = [
    r for r in records
    if not r.get("warmup") and r.get("engineTimeline")
    and (case is None or r["id"] == case) and (label is None or r["label"] == label)
    and (rep is None or str(r["rep"]) == rep)
]
if not records:
    sys.exit("No record with an engine timeline matches.")


def delta(a, b, key):
    return b.get(key, 0) - a.get(key, 0)


def live_tokens(row):
    """Tokens written so far. The runtime counts `tokens_decoded` when the turn ends; while it
    runs, each decode step has yielded one token plus the drafts MTP kept."""
    return row.get("decode.step.n", 0) + row.get("mtp_accepted", 0)


def stretch(a, b):
    """What happened between two rows of totals."""
    tokens = live_tokens(b) - live_tokens(a)
    steps = delta(a, b, "decode.step.n")
    seconds = delta(a, b, "decode.step.ms") / 1000
    drafted = delta(a, b, "mtp_drafted")

    def per_step(key):
        return delta(a, b, key) / steps if steps else 0

    return {
        "tokens": tokens, "steps": steps, "wall": b["seconds"] - a["seconds"],
        "tokPerSecond": tokens / seconds if seconds > 0 else 0,
        "tokensPerStep": tokens / steps if steps else 0,
        "accepted": delta(a, b, "mtp_accepted") / drafted if drafted else 0,
        "stepMs": per_step("decode.step.ms"),
        "verifyGpuMs": per_step("gpu.verify.ms"), "drafterGpuMs": per_step("gpu.drafter.ms"),
        "waitMs": per_step("gpu.wait.decode.ms"),
        "hostMs": per_step("host.lock_read.ms") + per_step("host.unlock_write.ms") + per_step("embedding_lookup.ms")
        + per_step("sample.ms") + per_step("detokenize.ms") + per_step("stream_callback.ms"),
        "queueDelayMs": delta(a, b, "gpu.queue_delay.ms") / delta(a, b, "command_buffers") if delta(a, b, "command_buffers") else 0,
        "footprintMB": b.get("footprintMB", 0), "thermal": int(b.get("thermal", 0)),
    }


def line(name, s):
    return (
        f"| {name} | {s['tokens']:.0f} | {s['tokPerSecond']:.1f} | {s['tokensPerStep']:.2f} | {100 * s['accepted']:.0f} % | "
        f"{s['stepMs']:.2f} | {s['verifyGpuMs']:.2f} | {s['drafterGpuMs']:.2f} | {s['waitMs']:.2f} | {s['hostMs']:.3f} | "
        f"{s['queueDelayMs']:.2f} | {s['footprintMB']:.0f} | {s['thermal']} |")


header = [
    "| Part | Tokens | tok/s | Tokens/step | Drafts kept | Step ms | GPU verify ms | GPU drafter ms | GPU wait ms | Host ms | Queue delay ms | Footprint MB | Thermal |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
]
for record in records:
    rows = record["engineTimeline"]
    for row in rows:
        row["tokens"] = live_tokens(row)
    decoding = [row for row in rows if row["tokens"] > 0]
    print(f"## {record['label']} / {record['id']} (rep {record['rep']}): {record['decode']} tokens at {record['decodeTPS']:.1f} tok/s"
          + (f"  [suspect: {'; '.join(record['suspect'])}]" if record.get("suspect") else ""))
    if len(decoding) < parts + 1:
        print(f"Too short to cut in {parts}: {len(decoding)} samples while decoding (use --timeline-interval with agello bench).\n")
        continue
    start = max((index for index, row in enumerate(rows) if row["tokens"] == 0), default=0)
    rows = rows[start:]
    print("\n".join(header))
    if show_rows:
        for a, b in zip(rows, rows[1:]):
            if b["tokens"] > a["tokens"]:
                print(line(f"{a['seconds']:.0f}–{b['seconds']:.0f} s", stretch(a, b)))
        print()
        continue
    total = rows[-1]["tokens"]
    cuts = [rows[0]]
    for part in range(1, parts):
        target = total * part / parts
        cuts.append(min(rows, key=lambda row: abs(row["tokens"] - target)))
    cuts.append(rows[-1])
    stretches = [stretch(a, b) for a, b in zip(cuts, cuts[1:])]
    for index, s in enumerate(stretches):
        print(line(f"{index + 1} of {parts}", s))
    print(line("whole", stretch(rows[0], rows[-1])))
    first, last = stretches[0], stretches[-1]
    if first["tokPerSecond"] and first["tokensPerStep"] and first["stepMs"]:
        speed = 100 * (last["tokPerSecond"] / first["tokPerSecond"] - 1)
        yield_change = 100 * (last["tokensPerStep"] / first["tokensPerStep"] - 1)
        cost = 100 * (last["stepMs"] / first["stepMs"] - 1)
        verify = 100 * (last["verifyGpuMs"] / first["verifyGpuMs"] - 1) if first["verifyGpuMs"] else 0
        print(
            f"\nFirst part to last: decode speed {speed:+.0f} %. Each step yields {yield_change:+.0f} % tokens "
            f"(drafts kept {100 * first['accepted']:.0f} % → {100 * last['accepted']:.0f} %) and costs {cost:+.0f} % "
            f"(GPU verify {verify:+.0f} %).\n")
