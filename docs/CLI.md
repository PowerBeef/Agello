# The Mac command line

A plan, approved by the maintainer on 2026-11-10 and corrected by them the same day ("Direction", below). C1 to C6 and C8 are built; C7, the new probes inside the runtime, is part-way: it's work in the fork.

`agello` runs Agello's engine on a Mac from a command line: the app's own code, on the runtime
build of your choice, with the runtime's telemetry and the app's trace of every reply. It's a
development tool for working on our LiteRT-LM backend. It is never shipped, there is no Mac app,
and the iPhone stays where a change is confirmed: this Mac is faster, cooler and has more memory.

## Direction

The maintainer's correction of 2026-11-10 ([BACKEND.md](BACKEND.md) has the whole of it):

- **One backend: ours, on the GPU.** The tool measures builds of our runtime against each other.
  It doesn't measure Google's runtime or the CPU backend, and neither is built or kept on this
  Mac as a reference.
- **The harness judges performance; Claude judges output quality, by reading the replies.** The
  answer checks are evidence for that reading, not the verdict.
- **The backend becomes a hard fork**, one repository of our own, and the app drops its code for
  Google's binary and for the CPU backend. `--backend` leaves the tool with it.

## Why

- **The fork's `agello-bench`** runs the runtime on a Mac against any build, but only synthetic
  prompts with greedy sampling: none of the app's prompts, budgets, tools, Search, files, helpers
  or sampler presets, and nothing scores realistic answers.
- **The iPhone bench** ([HARNESS.md](HARNESS.md)) runs the real app, but only on the phone, in
  about 20 minutes a run, on the one shipped runtime.
- **The gap** is the app's engine on a machine where a backend change can be built and measured
  in minutes.

## Shape

- **One Swift package at the repo root** (`Package.swift`) builds one command for macOS 27. Xcode
  never reads it: the iPhone app is built from `Agello.xcodeproj`, as before.
- **The app's real files, not a copy.** The target lists `Agello/AppState.swift`,
  `Agello/Inference`, `Agello/Knowledge`, `Agello/ModelHub`, `Agello/Persistence` and the few
  files of `Support/`, `System/` and `Voice/` that `AppState` uses. The interface, the theme,
  markdown rendering, intents and voice capture stay out. A new engine file in one of those
  folders joins by itself; one elsewhere breaks the build, which is the signal.
- **`AgelloCLI/`**, which no Xcode target compiles: macOS versions of the platform types the
  shared code calls (`AgelloCLI/Sources/Platform/`, the twins of `AgelloiOS/Platform/`), a
  session driver that sets up as a fresh install and sends as the chat screen does, and the
  commands.
- **The runtime is chosen at build time**, as `agello-bench` does. A local build of the fork is
  measured through the app's pipeline without vendoring it:

  ```sh
  swift build -c release --scratch-path build/cli/release      # what the app ships
  LITERTLM_PACKAGE="$PWD/../agello-arms/next/LiteRT-LM" swift build -c release --scratch-path build/cli/next
  build/cli/release/release/agello env
  ```

- **Memory decisions follow the iPhone, not this Mac.** The engine sees a simulated app limit
  (8 GiB by default, the iPhone 17 Pro's), so it takes the 32K window as on the phone, whatever
  else the Mac is running. `--memory-limit 5.0` gives the 16K step and `3.4` the 8K step. Nothing
  is enforced: the memory suite stays on the iPhone.

## What it reads and writes

| | Where | How |
| --- | --- | --- |
| Models | `~/Models/agello` (`--models`) | Read only: the store never downloads, deletes or cleans up there (`AGELLO_MODELS_DIR`) |
| Engine caches | `~/Models/agello/cache/agello-cli/<build id>/` (`--cache`) | One root per runtime build: the engine deletes other builds' folders in its root (`AGELLO_ENGINE_CACHE_DIR`) |
| Reply traces | `build/cli/traces/` (`--trace-dir`) | One file per reply, the iPhone bench's format, never pruned (`AGELLO_TRACE_DIR`) |
| Chats | Memory | Each run starts as a fresh install and keeps nothing |
| Settings | The tool's own defaults | The app's settings on this Mac or the phone are never read |

The three variables are hooks in shared code (`ModelStore`, `EngineCache`, `ReplyTrace`). They
do nothing unless set, and the app never sets them (`DevelopmentHooksTests`).

## Commands

```sh
agello env                         # this Mac, the runtime build, the models and folders in use
agello ask "prompt" [options]      # one message through the app's engine; the reply on stdout
agello ask --mock "prompt"         # the scripted engine: no model, no GPU
agello bench --only todo,email --repeat 3 --warmup --label release --out build/cli/runs/release.jsonl
scripts/cli-report.py build/cli/runs/release.jsonl      # the answer checks, after the measuring
```

`agello --help` lists the options: Think and its budget, Search, files, an image, a voice
message, follow-ups, the tools, the window, the backend, speculative decoding, the sampler preset,
the helpers, JSON output. Ctrl-C stops a reply as the Stop button does. The runtime's log lines
go to `runtime.log` beside the traces unless `--verbose` is given.

`agello bench` runs the iPhone bench's cases (`AgelloUITests/BenchCases.swift`, compiled into
the tool) with one engine load, a new chat per case, and Think set per case as the phone's driver
sets it. Each reply is one line of JSON in `--out`, with `agello-bench`'s keys plus the app's:
the settings in effect, why the reply ended, the reasoning, what reached the engine
(`engineSend`), the engine's telemetry for that turn alone, the Mac's state before and after,
and the path of the app's trace (`FILE.traces/`). The fork's scripts read it as they read
`agello-bench`'s:

```sh
python3 ../LiteRT-LM/tools/agello-bench/compare.py build/cli/runs/*.jsonl --base release
python3 ../LiteRT-LM/tools/agello-bench/telemetry.py build/cli/runs/release.jsonl --case explain
```

## Comparing two builds of the runtime

```sh
scripts/cli-bench.sh release next -- --only todo,explain,ttl-cache    # what ships against the fork's local build
ROUNDS=5 scripts/cli-bench.sh release again=release -- --only explain # one build against itself: the noise
```

`scripts/cli-bench.sh` builds every arm first, then runs `agello bench` once per arm and round
with the arms taking turns (one process each, so drift and heat land on all alike), then writes
the comparison (`compare.py`: medians, a 95 % interval for each change, the base arm's own noise
band) and the answer checks (`cli-report.py`). A change inside the noise band isn't a change.

- It takes the harness lock, so it and an iPhone run never measure or build at the same time.
- Before each process it waits for the GPU to be free (`QUIET_WAIT`, 60 s); a run that starts
  anyway says so in its records.
- Every record carries the Mac's state before and after its turn (load, what other processes
  used of the CPU, GPU utilization, swap, thermal state, memory-pressure events) and a `suspect`
  list when one of them makes the number doubtful.
- A real-model run is a Mac run: ask the maintainer first.

## Output quality

```sh
OUT=build/cli/runs/kernel scripts/cli-bench.sh release next -- --only email,explain   # compare.txt counts the identical replies
scripts/cli-replies.py build/cli/runs/kernel/release.jsonl build/cli/runs/kernel/next.jsonl   # where the others part

agello bench --only email,todo --samples 10 --label next --out build/cli/runs/quality.jsonl
scripts/cli-report.py build/cli/runs/quality.jsonl
```

- **Quality is judged by reading.** Claude reads the replies and gives the verdict: the same,
  better or worse. Nothing is compared with the CPU backend or with Google's runtime.
- **Identical replies need no judging.** With the shipping settings a reply is decoded greedily,
  so two builds whose arithmetic agrees give the same tokens, and the comparison counts them.
- **Where they part.** When a change moves the arithmetic (a kernel, a precision, a fused
  operation), two replies start alike and part at the first token where two candidates swap
  rank. `cli-replies.py` reports the tokens shared from the start, whether the replies part in
  the reasoning or the answer, and the text on each side: that's what gets read. A split at a
  near tie between two fair continuations is ordinary; a split early in every reply, or on a
  digit or a name, is what #3913 looked like. Records carry each reply's tokens
  (`outputTokenIDs`, `thoughtTokenIDs`: the text re-encoded by the model's tokenizer).
- **The answer checks over many sampled runs.** `--samples N` answers each case's first message
  N more times as Regenerate does (sampled with the preset, no speculative decoding), with seeds
  `--seed`+1 and up, so a run repeats exactly. `cli-report.py` gives each check's pass rate with
  its 95 % range, per build. They're evidence for the reading (does the code run, did the reply
  end by itself), not the verdict.
- Search cases vary with the live web: keep them out of comparisons between builds.

## The tests, natively

```sh
scripts/cli-test.sh unit                         # 269 unit tests on the scripted engine, about a minute
scripts/cli-test.sh unit AppStateTests           # one class, or Class/method
scripts/cli-test.sh inference                    # the real-model scenarios on this Mac's GPU (also files, web, thinking, probes, calibrate)
```

The package has two test targets on the same folders the iPhone's test targets compile,
`AgelloTests` and `AgelloDeviceTests`, importing the command line's module. `scripts/cli-test.sh`
builds them and runs them with the home folder redirected to `build/cli/test-home`, so a test
never reads or writes this Mac's own Library, Documents or settings; the real-model suites read
the models from `~/Models/agello` and take the harness lock. Left out: the tests of the
interface (markdown rendering, the shell, message actions, voice capture, intents), the
background-task tests and the memory envelopes, which need the iPhone.

## Reading where the time went

```sh
scripts/cli-timeline.py build/cli/runs/release.jsonl --case ttl-cache          # a reply cut in thirds
scripts/cli-timeline.py build/cli/runs/release.jsonl --case ttl-cache --rows   # second by second
agello bench --only email --telemetry 4 --out build/cli/runs/kernels.jsonl     # then telemetry.py --kernels 12
agello bench --only email --telemetry 3 --out build/cli/runs/trace.jsonl       # an event trace per reply
```

- **The engine timeline** is in every bench record: the runtime's totals sampled once a second
  while the reply is written. `cli-timeline.py` cuts the decoding in parts by tokens and gives,
  for each, what a decode step produced (tokens per step, drafts MTP kept) and what it cost
  (the step, the GPU's verify and drafter runs, waiting on the GPU, host work). A reply slows
  either because steps yield less or because they cost more: the two columns say which.
- **Level 4** times each GPU kernel in its own encoder. It halves the speed, so it's a pass of
  its own, read for shares (`telemetry.py --kernels`).
- **Level 3** writes the runtime's events as a Chrome/Perfetto trace beside the app's trace
  (`*.engine.json`). The runtime keeps the last 65,536 events per thread, about three seconds of
  decoding: enough for a short reply or the end of a long one. C7 lifts that.

## Milestones

| | What | Done when |
| --- | --- | --- |
| **C1** | The package, the platform types, the three hooks, `env` and `ask`. | It builds, the iPhone app still builds, and a reply comes back with stats and a trace. |
| **C2** | `ask` complete (files, images, audio, follow-ups, Ctrl-C), and parity with the phone. | A bench case's `engine send` event (window, tokens after prefill, output cap, budget, tools) equals the iPhone's. |
| **C3** | `agello bench`: the iPhone bench's cases (`AgelloUITests/BenchCases.swift`), one record per reply in `agello-bench`'s format, the answer checkers shared with `scripts/bench-report.py`. | The fork's `compare.py` and `telemetry.py` read a run unchanged. |
| **C4** | Telemetry in depth: a per-token timeline from the runtime's trace joined with the app's, per-kernel shares on demand, the Mac's state in every record. | The slowdown late in a long reply ([HARNESS.md](HARNESS.md), H3) is attributed to a layer. |
| **C5** | Runs across builds: alternating runs with a noise band, a build check with every harness run so an app change that breaks the tool shows the same day. | Two copies of the shipped build compare as "no change". |
| **C6** | Output quality: where two builds' replies part, and the checkers' pass rates over many sampled runs, for the reading that gives the verdict. (As first built: the GPU against the CPU backend token by token, dropped by the correction.) | A backend change gets a quality verdict beside its speed. |
| **C7** | New probes inside the runtime, in the fork: shader compile time, memory by buffer type, KV copy bytes, the sampled token on each step, GPU time without gaps, per-step logits on demand. | The new data shows in a run, with replies and speeds unchanged at the everyday levels. |
| **C8** | The test suites natively: `swift test` for the unit tests that need no interface, then the real-model scenarios. | They run on this Mac without the phone or Xcode's test host. |

### C1, built on 2026-11-10

- The package built on the first try, in about 15 s for a release build: the app's 41 engine
  files compile for macOS as they are, SwiftData's macros included.
- `agello env` reports the shipped build (`99b8f5f6ea49`), both models ready in
  `~/Models/agello`, and the 8 GiB simulated limit.
- `agello ask --mock` answers through the whole pipeline (settings, the chat store in memory,
  `AppState.send`, the trace) with the window at 32,000.
- The iPhone app compiles with the hooks; `swiftlint` has no error.
- The real model answers: a 10 s load with a cold cache, 1.2 s warm, the 32K window, on the GPU.
- Not done yet: the iPhone `unit` run with the hooks' test.

### C2 and C3, built on 2026-11-10

- **Parity with the phone.** Six bench cases without Search (seven turns) reach the engine
  exactly as on the iPhone 17 Pro: the same window (32,000), tokens after prefill (276 for
  `todo`, 1,026 for the three-part prompt, 4,879 and 9,698 for the file and its follow-up),
  output caps, reasoning budgets and tool calls, compared with the phone's traces of the same
  day. The prompt, the budgets and the tools are the app's.
- **Replies are not the phone's token for token.** `explain` is 1,503 tokens here and 1,666 on
  the phone, `email` 159 and 197; the file case's two replies have the phone's exact lengths
  (172 and 49). Different GPUs, different greedy paths: speed and quality work happens here,
  and the phone confirms.
- **Speed on this Mac** (M6, release build, 32K window, Think on): `explain` decodes at
  89.8 tok/s, and at 89.7 on the second pass; the first token comes after 0.28 s, and after 2.0 s
  with a 4,879-token file to read (2,514 tok/s prefill).
- **The fork's scripts read the records unchanged:** `compare.py` gives medians and intervals
  per case, `telemetry.py` the per-token breakdown (on `explain`: 11.1 ms a step, 86 % of it the
  GPU's MTP verify run, the GPU busy 94 % of the decode time).
- **The answer checks are shared.** They moved from `scripts/bench-report.py` to
  `scripts/bench/checks.py`; the phone's report gives the same verdicts as before on its last
  run, and `scripts/cli-report.py` applies them to the command line's records, with pass rates
  over repeated runs.
- The sample report of the file case moved from the chat screen to
  `Agello/Knowledge/SampleDocuments.swift`, which both benches use.

### C4 and C5, built on 2026-11-10

- **A long reply doesn't slow down on this Mac.** The three-part coding prompt (3,992 tokens
  here) decodes at 100, 113 and 116 tok/s by thirds. A decode step costs the same throughout
  (27.5, 26.9, 26.9 ms; the GPU's verify run 22.7 to 23.0 ms), and speed follows the drafts MTP
  keeps (58 %, 68 %, 71 %). `todo` (3,853 tokens) shows the same. So the 20 % slowdown seen in
  the last third on the iPhone ([HARNESS.md](HARNESS.md), H3) isn't a cost that grows with the
  position in our runtime's algorithm, at least on this GPU; on the phone the step itself got
  slower, which points at heat. Still to confirm on the iPhone.
- **Per-kernel shares** (level 4, `email`): a decode run is 72 % `fc1x1_int4_weights`, a prefill
  run 43 % the int8 convolution and 28 % `weights_convert_uint4_to_int8`, the conversion the
  fork's T4 notes already name as the next thing to hoist.
- **The event trace wraps**, as expected: 107 of 646 decode steps of a 1,503-token reply were
  left in it. The once-a-second timeline doesn't have that limit.
- **A busy Mac shows.** During these runs the GPU read 75 to 86 % busy from other work, and the
  records were flagged ("the GPU was 75 % busy before the case").
- **The build check** (`scripts/cli-check.sh`) runs at the end of every harness run and prints
  one line; broken on purpose, it quotes the compiler's error.

### C6, built on 2026-11-10

- **CPU against GPU, one case, before the correction** (`email`): the CPU backend decodes it at
  10.7 tok/s with MTP on, the GPU at 97. The replies share their first 59 tokens (37 % of the
  shorter) and part in the answer at "…consistently, and I ▸am concerned" against "▸would
  appreciate": two fair continuations, the look of a near tie. No wider run follows: the CPU
  reference is dropped, and the script that made this table now compares two builds of ours
  (`cli-replies.py`).
- **Sampled runs repeat.** Three sampled replies to `email` (seeds 1001 to 1003: 186, 160 and
  175 tokens) came back identical in a second process; all three pass their check. Sampling
  runs at 47 tok/s here, half the greedy speed, since Regenerate turns speculative decoding off.
- `AppState.regenerate` takes an optional seed (the app passes none), and
  `LiteRTChatEngine.tokenIDs` exposes the tokenizer; both are covered by the unit tests' next
  iPhone run.

### C8, built on 2026-11-10

- **269 unit tests pass natively** in 73 s (of the iPhone's 333: the rest test the interface).
- **The `inference` suite passes natively, 23 of 23, in 105 s**: load, text, chat isolation,
  stop, tools, Think, image, audio, vision toggles, the context limit, exact token counts,
  titles, memory, dictation, voice turns, digits past 2,048 and 4,096 tokens, the benchmark.
  The other real-model suites build; they haven't been run here yet.
- The device tests' harness lost its hard dependency on UIKit (three `#if canImport(UIKit)`),
  and the web tests find their fixtures in SwiftPM's bundle when built as a package.
- The tests' home is redirected, checked: after a run, this Mac's
  `~/Library/Application Support/Models` still doesn't exist.

## What it can't tell you

- **The iPhone's speed, heat and memory limits.** A gain here is a lead; the iPhone bench
  confirms it.
- **Whether a reply is token for token what the phone gives.** Only the prompt side is checked
  for parity (C2).
- **Anything on a busy Mac, cleanly.** Runs alternate builds and report a noise band; a change
  inside it isn't a change.
- **Search providers with keys.** An unsigned command-line binary can't read the app's keychain,
  so Search uses DuckDuckGo, then Wikipedia.
