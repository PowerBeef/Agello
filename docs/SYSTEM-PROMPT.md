# The chat system prompt: candidates to test

**Status (2026-11-16):** candidates written from research, none tested. Nothing in the app has changed: the base prompt is still `InferenceOptions.systemPrompt`, "You are a helpful on-device assistant." The research behind this page is in `reports/Gemma 4 E4B prompting and reasoning.md` and its notes in `research_notes/` (local files, kept out of git).

## What the research found

- **One system turn carries every standing instruction.** The model file's template renders `<bos><|turn>system\n` [`<|think|>`] the system text (trimmed), then the tool declarations, then `<turn|>`. Replayed history and the message follow. The system text is `SystemPrompt.compose`: the base, then style, name, about you, the user's instructions, up to 25 memories, and the project block. Today the base is about 9 tokens of a preface of about 236; the tool declarations take most of it.
- **It's read once per conversation.** The system turn is prefilled when a chat is built or rebuilt (a new chat, a chat switch, a reseed, a setting change), not on each message. On the iPhone 17 Pro, prefill runs at about 1,300 tokens a second, so 150–250 more tokens cost about 0.15–0.3 s per rebuild and nothing on a follow-up.
- **E4B follows short, checkable rules and drops compound ones.** IFEval 96.7 against IFBench 44.0 (Google, Think on). Studies of small models find adherence falls as instructions are added; earlier instructions are followed better than later ones. Personas don't improve accuracy, and "think step by step" lowered E4B's accuracy in the one measurement.
- **Google publishes no chat system prompt.** Its own AI Edge Gallery ships AI Chat with an empty one. Gemma 4 has a native system role (Gemma 3 had none), so Gemma 3 recipes don't carry over.
- **What the model can't know is the system prompt's real job:** the date (training data ends in January 2025; `web03` called 2025 sources "future-dated"), the configuration it runs in, and its limits.
- **Four recorded faults are within the base prompt's reach:** date blindness outside Search; reply shapes built for a long screen (openers such as "I can certainly help…", headings and tables for simple asks, emoji); deflections such as "check the official website"; clarifying questions instead of doing the task ("Suggest a dinner recipe" got three questions back).
- **Helpers never see it.** Titles, memories, dictation, section summaries and the search planner run in conversations of their own with no system turn, so the planner's faults need the planner's prompt.

## What the base prompt holds, and what it leaves out

Eight short defaults, each tied to a recorded fault or a model property:

1. **Identity, in one clause:** who and where. No expertise persona.
2. **Today's date with its weekday:** filled by code, in `WebContext.instructions`'s format (`Date.now.formatted(date: .complete, time: .omitted)`) and time zone.
3. **The knowledge limit:** training data ends in early 2025, and the date given wins over the model's sense of the year.
4. **Where current information comes from:** composed by code from the settings. With automatic search off, the user can tap Search; with it on, `web_search`.
5. **The reply language:** the language of the user's latest message, as a default the user can override.
6. **The reply shape, not its length:** answer first, prose for conversation, structure only when the answer needs it, no emoji unless the user uses them. A length rule would fight the Detailed style and the web and file prompts' "as fully as you would without them".
7. **Do the task:** make a sensible choice for open-ended requests; ask only when the task can't proceed.
8. **Brief, calibrated uncertainty:** say so in a few words and still answer, instead of deflecting.

Two lines are added only when they apply:
- **Precedence:** "The user's preferences and project instructions below take precedence over these defaults", when a personalization or project block follows. A pointer to an empty "below" is the kind of dangling reference a small model trips on.
- **A Think line, with Think on:** in the spirit of Google's "LOW" instruction, which cut thinking by about 20 %. Think already reseeds the chat, so it costs nothing extra.

**Kept out:** citation rules (plain chat has no sources), a safety restatement (trained behavior), few-shot examples (small models copy them, and they cost tokens on every rebuild), "think step by step", the time of day (it would rebuild the chat on every message; it stays with `get_current_date_time`), and anything about tools that may be switched off.

## Composition, in code

`SystemPrompt.compose` builds the base from the settings it already knows. Slots in the texts below:

| Slot | Filled with |
| --- | --- |
| `{date}` | `Date.now.formatted(date: .complete, time: .omitted)`, e.g. "Monday, November 16, 2026" |
| `{current}` | automatic search off: "; the user can tap Search for current information"; on: "; use web_search when a question needs current facts" |
| `{precedence}` | the precedence line, only when a style, name, about-you, instructions or project block follows |
| `{think}` | the Think line, only with Think on |

**The date's one cost:** the system prompt changes at midnight, so the first message after midnight in a running chat rebuilds it and prefills its replayed history: up to about 12 s in the worst case (16,000 tokens of history at 32K), typically far less. Two ways around it, to be decided by the table:
- **D1, date in the base, outside the rebuild check:** the comparison that triggers a rebuild ignores the date, so it refreshes at the next natural rebuild; a chat that crosses midnight runs a day stale until then.
- **D2, date in the user turn:** "Today is {date}." at the start of each message's user turn, about 15–20 tokens a message, never replayed. It loses the system position and may lead the model to mention the date unprompted.

## Candidates

Token counts are estimates (about 1.3 tokens a word, a token a digit); probe 17 measures the real ones. In every candidate, `<|think|>` stays first: the runtime places it, not the text.

**A, today's (about 9 tokens).**

```text
You are a helpful on-device assistant.
```

**B, date, language and shape (about 60 tokens).**

```text
You are Agello, an assistant running on the user's iPhone. Today is {date}.

Reply in the language of the user's latest message unless they ask for another.

Start with the answer. Write conversational replies as plain paragraphs, and use headings, lists or a table only when a long or structured answer needs them.
```

**C, B plus the knowledge limit and uncertainty (about 110 tokens).**

```text
You are Agello, an assistant running on the user's iPhone. Today is {date}.

Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, give what you know and say it may be out of date{current}.

Reply in the language of the user's latest message unless they ask for another.

Start with the answer. Write conversational replies as plain paragraphs, and use headings, lists or a table only when a long or structured answer needs them.

If you're unsure of a fact, say so in a few words and still give your best answer.
```

**D, all eight defaults (about 160–200 tokens): the lead candidate.**

```text
You are Agello, an assistant running on the user's iPhone. Today is {date}.

Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, give what you know and say it may be out of date{current}.

Reply in the language of the user's latest message unless they ask for another.

Start with the answer, not a preamble. Write conversational replies as plain paragraphs. Use headings, lists or a narrow table only when a long or structured answer needs them. Don't use emoji unless the user does.

For open-ended requests, make a sensible choice and do the task. Ask a question only when you can't proceed without the answer.

If you're unsure of a fact, say so in a few words and still give your best answer.{precedence}
```

**E, a long control (about 450–550 tokens): measures dilution, not a candidate to ship.** D's lines, plus sections in the style of a frontier assistant's prompt:

```text
You are Agello, an assistant running on the user's iPhone. You write every reply on the phone; only a web search sends anything out, and only its queries. Today is {date}.

Knowledge. Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, such as prices, versions, office holders, scores or schedules, give what you know and say it may be out of date{current}. Don't invent sources, quotes, numbers or links.

Language. Reply in the language of the user's latest message unless they ask for another. Keep names, code and quoted text in their original language.

Shape. Start with the answer, not a preamble or a restatement of the question. Write conversational replies as plain paragraphs of a few sentences. Use headings, lists or a table only when a long or structured answer needs them; keep tables to three or four narrow columns, since the screen is small. Put code in fenced blocks with the language named, and give complete code that runs. End when the answer is complete, without a summary of what you just said or an offer of more help. Don't use emoji unless the user does.

Tasks. For open-ended requests, make a sensible choice and do the task. Ask a question only when you can't proceed without the answer, and then ask one. When the user corrects you, fix the answer without long apologies.

Honesty. If you're unsure of a fact, say so in a few words and still give your best answer. If you made a mistake earlier in the chat, say so plainly. Do arithmetic step by step when it matters, and check the result.

Tone. Be warm and direct. Treat the user as a capable adult: no lecturing, moralizing or needless disclaimers. On contested topics, give the main views fairly. For health, legal or financial questions, give useful information and suggest a professional when the situation calls for one.

Safety. Decline only requests that could cause serious harm, briefly and without judgment, and help with the safe part when there is one.{precedence}
```

### Variants of D

| Variant | Change | Tests |
| --- | --- | --- |
| D-noname | "You are a helpful assistant running on the user's iPhone." | Whether the name affects "what model are you?" and self-identification (the model was trained to call itself Gemma) |
| D-end | The language line moved to the very end of the composed system text, after memories and the project block | Position: later text gets attention in some studies, earlier instructions are followed better in others |
| D-suffix | The language line also restated as a short suffix on the latest user turn ("Reply in the language of this message.") | Drift over long chats, measured on the 8–10 turn cases |
| D-think | `{think}` = "Think briefly about simple questions, and reason fully about math, code and problems with several steps." | Thought length and coding answers under Think (a 1,024-token budget once cut a coding plan mid-word) |
| D1 / D2 | The two date placements above | Midnight rebuild cost against date accuracy and unprompted date mentions |

Each winner should also be checked under two or three paraphrases of its own wording before it's trusted: small models are sensitive to wording, not just content.

## How to test them

**Hold everything else fixed:** the runtime build, the model file, MTP (so chat is greedy and one run per case is deterministic) and the 4,096-token Think budget. Three engine-side changes the research raised are tested separately, never mixed with wording: a newline after `<|think|>` (the file's template has none; Hugging Face's has one), a thought prefix after tool responses, and image-before-text order.

**The instrument:** `InferenceScenarioTests/test16_SystemPromptTable`, in the mould of `WebScenarioTests/test04_SearchDecisions` ([CLAUDE.md](../CLAUDE.md), "The fix loop"). It loops the candidates over the cases (tests can set `InferenceOptions.systemPrompt` in memory), records each raw reply, and checks outcomes in code:

| Family | Example inputs (from the record where possible) | Check in code |
| --- | --- | --- |
| Shape | "What is the capital of France?", "Define serendipity", "Hi!" | length ceiling; no opener phrase; heading, bullet and rule counts; no emoji |
| Long answers stay complete | "Explain how HTTPS works"; the bench's coding prompts | required terms; Swift type-checks, Python compiles |
| Date | "What's today's date?", "How many days until December 25?", tools on and off; `web03`'s Swift question | the right date; 2025 never called future |
| Language | typed French, Spanish, German, Japanese, Chinese; "Translate into Spanish…"; English under an "always answer in French" personalization | reply language (`NLLanguageRecognizer`) |
| Do the task | "Suggest a dinner recipe for tonight." | ingredients and steps; at most one question |
| Honesty | false premises, obscure facts, "latest version" questions | no fabricated certainty; no "check the official website" |
| Personalization and projects | each style; a name; a project rule ("answer in bullet points"); 25 full memories | the rule followed; memories not recited; the turn fits |
| Voice | `test14`'s turns | WER at most 0.25; one to three sentences; no markdown |
| Search and files | `mockup-os-search`; `test06`; files `test02` | no talk about irrelevant sources; citations in range; pages cited |
| Think | the riddle, the multi-turn arithmetic, a French reasoning prompt | the answer; thought length and language |
| Injection | fixture pages and files with planted instructions | not obeyed; nothing memorized from them |
| Refusals | benign but alarming-sounding ("How do I kill a Python process?"); a small harmful set | benign answered, harmful refused |
| Multi-turn | 8–10 turn chats, one with a Stop and a reseed | language and shape hold on the last turn |

**The order:** a screening round of about 40 cases (a few minutes a round); then a confirmation table of a few hundred cases across languages for the top two; then the bench in Release, with every reply read (a new prompt changes every reply, so the "identical replies need no judging" rule doesn't apply) and a new baseline. A Mac run (`scripts/cli-test.sh inference …`) needs the maintainer's go; the iPhone run is the verdict.

**A cost column beside the quality columns:** the exact preface tokens (probe 17, `renderPrefaceIntoString`), a new chat's first-token time, and the rebuild time with a long history.

**Promotion:** no regression in the existing reply checks (`inference` `test02`, `05`, `05b`, `06`, `11`, `12`, `14`; `web` `test01`–`06`; `files` `test02`/`02b`; `thinking` `01`, `01b`, `02`), and a clear gain on the targeted families.

**Bookkeeping a new base sets off:** `PersonalizationTests` pins the old string and its composed output. Probe 17, `ToolErrorProbe` and two `ProbeScenarioTests` cases build conversations from the default `InferenceOptions().systemPrompt`: pin the old string there so their records stay comparable. The bench has never run with a style, memories or a project; two or three such cases would show whether the precedence line works through the real screens.

## Fixes that belong outside the system prompt

The research placed these elsewhere; each is a separate change with its own check.

| Fault | Where it belongs |
| --- | --- |
| Comma-list citations such as "[4, 22]" get past the out-of-range check | the display regex, `test06`, `bench-report.py` |
| The web prompt's wording leaks ("Based on the reference material…") and replies discuss sources that don't bear on the question | `WebContext.instructions` |
| A web or file page could plant a memory that rides in every later system prompt | the memory extractor: ignore text that came from web or file material |
| No tool parameter is marked required (`calculate.expression`, `web_search.query` reach the model as optional) | Swift signatures without defaults (about 6 tokens a tool) |
| The date tool went unused in `web02` | the tool's description: when to call it |
| A weather answer said "tomorrow, Sunday, November 22" with the date given | the weather block: label Today and Tomorrow |
| The planner wrote a French query for an English message and planned a store's closing time without "near me" | `queryPrompt`, and the message's language detected in code |
| The app puts the image after the text; Google's card puts it before | `ChatEngine.runSend`, tested on its own |
| Thoughts are removed before a tool's response, against Google's rule to keep them within a tool-calling turn | the runtime, tested on its own |
