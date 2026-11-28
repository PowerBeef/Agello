#!/usr/bin/env python3
"""Automated Knowledge-Base & Doc-Parity Validator for Agello (iRT).

Validates structural, numerical, cross-reference, provenance, and hygiene
invariants across docs/BACKEND_KNOWLEDGE_BASE.md and peer repository docs in
under 1 second using only the Python 3 standard library:

  1. ID Uniqueness & Contiguous Numbering (MS/GPU/RT/APP/INF-01..max, no gaps)
  2. 1-to-1 Scorecard == Master Attempt Ledger == Parts 2-6 #### `<ID>` Parity
  3. Part 6 ("Do Not Repeat" Graveyard) §6.1-§6.7 Summary Table == Cat E Parity
  4. Internal (#anchor) & Cross-Doc Link Validity (AGENTS, README, docs, skills)
  5. Markdown Tables, Mermaid HTML-Free Labels & Zero Attribution Hygiene
  6. Git Commit SHA Provenance via `git cat-file --batch-check` (--skip-git opt)
  7. Repo Doc Parity (ROADMAP Current status <= 3,000 B & Package.swift tag sync)

Exit codes:
  0  All checks passed
  1  One or more checks failed (exact file:line diagnostics printed to stderr)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

DOMAINS: tuple[str, ...] = ("MS", "GPU", "RT", "APP", "INF")
CATEGORIES: tuple[str, ...] = ("Cat A", "Cat B", "Cat C", "Cat D", "Cat E")
PART_TO_CATEGORY: dict[int, str] = {
    2: "Cat A",
    3: "Cat B",
    4: "Cat C",
    5: "Cat D",
    6: "Cat E",
}
CATEGORY_TO_PART: dict[str, int] = {v: k for k, v in PART_TO_CATEGORY.items()}
ROADMAP_STATUS_MAX_BYTES = 3000

ID_TOKEN_RE = re.compile(r"^(MS|GPU|RT|APP|INF)-(\d+)$")
ANY_KB_ID_RE = re.compile(r"`((?:MS|GPU|RT|APP|INF)-\d+)`")
CAT_BADGE_RE = re.compile(r"`(Cat [A-E])\b")
H4_ID_HEADING_RE = re.compile(r"^####\s+`([A-Z]+-\d+)`")
FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
INLINE_CODE_RE = re.compile(r"(`+)([^`]*?)\1")
MD_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
DELIM_CELL_RE = re.compile(r"^:?-+:?$")

# HTML tags forbidden inside ```mermaid blocks (word-bounded so model tokens
# like <bos>, <pad>, <thought>, or <|turn> are never misclassified as HTML).
MERMAID_HTML_TAG_RE = re.compile(
    r"</?(?:"
    r"br|hr|wbr|b|strong|i|em|u|s|strike|del|ins|mark|sub|sup|small|big|"
    r"code|pre|tt|kbd|samp|var|span|div|p|a|img|font|center|"
    r"ul|ol|li|dl|dt|dd|table|thead|tbody|tr|td|th|blockquote|h[1-6]"
    r")\b[^>]*>",
    re.IGNORECASE,
)

# AI / agent / swarm attribution markers forbidden across all repository docs
# (carefully scoped so "Core AI", "Google AI Edge", "Apple Intelligence", UI
# "cursor" terms, and AGENTS.md workflow instructions never false-positive).
COMMON_ATTRIBUTION_RE = re.compile(
    r"(?:"
    r"Co-Authored-By:\s*.*(?:Claude|Anthropic|OpenAI|ChatGPT|Codex|Gemini|Copilot|Cursor|Windsurf|Antigravity|AI\b|Agent\b|Bot\b)"
    r"|Signed-off-by:\s*.*(?:Claude|Anthropic|OpenAI|ChatGPT|Codex|Gemini|Copilot|Cursor|Windsurf|Antigravity)"
    r"|Claude-Session"
    r"|Claude\s+Code"
    r"|Generated\s+(?:with|by)\s+\[?(?:Claude|Anthropic|ChatGPT|OpenAI|Codex|Gemini|Copilot|Cursor|Windsurf|Antigravity)"
    r"|\U0001f916\s*Generated"
    r"|\bAntigravity\s+swarm\b"
    r"|\bswarm\s+(?:worker|coordinator|board|agent)\b"
    r"|\bwf-[a-z0-9-]+\b"
    r")",
    re.IGNORECASE,
)

# Additional agent/product names forbidden in KB, README, Vendor/README, NOTICE.
KB_STRICT_ATTRIBUTION_RE = re.compile(
    r"(?:"
    r"\b(?:Claude|Anthropic|ChatGPT|Copilot|Windsurf|Antigravity)\b"
    r"|\bCursor\s+(?:AI|IDE|Agent)\b"
    r")",
    re.IGNORECASE,
)

# Explicit repo-prefixed commit SHAs (plus optional .. / -> / → range RHS).
EXPLICIT_COMMIT_RE = re.compile(
    r"\b(iRT|LRT|LiteRT-LM)@([0-9a-fA-F]{6,40})"
    r"(?:(?:\.\.|→|\s*->\s*|\s*→\s*)([0-9a-fA-F]{6,40}))?\b"
)


@dataclass
class CheckResult:
    name: str
    summary: str = ""
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    def fail(self, relpath: str, line: int, message: str) -> None:
        self.errors.append(f"{relpath}:{line}: {message}")


@dataclass
class LedgerEntry:
    id_str: str
    domain: str
    number: int
    category: str
    line: int


@dataclass
class ParsedKB:
    relpath: str
    text: str
    lines: list[str]
    ledger: dict[str, LedgerEntry] = field(default_factory=dict)
    ledger_heading_line: int = 0
    ledger_heading_claimed_total: int | None = None
    scorecard_line: int = 0
    scorecard_domains: dict[str, tuple[int, str, list[int]]] = field(default_factory=dict)
    scorecard_total: tuple[int, int | None, list[int]] | None = None
    part_headings: dict[str, tuple[int, int, str | None]] = field(default_factory=dict)
    stray_id_headings: list[tuple[int, str]] = field(default_factory=list)
    duplicate_part_headings: list[tuple[int, int, str]] = field(default_factory=list)
    part6_subsections_seen: set[str] = field(default_factory=set)
    part6_table_ids: dict[str, list[int]] = field(default_factory=dict)
    slugs: dict[str, int] = field(default_factory=dict)


def split_pipe_row(line: str) -> list[str] | None:
    """Split a Markdown pipe-table row on unescaped `|` delimiters."""
    s = line.strip()
    if s.startswith(">"):
        s = re.sub(r"^(?:>\s*)+", "", s).strip()
    if not (s.startswith("|") and s.endswith("|")) or len(s) < 2:
        return None
    parts = re.split(r"(?<!\\)\|", s)
    if len(parts) < 3:
        return None
    return [cell.strip() for cell in parts[1:-1]]


def is_delimiter_row(cells: list[str]) -> bool:
    return bool(cells) and all(DELIM_CELL_RE.match(c) for c in cells)


def strip_inline_code(line: str) -> str:
    return INLINE_CODE_RE.sub("", line)


def github_slug(heading_line: str) -> str:
    """Compute GitHub's anchor slug for an ATX Markdown heading."""
    text = re.sub(r"^#{1,6}\s+", "", heading_line).strip()
    text = re.sub(r"\s+#+\s*$", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = text.replace("&amp;", "&")
    text = text.replace("`", "").replace("*", "").replace("~", "")
    text = text.lower()
    out: list[str] = []
    for ch in text:
        if ch in (" ", "-"):
            out.append("-")
        elif ch == "_":
            out.append("_")
        elif unicodedata.category(ch).startswith(("L", "N")):
            out.append(ch)
    return "".join(out)


def parse_kb(kb_path: Path, relpath: str, structural_errors: list[tuple[int, str]]) -> ParsedKB:
    text = kb_path.read_text(encoding="utf-8")
    lines = text.splitlines()
    kb = ParsedKB(relpath=relpath, text=text, lines=lines)

    in_fence = False
    fence_marker = ""
    section_h2 = ""
    section_h2_part: int | None = None
    section_h3 = ""
    part6_in_id_table = False

    for line_no, raw in enumerate(lines, 1):
        m_fence = FENCE_RE.match(raw)
        if m_fence:
            ticks = m_fence.group(1)
            if not in_fence:
                in_fence = True
                fence_marker = ticks[0] * len(ticks)
                part6_in_id_table = False
                continue
            if ticks[0] == fence_marker[0] and len(ticks) >= len(fence_marker):
                in_fence = False
                fence_marker = ""
                continue
        if in_fence:
            continue

        # Record GitHub heading slugs for every ATX heading.
        if re.match(r"^#{1,6}\s+", raw):
            base = github_slug(raw)
            if base in kb.slugs:
                suffix = 1
                while f"{base}-{suffix}" in kb.slugs:
                    suffix += 1
                kb.slugs[f"{base}-{suffix}"] = line_no
            else:
                kb.slugs[base] = line_no

        if raw.startswith("## "):
            section_h2 = raw
            m_part = re.match(r"^##\s+Part\s+(\d+)\b", raw)
            section_h2_part = int(m_part.group(1)) if m_part else None
            section_h3 = ""
            part6_in_id_table = False
        elif raw.startswith("### "):
            section_h3 = raw
            part6_in_id_table = False
            if section_h3.startswith("### Aggregate Scorecard"):
                kb.scorecard_line = line_no
            elif section_h3.startswith("### Master Attempt Ledger"):
                kb.ledger_heading_line = line_no
                m_cnt = re.search(r"\((\d+)\s+Unique Tracked Attempts\)", section_h3)
                if m_cnt:
                    kb.ledger_heading_claimed_total = int(m_cnt.group(1))
            elif section_h2_part == 6:
                m_sub = re.match(r"^###\s+(6\.\d+)\b", section_h3)
                if m_sub:
                    kb.part6_subsections_seen.add(m_sub.group(1))

        # Parse Aggregate Scorecard rows.
        if section_h3.startswith("### Aggregate Scorecard"):
            cells = split_pipe_row(raw)
            if cells and len(cells) == 8 and not is_delimiter_row(cells) and cells[0] != "Domain":
                try:
                    nums = [int(re.sub(r"[*`,\s]", "", c)) for c in cells[2:]]
                except ValueError:
                    structural_errors.append((line_no, f"non-integer cell in Aggregate Scorecard: {raw}"))
                    continue
                m_range = re.search(r"`(MS|GPU|RT|APP|INF)-\d+`[–-]`\1-\d+`", cells[1])
                if m_range:
                    kb.scorecard_domains[m_range.group(1)] = (line_no, cells[1], nums)
                elif "Total" in cells[0]:
                    m_ids = re.search(r"(\d+)\s+IDs", cells[1])
                    kb.scorecard_total = (line_no, int(m_ids.group(1)) if m_ids else None, nums)
                else:
                    structural_errors.append((line_no, f"unrecognized Aggregate Scorecard row: {cells[0]}"))

        # Parse Master Attempt Ledger rows.
        if section_h3.startswith("### Master Attempt Ledger"):
            cells = split_pipe_row(raw)
            if cells and not is_delimiter_row(cells) and cells[0] != "ID":
                if len(cells) != 5:
                    structural_errors.append(
                        (line_no, f"Master Attempt Ledger row has {len(cells)} columns (expected 5)")
                    )
                    continue
                m_id = ANY_KB_ID_RE.search(cells[0])
                m_cat = CAT_BADGE_RE.search(cells[4])
                if not m_id or not m_cat:
                    structural_errors.append(
                        (line_no, f"malformed Master Attempt Ledger ID or Category cell: {cells[0]} / {cells[4]}")
                    )
                    continue
                id_str = m_id.group(1)
                cat_str = m_cat.group(1)
                m_tok = ID_TOKEN_RE.match(id_str)
                assert m_tok is not None
                dom, num_str = m_tok.group(1), m_tok.group(2)
                num = int(num_str)
                expected_fmt = f"{dom}-{num:02d}" if num < 100 else f"{dom}-{num}"
                if id_str != expected_fmt:
                    structural_errors.append(
                        (line_no, f"ID '{id_str}' must use canonical zero-padded format '{expected_fmt}'")
                    )
                if id_str in kb.ledger:
                    prev = kb.ledger[id_str].line
                    structural_errors.append(
                        (line_no, f"duplicate ID '{id_str}' in Master Attempt Ledger (first seen at line {prev})")
                    )
                else:
                    kb.ledger[id_str] = LedgerEntry(
                        id_str=id_str,
                        domain=dom,
                        number=num,
                        category=cat_str,
                        line=line_no,
                    )

        # Parse #### `<ID>` entries across the entire file.
        if raw.startswith("#### "):
            m_h4 = H4_ID_HEADING_RE.match(raw)
            if m_h4:
                hid = m_h4.group(1)
                if section_h2_part not in PART_TO_CATEGORY:
                    kb.stray_id_headings.append((line_no, hid))
                elif hid in kb.part_headings:
                    prev_line = kb.part_headings[hid][0]
                    kb.duplicate_part_headings.append((line_no, prev_line, hid))
                else:
                    m_badge = CAT_BADGE_RE.search(raw)
                    kb.part_headings[hid] = (
                        line_no,
                        section_h2_part,
                        m_badge.group(1) if m_badge else None,
                    )

        # Parse Part 6 (§6.1-§6.7) summary tables.
        if section_h2_part == 6 and section_h3.startswith("### 6."):
            cells = split_pipe_row(raw)
            if cells is None:
                part6_in_id_table = False
            elif cells[0] == "ID":
                part6_in_id_table = True
            elif part6_in_id_table and not is_delimiter_row(cells):
                m_id = ANY_KB_ID_RE.search(cells[0])
                if not m_id:
                    structural_errors.append(
                        (line_no, f"Part 6 summary table row missing valid `<ID>` in column 1: {cells[0]}")
                    )
                else:
                    kb.part6_table_ids.setdefault(m_id.group(1), []).append(line_no)

    return kb


def check_1_ids(kb: ParsedKB, structural_errors: list[tuple[int, str]]) -> CheckResult:
    res = CheckResult("1. ID Uniqueness & Contiguous Numbering")
    for line_no, msg in structural_errors:
        res.fail(kb.relpath, line_no, msg)

    if not kb.ledger_heading_line:
        res.fail(kb.relpath, 1, "missing '### Master Attempt Ledger' section")
        return res

    if kb.ledger_heading_claimed_total is not None and kb.ledger_heading_claimed_total != len(kb.ledger):
        res.fail(
            kb.relpath,
            kb.ledger_heading_line,
            f"Master Attempt Ledger heading claims {kb.ledger_heading_claimed_total} IDs, "
            f"but table has {len(kb.ledger)} unique IDs",
        )

    by_domain: dict[str, list[LedgerEntry]] = {d: [] for d in DOMAINS}
    for entry in kb.ledger.values():
        by_domain[entry.domain].append(entry)

    ranges_summary: list[str] = []
    for dom in DOMAINS:
        entries = sorted(by_domain[dom], key=lambda e: e.number)
        if not entries:
            res.fail(kb.relpath, kb.ledger_heading_line, f"domain '{dom}' has zero entries in Master Attempt Ledger")
            continue
        max_num = entries[-1].number
        present = {e.number for e in entries}
        if 1 not in present:
            res.fail(
                kb.relpath,
                entries[0].line,
                f"domain '{dom}' must start at {dom}-01 (lowest found is {entries[0].id_str})",
            )
        missing = [
            f"{dom}-{n:02d}" if n < 100 else f"{dom}-{n}"
            for n in range(1, max_num + 1)
            if n not in present
        ]
        if missing:
            res.fail(
                kb.relpath,
                entries[0].line,
                f"domain '{dom}' has numeric gap(s) in 01..{max_num:02d}: missing {', '.join(missing)}",
            )
        ranges_summary.append(f"{dom}-01..{max_num:02d} ({len(entries)})")

    res.summary = f"{len(kb.ledger)} unique contiguous IDs: " + ", ".join(ranges_summary)
    return res


def check_2_parity(kb: ParsedKB) -> CheckResult:
    res = CheckResult("2. Scorecard == Master Ledger == Parts 2-6 Parity")
    if not kb.scorecard_line:
        res.fail(kb.relpath, 1, "missing '### Aggregate Scorecard' section")
        return res

    # Scorecard vs Master Attempt Ledger
    col_sums = [0, 0, 0, 0, 0, 0]  # [Total, Cat A..Cat E]
    for dom in DOMAINS:
        dom_entries = [e for e in kb.ledger.values() if e.domain == dom]
        if dom not in kb.scorecard_domains:
            res.fail(kb.relpath, kb.scorecard_line, f"Aggregate Scorecard missing row for domain '{dom}'")
            continue
        row_line, range_cell, nums = kb.scorecard_domains[dom]
        max_num = max((e.number for e in dom_entries), default=0)
        expected_range = f"`{dom}-01`–`{dom}-{max_num:02d}`" if max_num < 100 else f"`{dom}-01`–`{dom}-{max_num}`"
        if range_cell.replace("-", "–") != expected_range.replace("-", "–"):
            res.fail(
                kb.relpath,
                row_line,
                f"Scorecard {dom} ID Range is '{range_cell}', expected '{expected_range}'",
            )
        expected_cats = [sum(1 for e in dom_entries if e.category == cat) for cat in CATEGORIES]
        expected_nums = [len(dom_entries), *expected_cats]
        if sum(nums[1:]) != nums[0]:
            res.fail(
                kb.relpath,
                row_line,
                f"Scorecard {dom} Cat A..E sum ({sum(nums[1:])}) != row Total ({nums[0]})",
            )
        if nums != expected_nums:
            res.fail(
                kb.relpath,
                row_line,
                f"Scorecard {dom} counts [Total, A..E] = {nums} != Master Ledger {expected_nums}",
            )
        for idx, val in enumerate(nums):
            col_sums[idx] += val

    if kb.scorecard_total is None:
        res.fail(kb.relpath, kb.scorecard_line, "Aggregate Scorecard missing 'Total Unique Tracked Attempts' row")
    else:
        tot_line, label_ids, tot_nums = kb.scorecard_total
        if label_ids is not None and label_ids != len(kb.ledger):
            res.fail(
                kb.relpath,
                tot_line,
                f"Scorecard Total label says '{label_ids} IDs', expected '{len(kb.ledger)} IDs'",
            )
        if tot_nums != col_sums:
            res.fail(
                kb.relpath,
                tot_line,
                f"Scorecard Total row {tot_nums} != column sums {col_sums}",
            )
        expected_tot = [
            len(kb.ledger),
            *[sum(1 for e in kb.ledger.values() if e.category == cat) for cat in CATEGORIES],
        ]
        if tot_nums != expected_tot:
            res.fail(
                kb.relpath,
                tot_line,
                f"Scorecard Total row {tot_nums} != Master Ledger totals {expected_tot}",
            )

    # Parts 2-6 #### `<ID>` headings vs Master Attempt Ledger
    for line_no, hid in kb.stray_id_headings:
        res.fail(kb.relpath, line_no, f"heading '#### `{hid}`' appears outside Parts 2-6")
    for dup_line, first_line, hid in kb.duplicate_part_headings:
        res.fail(
            kb.relpath,
            dup_line,
            f"duplicate heading '#### `{hid}`' in Parts 2-6 (first defined at line {first_line})",
        )

    for hid, (h_line, part_num, badge_cat) in kb.part_headings.items():
        expected_part_cat = PART_TO_CATEGORY[part_num]
        if badge_cat != expected_part_cat:
            res.fail(
                kb.relpath,
                h_line,
                f"heading '#### `{hid}`' in Part {part_num} has badge '{badge_cat}', expected '{expected_part_cat}'",
            )
        if hid not in kb.ledger:
            res.fail(kb.relpath, h_line, f"heading '#### `{hid}`' in Part {part_num} is missing from Master Ledger")
            continue
        ledger_entry = kb.ledger[hid]
        if ledger_entry.category != expected_part_cat:
            expected_part = CATEGORY_TO_PART[ledger_entry.category]
            res.fail(
                kb.relpath,
                h_line,
                f"category mismatch for '{hid}': in Part {part_num} ({expected_part_cat}), "
                f"but Master Ledger line {ledger_entry.line} marks it '{ledger_entry.category}' (Part {expected_part})",
            )

    for hid, entry in kb.ledger.items():
        if hid not in kb.part_headings:
            expected_part = CATEGORY_TO_PART[entry.category]
            res.fail(
                kb.relpath,
                entry.line,
                f"Master Ledger ID '{hid}' ({entry.category}) has no '#### `{hid}`' entry in Part {expected_part}",
            )

    part_counts = ", ".join(
        f"P{p}/{cat}={sum(1 for _, pn, _ in kb.part_headings.values() if pn == p)}"
        for p, cat in PART_TO_CATEGORY.items()
    )
    res.summary = f"1-to-1 match across Scorecard, {len(kb.ledger)} Ledger rows & {len(kb.part_headings)} entries ({part_counts})"
    return res


def check_3_part6_graveyard(kb: ParsedKB) -> CheckResult:
    res = CheckResult("3. Part 6 Graveyard (§6.1-§6.7) Parity")
    expected_subs = {f"6.{i}" for i in range(1, 8)}
    missing_subs = sorted(expected_subs - kb.part6_subsections_seen)
    if missing_subs:
        res.fail(kb.relpath, 1, f"Part 6 missing expected subsection(s): {', '.join(missing_subs)}")

    cat_e_entries = {hid: e for hid, e in kb.ledger.items() if e.category == "Cat E"}

    for hid, line_list in kb.part6_table_ids.items():
        if len(line_list) > 1:
            res.fail(
                kb.relpath,
                line_list[1],
                f"duplicate ID '{hid}' in Part 6 summary tables (also at line {line_list[0]})",
            )
        if hid not in kb.ledger:
            res.fail(kb.relpath, line_list[0], f"unknown ID '{hid}' in Part 6 summary table")
        elif kb.ledger[hid].category != "Cat E":
            res.fail(
                kb.relpath,
                line_list[0],
                f"non-Cat E ID '{hid}' ({kb.ledger[hid].category}, ledger line {kb.ledger[hid].line}) "
                f"listed in Part 6 Graveyard summary table",
            )

    for hid, entry in cat_e_entries.items():
        if hid not in kb.part6_table_ids:
            res.fail(
                kb.relpath,
                entry.line,
                f"Cat E ID '{hid}' is missing from Part 6 (§6.1-§6.7) summary tables",
            )

    res.summary = f"{len(kb.part6_table_ids)}/{len(cat_e_entries)} Cat E IDs indexed across §6.1-§6.7"
    return res


def check_4_links(root: Path, kb_path: Path, kb: ParsedKB) -> CheckResult:
    res = CheckResult("4. Internal Anchor & Cross-Doc Link Validity")
    kb_resolved = kb_path.resolve()

    # 4a. Internal (#anchor) links inside docs/BACKEND_KNOWLEDGE_BASE.md
    internal_checked = 0
    in_fence = False
    fence_marker = ""
    for line_no, raw in enumerate(kb.lines, 1):
        m_fence = FENCE_RE.match(raw)
        if m_fence:
            ticks = m_fence.group(1)
            if not in_fence:
                in_fence = True
                fence_marker = ticks[0] * len(ticks)
                continue
            if ticks[0] == fence_marker[0] and len(ticks) >= len(fence_marker):
                in_fence = False
                fence_marker = ""
                continue
        if in_fence:
            continue

        clean = strip_inline_code(raw)
        for m_link in MD_LINK_RE.finditer(clean):
            target = m_link.group(1).strip().split()[0]
            if target.startswith("#"):
                internal_checked += 1
                frag = target[1:]
                if frag not in kb.slugs:
                    res.fail(kb.relpath, line_no, f"unresolved internal anchor '(#{frag})'")

    # 4b. Relative links to BACKEND_KNOWLEDGE_BASE.md in AGENTS.md, README.md,
    #     Vendor/README.md, docs/*.md, and .agents/skills/*/SKILL.md
    peer_files: list[Path] = [
        root / "AGENTS.md",
        root / "README.md",
        root / "Vendor" / "README.md",
        *sorted((root / "docs").glob("*.md")),
        *sorted((root / ".agents" / "skills").glob("*/SKILL.md")),
    ]
    seen_files: set[Path] = set()
    cross_checked = 0

    for doc_path in peer_files:
        if not doc_path.is_file():
            continue
        doc_resolved = doc_path.resolve()
        if doc_resolved in seen_files:
            continue
        seen_files.add(doc_resolved)
        rel_doc = doc_path.relative_to(root).as_posix()
        doc_lines = doc_path.read_text(encoding="utf-8").splitlines()

        in_f = False
        f_mark = ""
        for line_no, raw in enumerate(doc_lines, 1):
            m_fence = FENCE_RE.match(raw)
            if m_fence:
                ticks = m_fence.group(1)
                if not in_f:
                    in_f = True
                    f_mark = ticks[0] * len(ticks)
                    continue
                if ticks[0] == f_mark[0] and len(ticks) >= len(f_mark):
                    in_f = False
                    f_mark = ""
                    continue
            if in_f:
                continue

            clean = strip_inline_code(raw)
            for m_link in MD_LINK_RE.finditer(clean):
                target = m_link.group(1).strip().split()[0]
                if target.startswith(("http://", "https://", "mailto:", "agello://", "file://", "conversation://")):
                    continue
                if "BACKEND_KNOWLEDGE_BASE.md" not in target:
                    continue
                cross_checked += 1
                path_part, _, frag = target.partition("#")
                candidate = (doc_path.parent / path_part).resolve() if path_part else doc_resolved
                if candidate != kb_resolved or not candidate.is_file():
                    res.fail(
                        rel_doc,
                        line_no,
                        f"broken relative link '{target}' (resolved to {candidate})",
                    )
                elif frag and frag not in kb.slugs:
                    res.fail(
                        rel_doc,
                        line_no,
                        f"unresolved BACKEND_KNOWLEDGE_BASE.md anchor '#{frag}' in '{target}'",
                    )

    res.summary = f"{internal_checked} internal KB anchors + {cross_checked} cross-doc links verified"
    return res


def validate_tables_and_mermaid(path: Path, relpath: str, res: CheckResult, check_mermaid: bool) -> tuple[int, int]:
    lines = path.read_text(encoding="utf-8").splitlines()
    in_fence = False
    fence_marker = ""
    fence_open_line = 0
    in_mermaid = False
    mermaid_blocks = 0

    table_start_line: int | None = None
    table_expected_cols: int | None = None
    table_row_index = 0
    table_count = 0

    for line_no, raw in enumerate(lines, 1):
        m_fence = FENCE_RE.match(raw)
        if m_fence:
            ticks, info = m_fence.group(1), m_fence.group(2).strip().lower()
            if not in_fence:
                if table_start_line is not None and table_row_index < 2:
                    res.fail(relpath, table_start_line, "incomplete 1-row Markdown pipe table")
                table_start_line = None
                table_expected_cols = None
                table_row_index = 0

                in_fence = True
                fence_marker = ticks[0] * len(ticks)
                fence_open_line = line_no
                in_mermaid = info.startswith("mermaid")
                if in_mermaid:
                    mermaid_blocks += 1
                continue
            if ticks[0] == fence_marker[0] and len(ticks) >= len(fence_marker):
                in_fence = False
                fence_marker = ""
                in_mermaid = False
                continue

        if in_fence:
            if check_mermaid and in_mermaid:
                m_html = MERMAID_HTML_TAG_RE.search(raw)
                if m_html:
                    res.fail(
                        relpath,
                        line_no,
                        f"forbidden HTML tag '{m_html.group(0)}' inside mermaid block (use \\n inside quoted labels)",
                    )
            continue

        cells = split_pipe_row(raw)
        if cells is not None:
            if table_start_line is None:
                table_start_line = line_no
                table_expected_cols = len(cells)
                table_row_index = 1
                table_count += 1
            else:
                table_row_index += 1
                assert table_expected_cols is not None
                if len(cells) != table_expected_cols:
                    res.fail(
                        relpath,
                        line_no,
                        f"Markdown table (started at line {table_start_line}) expects "
                        f"{table_expected_cols} columns, got {len(cells)}",
                    )
                elif table_row_index == 2 and not is_delimiter_row(cells):
                    res.fail(
                        relpath,
                        line_no,
                        f"Markdown table (started at line {table_start_line}) missing valid separator row on row 2",
                    )
        else:
            if table_start_line is not None and table_row_index < 2:
                res.fail(relpath, table_start_line, "incomplete 1-row Markdown pipe table")
            table_start_line = None
            table_expected_cols = None
            table_row_index = 0

    if in_fence:
        res.fail(relpath, fence_open_line, f"unclosed code fence '{fence_marker}'")
    if table_start_line is not None and table_row_index < 2:
        res.fail(relpath, table_start_line, "incomplete 1-row Markdown pipe table")

    return table_count, mermaid_blocks


def check_5_hygiene(root: Path, kb_path: Path, kb: ParsedKB) -> CheckResult:
    res = CheckResult("5. Markdown Tables, Mermaid & Zero Attribution Hygiene")

    kb_tables, kb_mermaids = validate_tables_and_mermaid(kb_path, kb.relpath, res, check_mermaid=True)
    readme_path = root / "README.md"
    readme_tables = 0
    if readme_path.is_file():
        readme_tables, _ = validate_tables_and_mermaid(readme_path, "README.md", res, check_mermaid=True)

    strict_files: list[Path] = [
        kb_path,
        root / "README.md",
        root / "Vendor" / "README.md",
        root / "NOTICE",
        root / "Agello" / "Resources" / "NOTICE.txt",
    ]
    all_scan_files: list[Path] = [
        *strict_files,
        *sorted((root / "docs").glob("*.md")),
        root / "AGENTS.md",
        *sorted((root / ".agents" / "skills").glob("*/SKILL.md")),
    ]
    strict_resolved = {p.resolve() for p in strict_files if p.is_file()}
    scanned: set[Path] = set()

    for path in all_scan_files:
        if not path.is_file():
            continue
        resolved = path.resolve()
        if resolved in scanned:
            continue
        scanned.add(resolved)
        rel = path.relative_to(root).as_posix()
        is_strict = resolved in strict_resolved

        for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            m_common = COMMON_ATTRIBUTION_RE.search(raw)
            if m_common:
                res.fail(rel, line_no, f"forbidden AI/agent/swarm attribution term '{m_common.group(0)}'")
                continue
            if is_strict:
                m_strict = KB_STRICT_ATTRIBUTION_RE.search(raw)
                if m_strict:
                    res.fail(rel, line_no, f"forbidden AI/agent attribution term '{m_strict.group(0)}'")

    res.summary = (
        f"{kb_tables + readme_tables} tables uniform, {kb_mermaids} KB mermaid block(s) HTML-free, "
        f"{len(scanned)} docs attribution-clean"
    )
    return res


def batch_verify_commits(repo_dir: Path, sha_lines: dict[str, list[int]], repo_label: str, kb_rel: str, res: CheckResult) -> None:
    if not sha_lines:
        return
    shas = list(sha_lines.keys())
    payload = "".join(f"{sha}^{{commit}}\n" for sha in shas)
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo_dir), "cat-file", "--batch-check"],
            input=payload,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        res.fail(kb_rel, 1, f"failed to invoke git for {repo_label} ({repo_dir}): {exc}")
        return

    if proc.returncode != 0:
        err = proc.stderr.strip() or f"exit {proc.returncode}"
        res.fail(kb_rel, 1, f"git cat-file --batch-check failed in {repo_label} ({repo_dir}): {err}")
        return

    out_lines = proc.stdout.splitlines()
    if len(out_lines) != len(shas):
        res.fail(
            kb_rel,
            1,
            f"git cat-file --batch-check returned {len(out_lines)} lines for {len(shas)} {repo_label} SHAs",
        )
        return

    for sha, verdict in zip(shas, out_lines):
        if " commit " not in verdict:
            first_line = sha_lines[sha][0]
            other = f" (also at lines {', '.join(map(str, sha_lines[sha][1:]))})" if len(sha_lines[sha]) > 1 else ""
            res.fail(kb_rel, first_line, f"unresolvable {repo_label} commit SHA '{sha}'{other}: {verdict}")


def check_6_git_provenance(root: Path, kb: ParsedKB, skip_git: bool) -> CheckResult:
    res = CheckResult("6. Git Commit SHA Provenance")
    if skip_git:
        res.summary = "skipped (--skip-git)"
        return res

    irt_shas: dict[str, list[int]] = {}
    lrt_shas: dict[str, list[int]] = {}
    for line_no, raw in enumerate(kb.lines, 1):
        for m in EXPLICIT_COMMIT_RE.finditer(raw):
            repo_tag, sha1, sha2 = m.group(1), m.group(2), m.group(3)
            bucket = irt_shas if repo_tag == "iRT" else lrt_shas
            bucket.setdefault(sha1, []).append(line_no)
            if sha2:
                bucket.setdefault(sha2, []).append(line_no)

    batch_verify_commits(root, irt_shas, "iRT", kb.relpath, res)

    lrt_root = root.parent / "LiteRT-LM"
    if lrt_root.exists() and (lrt_root / ".git").exists():
        batch_verify_commits(lrt_root, lrt_shas, "LiteRT-LM", kb.relpath, res)
        res.summary = f"{len(irt_shas)} iRT + {len(lrt_shas)} LiteRT-LM unique commit SHAs verified"
    else:
        res.summary = f"{len(irt_shas)} iRT unique commit SHAs verified (../LiteRT-LM not present)"

    return res


def check_7_repo_doc_parity(root: Path, kb: ParsedKB) -> CheckResult:
    res = CheckResult("7. Repo Doc Parity")

    # 7a. docs/ROADMAP.md `## Current status` <= 3,000 bytes (matching session-start.sh).
    roadmap_path = root / "docs" / "ROADMAP.md"
    roadmap_rel = "docs/ROADMAP.md"
    status_bytes = 0
    status_text = ""
    if not roadmap_path.is_file():
        res.fail(roadmap_rel, 1, "missing docs/ROADMAP.md")
    else:
        r_lines = roadmap_path.read_text(encoding="utf-8").splitlines()
        start_line: int | None = None
        collected: list[str] = []
        for idx, raw in enumerate(r_lines, 1):
            if raw == "## Current status":
                start_line = idx
                collected.append(raw)
                continue
            if start_line is not None:
                if raw.startswith("## "):
                    break
                collected.append(raw)
        if start_line is None:
            res.fail(roadmap_rel, 1, "missing '## Current status' heading")
        else:
            status_text = "\n".join(collected).rstrip("\n")
            status_bytes = len(status_text.encode("utf-8"))
            if status_bytes > ROADMAP_STATUS_MAX_BYTES:
                res.fail(
                    roadmap_rel,
                    start_line,
                    f"'## Current status' is {status_bytes} bytes (exceeds {ROADMAP_STATUS_MAX_BYTES}-byte cap)",
                )

    # 7b. Vendor/LiteRT-LM/Package.swift release tag parity with README.md (+ KB & ROADMAP).
    pkg_path = root / "Vendor" / "LiteRT-LM" / "Package.swift"
    pkg_rel = "Vendor/LiteRT-LM/Package.swift"
    tag_note = "local binaryTarget"
    if not pkg_path.is_file():
        res.fail(pkg_rel, 1, "missing Vendor/LiteRT-LM/Package.swift")
    else:
        pkg_text = pkg_path.read_text(encoding="utf-8")
        m_tag = re.search(r"releases/download/([^/\s\"']+)/", pkg_text)
        if m_tag:
            shipped_tag = m_tag.group(1)
            tag_note = f"tag={shipped_tag}"
            readme_path = root / "README.md"
            if not readme_path.is_file():
                res.fail("README.md", 1, "missing README.md")
            else:
                readme_text = readme_path.read_text(encoding="utf-8")
                readme_lines = readme_text.splitlines()
                if shipped_tag not in readme_text:
                    res.fail(
                        "README.md",
                        1,
                        f"README.md does not reference shipped runtime tag '{shipped_tag}' from {pkg_rel}",
                    )
                for lno, rline in enumerate(readme_lines, 1):
                    for m_rel_url in re.finditer(
                        r"github\.com/PowerBeef/agello-litert-lm/releases/tag/([A-Za-z0-9._-]+)",
                        rline,
                    ):
                        found_tag = m_rel_url.group(1)
                        if found_tag != shipped_tag:
                            res.fail(
                                "README.md",
                                lno,
                                f"stale release tag link '{found_tag}' in README.md (Package.swift ships '{shipped_tag}')",
                            )

            # Verify Active Baseline in KB header and ROADMAP Current status also name shipped_tag.
            kb_header = "\n".join(kb.lines[:20])
            if shipped_tag not in kb_header:
                res.fail(
                    kb.relpath,
                    1,
                    f"Active Baseline header does not reference shipped runtime tag '{shipped_tag}'",
                )
            if status_text and shipped_tag not in status_text:
                res.fail(
                    roadmap_rel,
                    7,
                    f"'## Current status' does not reference shipped runtime tag '{shipped_tag}'",
                )

    res.summary = f"ROADMAP Current status = {status_bytes}/{ROADMAP_STATUS_MAX_BYTES} B, {tag_note}"
    return res


def run_all_checks(root: Path, skip_git: bool = False) -> tuple[list[CheckResult], float]:
    t0 = time.perf_counter()
    kb_rel = "docs/BACKEND_KNOWLEDGE_BASE.md"
    kb_path = root / "docs" / "BACKEND_KNOWLEDGE_BASE.md"
    if not kb_path.is_file():
        missing = CheckResult("0. Knowledge Base File")
        missing.fail(kb_rel, 1, "missing docs/BACKEND_KNOWLEDGE_BASE.md")
        return [missing], time.perf_counter() - t0

    structural_errors: list[tuple[int, str]] = []
    kb = parse_kb(kb_path, kb_rel, structural_errors)

    results = [
        check_1_ids(kb, structural_errors),
        check_2_parity(kb),
        check_3_part6_graveyard(kb),
        check_4_links(root, kb_path, kb),
        check_5_hygiene(root, kb_path, kb),
        check_6_git_provenance(root, kb, skip_git=skip_git),
        check_7_repo_doc_parity(root, kb),
    ]
    return results, time.perf_counter() - t0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--skip-git",
        action="store_true",
        help="skip git commit SHA verification against iRT and ../LiteRT-LM",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="path to iRT repository root (default: parent of scripts/)",
    )
    parser.add_argument("--quiet", "-q", action="store_true", help="only print summary or failures")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    results, elapsed = run_all_checks(root, skip_git=args.skip_git)
    failed = [r for r in results if not r.ok]

    if not args.quiet:
        for r in results:
            badge = "PASS" if r.ok else "FAIL"
            detail = f" ({r.summary})" if r.summary and r.ok else ""
            print(f"[{badge}] {r.name}{detail}")

    if failed:
        total_errs = sum(len(r.errors) for r in failed)
        for r in failed:
            for err in r.errors:
                print(f"error: {err}", file=sys.stderr)
        print(
            f"FAIL: {len(failed)}/{len(results)} check group(s) failed ({total_errs} error(s)) in {elapsed:.3f}s",
            file=sys.stderr,
        )
        return 1

    print(f"PASS: all {len(results)}/{len(results)} knowledge-base & doc-parity checks passed in {elapsed:.3f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
