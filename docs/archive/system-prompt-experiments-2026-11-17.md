> [!IMPORTANT]
> **Archived experiment log (2026-11-17).** This document preserves the four prompt-screening rounds on M6 that selected **D8** as `SystemPrompt.base` and tuned `Personalization.Style.concise`. For the live system prompt and prompt-composition specification, see [docs/SYSTEM-PROMPT.md](../SYSTEM-PROMPT.md).

# The chat system prompt: candidate experiments (2026-11-17)

**Historical record (2026-11-17):** four rounds ran on the M6 (`ProbeScenarioTests/test34_SystemPromptTable` in `AgelloDeviceTests/SystemPromptProbes.swift`, now gated behind `HARNESS_RESEARCH_PROBES=1` / `research-probes`). Round 3 initially promoted **D4** into the app; Round 4 superseded it the same day with **D8** (D4 with examples of what may have changed and an explicit answer to "what model are you?", placed last). Before this work, `SystemPrompt.base` was `"You are a helpful on-device assistant."`

## Round 4 (2026-11-17, M6): D8 supersedes D4

Probe 34 on the fork's runtime (build `ca7bbff03b2c` and later), the table grown to 63 cases and 142 checks: three Think cases (a capital, a train trip's length, counting words in Python), and "What model are you?" checked for the model's name.

| Candidate | Checks | What it changes from D4 |
| --- | --- | --- |
| D4 | 138/142 | (fails identity, the bakery, iOS, the World Cup) |
| D5 | 140/142 | The identity line says "built on Google's Gemma 4 model"; the knowledge line's examples, "such as the latest version, holder or winner of something" |
| D5t | 139/142 | D5 with the Think line ("Think briefly about simple questions, and reason fully about math, code and problems with several steps.") |
| D6 | 140/142 | D5, the identity line reworded ("…with Google's Gemma 4 model, entirely on the device") |
| D7 | 138/142 | D5's examples, and near the top: "If asked what you are or which model you run, say you're Agello, running Google's Gemma 4 model on the device." |
| **D8** | **141/142** | D5's examples, and that sentence last instead |

What reading the replies showed:
- **Identity.** The model calls itself Gemma 4 when the identity line names Gemma: D5 and D6 answered "I am Gemma 4, an assistant running on your iPhone, built on Google's Gemma 4 model". The explicit answer works ("I am Agello, running Google's Gemma 4 model on your device"), but near the top it moved other replies: D7 left "See you tomorrow at the station" untranslated and lost the keys from HTTPS. Placed last (D8), it moves nothing that the checks see.
- **The Think line is out.** Thought on the capital wasn't shorter (171 characters against 146). On the train trip, the thought shortened (1,372 against 1,732) but the answer came out wrong.
- **What may have changed.** D8 answers the iOS question with "likely iOS 18 … You can tap Search" instead of only pointing to Search. The World Cup is still called 2022's without a caveat in every candidate. Iceland's population lost its caveat in D8.
- D8's replies are identical to D4's in 18 of 63 cases. The others differ in wording, and some are better: the Saturday plan gives options before asking, and the tomato answer is shorter.

**Outcome:** `SystemPrompt.base` shipped as **D8**.

## Earlier integration pass (2026-11-17, M6, pre-Round 4): D4 promotion check

Before Round 4 selected D8, **D4** was placed in `SystemPrompt.base` (`{date}`, `{current}`, `{precedence}` filled by `SystemPrompt.compose`) and checked across the M6 promotion suites. Probes that build conversations of their own keep the legacy line (`ProbeScenarioTests.recordedSystemPrompt`), and `HARNESS_SYSTEM_PROMPT=legacy` runs any suite with the legacy line for an A/B on the same build.

The promotion suites, natively on the M6 with the then-shipped runtime (`0c749789100a`):

| Suite | D4 | Legacy line, where D4 failed |
| --- | --- | --- |
| `unit` | 309/309 | |
| `inference` (test90 left out) | 22/22 | |
| `files` | 5/5 | |
| `thinking` | 2/3: test02 | 3/3 |
| `web` | 6/9: test01, test04, test06 | test01 passes, test06 fails |

What the failures showed:
- **`thinking` test02 surfaced a runtime MTP tail-token bug.** In the three-turn Think chat, "Now divide it by 4" came back "10" after "400" because speculative decoding rolled back one token too many at end of turn (`AgelloDeviceTests/ThinkTailProbe.swift`, probe 35). Fixed in the fork the same evening (`e62e6ff1`); on the fixed build (`8ba3a9ff1747`), `thinking` passed 3/3, `inference` 22/22, `files` 5/5, and `web` 7/9. The reasoning-length floor in `test02` was adjusted to 100 bytes because D4 thought more concisely on a simple product (118 bytes vs 350).
- **`web` test01 / test04 / test06** were search-planner and Mac-no-location issues rather than base prompt regressions (subsequently resolved by `WebContext.replansAsQuestion` and `LanguageSupport`).

## Confirmation round (2026-11-17, M6): D4 leads

The same probe (`test34_SystemPromptTable`), natively, with the table grown to 60 cases and 137 checks (adding Korean, Russian, Arabic, Dutch, French coding, tasks, false premises, two 4-turn chats, and four personalization cases). Greedy replies repeated in 59 of 60 cases across two runs of D3.

| Candidate | Checks | Prompt (est. tokens) | Output, 60 cases | Task family |
| --- | --- | --- | --- | --- |
| D | 128/137 | 282 | 13,842 tokens | 10/16 |
| D3 | 130/137 | 303 | 14,579 | 12/16 |
| D3a, D3 reworded line by line | 129/137 | 324 | 14,903 | 12/16 |
| D3b, D3 packed into fewer, longer lines | 126/137 | 251 | 15,904 | 11/16 |
| **D4** | **133/137** | 345 | 14,574 | 15/16 |

Key observations:
- **D3's wording holds under paraphrase, and paragraph structure matters:** packing lines together (D3b) degraded translation, Iceland's population, and recipe behavior.
- **D4 fixed preference-question stalling** on open-ended tasks and stopped date recitation outside date questions.
- **Personalization worked through `{precedence}`**, except `Personalization.Style.concise`, whose original wording left answers at 1,000–1,200 characters. Tuned the same day in probe 37 (`AgelloDeviceTests/StyleProbe.swift`) to: *"Keep answers short: two to four sentences for a question. For a recipe, a plan or steps, give only what's needed to do it, as a compact list. Leave out background, caveats, summaries and offers of more help."* (cutting total length across 10 everyday asks from 10,900 to ~4,000 chars while keeping recipe amounts and trip plans intact).

## Screening round 1 (2026-11-17, M6)

`ProbeScenarioTests/test34_SystemPromptTable` (`AgelloDeviceTests/SystemPromptProbes.swift`), tools on, automatic search off, greedy (MTP on): 33 cases, 75 checks.

| Candidate | Checks | Prompt (est. tokens) | Output, 33 replies |
| --- | --- | --- | --- |
| A, legacy (`You are a helpful on-device assistant.`) | 61/75 | 13 | 12,591 tokens |
| B (date, language, shape) | 68/75 | 111 | 10,085 |
| C (B + knowledge limit & uncertainty) | 71/75 | 219 | 10,014 |
| D (all eight defaults) | 72/75 | 281 | 7,666 |
| E (long control, ~450–550 tokens) | 71/75 | 698 | 4,860 |

Follow-up rewordings of D on 24 cases (51 checks, English date via `PromptText.date(.now)` after fixing locale leakage in `66a88d9`): **D3** scored **49/51**, D scored 47/51, and D2 moved unrelated facts (rejected).

## Candidate texts archived from Round 1–3

- **A (legacy):** `You are a helpful on-device assistant.`
- **B–D:** progressively added identity + `{date}`, early-2025 knowledge limit + `{current}`, reply language, answer-first shape, do-the-task default, calibrated uncertainty, and `{precedence}`.
- **E (long control):** 8 labeled sections (`Knowledge`, `Language`, `Shape`, `Tasks`, `Honesty`, `Tone`, `Safety`) — diluted adherence and made the model overly terse/deflective; rejected as expected.
- **D-think / D5t:** explicit Think-length hint shortened reasoning on a multi-step train problem and broke the answer; rejected.

## Follow-up fixes placed outside the system prompt

All key prompt-adjacent issues identified on 2026-11-17 were subsequently addressed in code:
- Comma-list citation validation (`d159ad1`).
- Untrusted block stripping before persistent memory extraction (`c02d942`, `fc3d375`, `UntrustedContext.stripUntrustedBlocks`).
- Non-optional required `@ToolParam` arguments (`a96bd87`, P5.1).
- Calendar-aware weather Today/Tomorrow labels (`45c7ebe`).
- Multilingual structured queries and 13-language `LanguageSupport.swift` (`6864e2b`).
- Canonical image-before-text ordering (`8382f04`, P4.2).
- Live `<thought>` KV continuity across intermediate tool steps (`LiteRT-LM@7d80c7ec`, P5.1).
