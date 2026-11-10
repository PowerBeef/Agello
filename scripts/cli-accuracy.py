#!/usr/bin/env python3
"""Compare two backends' replies token by token (docs/CLI.md).

Usage: scripts/cli-accuracy.py REFERENCE.jsonl TEST.jsonl [--out REPORT.md]

Both files are `agello bench` records of the same cases with the shipping settings, under which
replies are decoded greedily on either backend (speculative decoding on): the reference from
the CPU backend (`agello bench --backend cpu`, about 10 tok/s on an M6), the test from the GPU
backend under study. Their replies
start alike and part ways at the first token where the two backends' arithmetic ranks two
candidates differently; from there the texts are different continuations, so what counts is
where that happens:

- the tokens both replies share from the start, and the share of the shorter reply that is;
- whether they part in the reasoning or in the answer;
- the text on each side of the split.

A split at a near tie is harmless and happens between any two float implementations; a split
early in every reply, or one that lands on a digit or a name, is the kind #3913 was. Sampled
replies (`~sampled`) and warm-ups are left out. Exits 0: this is a measurement, not a gate.
"""
import json, os, statistics, sys

arguments = sys.argv[1:]
out = None
if "--out" in arguments:
    index = arguments.index("--out")
    out = arguments[index + 1]
    del arguments[index:index + 2]
if len(arguments) != 2:
    sys.exit(__doc__)


def load(path):
    records = {}
    for line in open(path):
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get("warmup") or record["id"].endswith("~sampled") or "outputTokenIDs" not in record:
            continue
        records.setdefault(record["id"], record)  # the first repetition: greedy runs repeat
    return records


reference, test = load(arguments[0]), load(arguments[1])
shared = [name for name in reference if name in test]
if not shared:
    sys.exit("No case with token ids in both files (run both with a real model).")


def common_prefix(a, b):
    count = 0
    for x, y in zip(a, b):
        if x != y:
            break
        count += 1
    return count


def describe(record):
    machine = record.get("machine", {})
    build = (machine.get("runtimeBuild") or {}).get("build_id", "no build id")
    return f"{record['label']} ({record['backend']}, MTP {'on' if record.get('mtp') else 'off'}, build {build})"


first_ref, first_test = reference[shared[0]], test[shared[0]]
lines = [
    "# Token agreement", "",
    f"Reference: {describe(first_ref)}. Test: {describe(first_test)}.", "",
    "| Case | Reference tokens | Test tokens | Shared from the start | Share | They part in | Reference continues | Test continues |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
]
shares, identical = [], 0
for name in shared:
    a, b = reference[name], test[name]
    # Reasoning first, then the answer: the order the model wrote them in.
    ids_a = a.get("thoughtTokenIDs", []) + a["outputTokenIDs"]
    ids_b = b.get("thoughtTokenIDs", []) + b["outputTokenIDs"]
    prefix = common_prefix(ids_a, ids_b)
    shorter = min(len(ids_a), len(ids_b))
    share = prefix / shorter if shorter else 1.0
    shares.append(share)
    if ids_a == ids_b:
        identical += 1
        lines.append(f"| {name} | {len(ids_a)} | {len(ids_b)} | {prefix} | 100 % | identical | | |")
        continue
    where = "the reasoning" if prefix < min(len(a.get("thoughtTokenIDs", [])), len(b.get("thoughtTokenIDs", []))) else "the answer"
    text_a = (a.get("thought", "") + a["output"]) if where == "the reasoning" else a["output"]
    text_b = (b.get("thought", "") + b["output"]) if where == "the reasoning" else b["output"]
    characters = common_prefix(text_a, text_b)

    def continuation(text):
        return repr(text[max(0, characters - 20):characters] + "▸" + text[characters:characters + 40])[1:-1].replace("|", "\\|")

    lines.append(
        f"| {name} | {len(ids_a)} | {len(ids_b)} | {prefix} | {100 * share:.0f} % | {where} | "
        f"`{continuation(text_a)}` | `{continuation(text_b)}` |")
lines += [
    "",
    f"{identical} of {len(shared)} replies are identical token for token. The others share a median of "
    f"{100 * statistics.median(shares):.0f} % of the shorter reply before they part "
    f"(least {100 * min(shares):.0f} %). ▸ marks where the texts part.", "",
]
text = "\n".join(lines)
print(text)
if out:
    open(out, "w").write(text)
    print(f"Report: {out}")
