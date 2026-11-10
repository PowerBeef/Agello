# The Mac command line

A plan, approved by the maintainer on 2026-11-10. C1 is built (below); C2 to C8 aren't.

`agello` runs Agello's engine on a Mac from a command line: the app's own code, on the runtime
build of your choice, with the runtime's telemetry and the app's trace of every reply. It's a
development tool for working on our LiteRT-LM backend. It is never shipped, there is no Mac app,
and the iPhone stays where a change is confirmed: this Mac is faster, cooler and has more memory.

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
```

`agello --help` lists the options: Think and its budget, Search, the tools, the window, the
backend, speculative decoding, the sampler preset, the helpers, JSON output.

## Milestones

| | What | Done when |
| --- | --- | --- |
| **C1** | The package, the platform types, the three hooks, `env` and `ask`. | It builds, the iPhone app still builds, and a reply comes back with stats and a trace. |
| **C2** | `ask` complete (files, images, audio, follow-ups, Ctrl-C), and parity with the phone. | A bench case's `engine send` event (window, tokens after prefill, output cap, budget, tools) equals the iPhone's. |
| **C3** | `agello bench`: the iPhone bench's cases (`AgelloUITests/BenchCases.swift`), one record per reply in `agello-bench`'s format, the answer checkers shared with `scripts/bench-report.py`. | The fork's `compare.py` and `telemetry.py` read a run unchanged. |
| **C4** | Telemetry in depth: a per-token timeline from the runtime's trace joined with the app's, per-kernel shares on demand, the Mac's state in every record. | The slowdown late in a long reply ([HARNESS.md](HARNESS.md), H3) is attributed to a layer. |
| **C5** | Runs across builds: alternating runs with a noise band, a build check with every harness run so an app change that breaks the tool shows the same day. | Two copies of the shipped build compare as "no change". |
| **C6** | Accuracy: the Metal backend against the CPU backend token by token, and the checkers' pass rates over many sampled runs. | A backend change gets an accuracy verdict beside its speed. |
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
- Not done yet: a reply from the real model on this Mac, and the iPhone `unit` run with the
  hooks' test.

## What it can't tell you

- **The iPhone's speed, heat and memory limits.** A gain here is a lead; the iPhone bench
  confirms it.
- **Whether a reply is token for token what the phone gives.** Only the prompt side is checked
  for parity (C2).
- **Anything on a busy Mac, cleanly.** Runs alternate builds and report a noise band; a change
  inside it isn't a change.
- **Search providers with keys.** An unsigned command-line binary can't read the app's keychain,
  so Search uses DuckDuckGo, then Wikipedia.
