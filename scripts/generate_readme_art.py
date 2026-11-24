#!/usr/bin/env python3
"""Generate every Agello README graphic as deterministic, branded SVG.

Writes docs/readme/ (paired wide 880 px and narrow 400 px SVGs plus 40x40
highlight icons) from scripts/lib/readme_art.py. Python stdlib only; output is
byte-deterministic so `--check` fails closed if any committed SVG is stale.

Usage:
  python3 scripts/generate_readme_art.py            # rebuild docs/readme/
  python3 scripts/generate_readme_art.py --check    # verify committed SVGs match
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "docs" / "readme"

if str(ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts"))
from lib import readme_art as art  # noqa: E402

MEASURED = art.Measured(
    hardware="iPhone 17 Pro · Apple A19 Pro, 12 GB",
    os_version="iOS 27.2.1",
    runtime_tag="agello-one-20261124",
    runtime_build="8a7e34594612",
    prefill_peak_tok_s=1668,
    decode_low_tok_s=52,
    decode_high_tok_s=84,
    ane_pdf_seconds=0.86,
    chat_peak_gb="1.5–1.7 GB",
    full_64k_gb="3.2–3.5 GB",
    undisturbed_runs="23/24 undisturbed",
    decode_bars=(
        ("rewrite", "Rewrite", 84.3, "0.65 s TTFT · verify_8", "voice"),
        ("chat", "Chat", 57.8, "0.85 s TTFT · email", "chat"),
        ("file", "File Q&A", 56.9, "3.80 s TTFT · 1,668 prefill", "search"),
        ("think", "Think", 51.9, "0.97 s TTFT · reasoning", "think"),
    ),
    stock_32k_tok_s=27.0,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if committed README SVGs are stale")
    args = parser.parse_args()

    rendered = art.render(ROOT, MEASURED)
    on_disk = (
        {path.relative_to(OUTPUT_DIR).as_posix() for path in OUTPUT_DIR.rglob("*.svg")}
        if OUTPUT_DIR.exists()
        else set()
    )

    if args.check:
        stale = [
            name for name, content in rendered.items()
            if not (OUTPUT_DIR / name).is_file()
            or (OUTPUT_DIR / name).read_text(encoding="utf-8") != content
        ]
        stale += [f"{name} (extra file)" for name in sorted(on_disk - set(rendered))]
        if stale:
            print(f"error: README SVGs are stale: {', '.join(sorted(stale))}", file=sys.stderr)
            print("run: python3 scripts/generate_readme_art.py", file=sys.stderr)
            return 1
        print(f"README SVGs: fresh ({len(rendered)} files)")
        return 0

    for name in sorted(on_disk - set(rendered)):
        (OUTPUT_DIR / name).unlink()
    for name, content in rendered.items():
        target = OUTPUT_DIR / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    print(f"Rendered {len(rendered)} deterministic SVG files -> {OUTPUT_DIR.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
