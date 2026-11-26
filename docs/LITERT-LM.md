# LiteRT-LM in Agello

Agello runs Gemma 4 E4B through our hard fork of LiteRT-LM (`PowerBeef/agello-litert-lm`, with
LiteRT and ML Drift in-tree) and runs primary `EmbeddingGemma 2` embeddings on the 16-core Apple
Neural Engine via Core AI (`CoreAIEmbedder`, with `LiteRTEmbedder` as GPU fallback). This page maps
what Agello configures on the runtime, what runtime behavior matters to the app, and where canonical
inventories and deep references live.

The deep runtime reference lives in our fork: [`docs/agello/reference/`](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/README.md) on
`main`, the one branch of `PowerBeef/agello-litert-lm`, cloned at `../LiteRT-LM/docs/agello/reference/`.
It covers LiteRT-LM, LiteRT, ML Drift and the Gemma 4 models, Apple paths in depth. Every statement
in it is a claim with sources, checked by an independent verifier, and every number to quote is a
row in [`facts.md`](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md) with its conditions and a safe wording.

## What ships

Exact binary release pins, vendored `swift/` commits, checksums, and the full Swift patch inventory
live in [Vendor/README.md](../Vendor/README.md) (single source of truth). Performance release rows
live in [BACKEND.md](BACKEND.md#the-ledger).

| Part | What | Canonical owner / reference |
| --- | --- | --- |
| Swift wrapper | Vendored in `Vendor/LiteRT-LM/swift/` byte-for-byte from `../LiteRT-LM/swift/` (tracks fork `main` ahead of binary cuts when Swift-only patches land, including the pure-Swift `LiteRTLMTools` split). | [Vendor/README.md](../Vendor/README.md#swift-patches), [patches.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/patches.md) |
| Native runtime | Checksummed dual-slice (`ios-arm64` + `macos-arm64`) `CLiteRTLM.xcframework` built from our fork (`PowerBeef/agello-litert-lm` `main`, LiteRT and ML Drift in-tree, Metal 4 / MSL 4.1). | [Vendor/README.md](../Vendor/README.md#the-runtime), [BACKEND.md](BACKEND.md), [versions.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/versions.md) |
| Our source build | The fork's one branch, `main` (`agello-one` and `agello-next` before 2026-11-15): Google's 0.19.0 nightly plus our commits, LiteRT and ML Drift in the same tree. Releases of it are what Agello vendors; `Vendor/use-local-litert.sh` swaps in a local build for test runs. | [build-and-release.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/build-and-release.md) |
| Chat model | `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` (`gemma-4-E4B-it-agello-v2.litertlm`, 1,536-slot local KV rings, 128K Dual-`GATHER` RoPE, `verify_8`), pinned in `Agello/ModelHub/ModelCatalog.swift`. | [ModelCatalog.swift](../Agello/ModelHub/ModelCatalog.swift), [models/gemma4-e4b.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/models/gemma4-e4b.md) |
| Embedding model | `PowerBeef02/embeddinggemma-2-text-270m-coreai-ane` (`embeddinggemma-2-text-270m-ane.aar`), unpacked atomically into a 4-bucket asymmetric INT4 Core AI Apple Neural Engine bundle (0% GPU contention), pinned in `Agello/ModelHub/ModelCatalog.swift`. | [ModelCatalog.swift](../Agello/ModelHub/ModelCatalog.swift), [models/embeddinggemma.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/models/embeddinggemma.md) |

> [!NOTE]
> The fork's claim-checked reference (`../LiteRT-LM/docs/agello/reference/facts.md`) was last re-pinned on 2026-11-17 against `main` `b7b856a0` (fork `4318c4a1`, `agello-one-20261115`, v1 32K; 648 claims checked). It awaits its next `repin.py` pass after the next binary cut — cross-check [Vendor/README.md](../Vendor/README.md), [BACKEND.md](BACKEND.md), [ROADMAP.md](ROADMAP.md#current-status), and `ModelCatalog.swift` for Phases 3–6, Audit Waves 1–2, and Phases A–C rather than quoting superseded v1 rows from `facts.md`. Remaining loose ends are tracked in `../LiteRT-LM/docs/agello/reference/_work/audits.md`.

## What Agello sets

All through the Swift API, in `Inference/ChatEngine.swift`, `Knowledge/LiteRTEmbedder.swift`,
`Knowledge/CoreAIEmbedder.swift`, and `ModelHub/EngineCache.swift`; the full table, with what's left
at defaults, is in
[configuration.md, "What Agello sets"](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/configuration.md#what-agello-sets).

- **Every load:** `enableBenchmark` off (reply stats come from the runtime's telemetry,
  `RuntimeTelemetry`) and `filterChannelContentFromKvCache` on; speculative decoding (MTP) from
  the plan; the language model and vision encoder on the GPU, with no CPU fallback since
  2026-11-11; the audio encoder lazily loaded on P-core XNNPACK (`USER_INTERACTIVE` QoS) when
  needed and unloaded after each clip; `maxNumTokens` from the plan; the cache folder from
  `EngineCache`.
- **Each new engine:** a one-token reply to "Hi" (`validate()`), with no sampler settings.
- **Chat:** system prompt, history, tools, sampler, thinking budget and visual token budget per
  conversation; `sendMessageStream` with an output cap from `ContextBudget`.
- **Helpers:** JSON helpers run with speculative decoding (MTP) on by default
  (`LiteRTChatEngine.jsonHelpersSpeculate`, fixed in fork `1382157b` + `7d80c7ec`; `#if DEBUG || BENCH`
  override via `AGELLO_JSON_MTP=0`) and use a JSON-schema response format; transcription samples
  greedily; the others pass no sampler.
- **Embeddings:** primarily on the **16-core Apple Neural Engine** via Core AI (`CoreAIEmbedder`,
  4-bucket `128/256/512/1024` asymmetric INT4 `EmbeddingGemma 2`, 768 dimensions, `0.99949` average
  cosine vs LiteRT true FP32, `0.86 s` for a 40-page PDF on iPhone 17 Pro with zero GPU contention).
  `LiteRTEmbedder` (GPU FP16, cosine `0.9956`, batches of 8; `EmbeddingEngineConfig.activationDataType`
  available for FP32) and BM25 keyword search serve as fallbacks.

## Words to get right

- **Context length** means four things: the *trained* context (128K for E2B and E4B), the file's
  *export window* (128K / `131,101` on the shipped v2 file `gemma-4-E4B-it-agello-v2.litertlm`;
  older v1 files exported 32K), the *allocated* context (`maxNumTokens`; the app asks for 65,536
  and the shipped v2 file allocates the full 65,536 positions on 12 GB iPhones, while older 32K
  files cap at 32,000) and the *filled* length (tokens in the cache). Say which.
  ([F-048 to F-050](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md#f-048))
- **Which runtime.** A speed or memory figure names its build (ours, with its release tag and build
  id, or a dated historical baseline) and its date.
- **GPU Neural Accelerators vs Apple Neural Engine:** ML Drift runs Gemma 4 E4B (LLM + Vision) on
  the GPU's matrix units (**GPU Neural Accelerators**) on Apple10+ GPUs, not the ANE. Agello uses
  the **16-core Apple Neural Engine** directly via Core AI (`CoreAIEmbedder` for `EmbeddingGemma 2`)
  and iOS 27 `SpeechAnalyzer` (live dictation and voice turn detection).

The rest is in [glossary.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/glossary.md).

## What the reference found that affects Agello

| Finding | Effect | Status | Reference |
| --- | --- | --- | --- |
| `enableBenchmark` makes LiteRT-LM request active (busy-wait) GPU waits, in both builds | A CPU core spins during every GPU wait; our passive-wait commit never applied in the app | with our build the app now leaves it off: 7.5–8.7 ms of CPU per decoded token on the M6, 0.7 ms without (2026-10-24) | [F-019](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md#f-019) |
| The engine's sampler takes its parameters from the first session that samples, and `validate()` samples first | The chat's temperature, top-k and top-p didn't reach plain decode steps, and Regenerate's seeds didn't vary replies | seen in probe 18 on our build; fixed in fork `f1b88286` (each session owns its sampler settings and random state) | [configuration.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/configuration.md#what-agello-sets) |
| The E4B file exports at most 280 visual tokens per image | There's no image-detail setting (since 2026-11-11): the app sends 280 per image (`VisualDetail.balanced`), the file's most | from the file and the code | [F-066](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md#f-066) |
| With tools declared, a tool-call block the parser rejects sends up to three final error chunks; the wrapper releases its stream context on each | A use-after-free in the shipped wrapper | from the code; not reproduced. Our wrapper keeps streams by ID, and our build sends one final chunk per send at the C boundary (`agello-next` `8acc748c`) | [swift-api.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/swift-api.md#error-chunks-and-the-retained-context) |
| Upstream MTP and JSON/regex constraints shared one grammar matcher across drafts, and `LlgConstraintProvider` mangled `▁` / control tokens in `TokTrie` | Constrained output broke under MTP and rejected multi-word JSON enums | fixed in fork `1382157b` + `7d80c7ec` (shipped in `agello-one-20261122-3`); `jsonHelpersSpeculate` now defaults ON and `test16_MultiWordJsonEnumWithMTP` passes | [troubleshooting.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/troubleshooting.md#json-constrained-replies-break-with-mtp-on) |
| EmbeddingGemma takes up to 1,024 tokens (`1,022` payload + BOS/EOS); model card warns against GPU FP16 | Passages plus prefixes must fit in 1,022 tokens; GPU embeddings contended with E4B | moved primary execution to the 16-core ANE via Core AI (`CoreAIEmbedder`, 4-bucket `128/256/512/1024` INT4, `0.99949` avg cosine vs FP32, `0.86 s` 40-page PDF, 0% GPU contention); LiteRT GPU FP16 (`0.9956` cosine, probe 32) stays as fallback | [F-056](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md#f-056), [F-123](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md#f-123) |
| The chat template inside the E4B file is older than Google's Hugging Face template | The file's template is what runs; don't quote the Hugging Face one as Agello's | from the file | [F-032](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md#f-032) |
| The app's memory limit on an iPhone 17 Pro is about 8.6 GB (8 GiB); 6.44 GB (6 GiB) is an early reading in some runs | Tests that read the limit at launch can size themselves to the wrong value | measured | [F-071](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/facts.md#f-071) |

## Where to look

| Topic | Page |
| --- | --- |
| One chat turn end to end: Swift, C, conversation, session, executor, GPU; threads | [stack.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/stack.md) |
| Engine, sessions, helper conversations, KV snapshots | [litert-lm/engine-and-sessions.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/engine-and-sessions.md) |
| Prefill, decode, MTP, the vision and audio executors | [litert-lm/executors.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/executors.md) |
| Conversations, channels and thinking, tool calls | [litert-lm/conversation.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/conversation.md) |
| Chat template, tokenizer, special tokens | [models/tokenizer-and-chat-format.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/models/tokenizer-and-chat-format.md) |
| Sampling, constrained decoding, stop tokens | [litert-lm/components.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/components.md) |
| The Swift API Agello calls; the C API under it | [litert-lm/swift-api.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/swift-api.md), [litert-lm/c-api.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert-lm/c-api.md) |
| Every setting: default, when it's read, effect on Apple | [configuration.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/configuration.md) |
| Memory: weights, KV sizes, caches on disk, iOS limits | [memory.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/memory.md), [apple-platform.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/apple-platform.md) |
| Errors, status codes, failure modes, Agello's rules traced to their causes | [troubleshooting.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/troubleshooting.md) |
| The GPU path: LiteRT, the ML Drift delegate, kernels, Metal | [litert/](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/litert/runtime.md), [ml-drift/](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/ml-drift/architecture.md) |
| Gemma 4 E4B, E2B, the family, EmbeddingGemma | [models/](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/models/gemma4-e4b.md) |
| What ships, what's documented, what changed between them | [versions.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/versions.md) |
| Our patches, why, evidence, upstream status | [patches.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/patches.md) |
| Upstream issues and pull requests, commit messages, user-doc checklist | [contributing.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/contributing.md) |
| agello-bench, telemetry, model inspection | [tools.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/tools.md) |
| Google's own Gemma docs ([gemma.ai](https://gemma.ai/)): model cards, prompt format, MTP, LiteRT-LM deployment, release dates; what they add and where their visual guides don't fit E2B/E4B | [models/gemma4-family.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/models/gemma4-family.md#googles-documentation-site) |

## Writing about the runtime or the models

- Quote numbers from `facts.md` (with their conditions and safe wording) only for rows still valid
  at the current pin. While `facts.md` remains pinned to `b7b856a0` (`agello-one-20261115`, v1 32K),
  cross-check [Vendor/README.md](../Vendor/README.md), [BACKEND.md](BACKEND.md),
  [ROADMAP.md](ROADMAP.md#current-status), and `ModelCatalog.swift` instead of quoting superseded
  v1 / pre-Phase-4 rows.
- Follow the checklist in [contributing.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/contributing.md) for user docs, commit messages
  and anything posted upstream: name the build and date with any speed or memory figure, and say
  whether a statement is about the trained model, the exported file or the runtime.

## Updating

1. Engine changes follow the `agello-inference-rules` skill; LiteRT-LM updates, the fork and
   upstream work follow `agello-litert-update`.
2. After changing `agello/litert` or `agello/ml_drift`, vendoring a new release, or a model update,
   re-verify the reference as
   [maintenance.md](https://github.com/PowerBeef/agello-litert-lm/blob/main/docs/agello/reference/maintenance.md) describes: move the pins in `tools/agello-docs/pins.json`,
   and `tools/agello-docs/repin.py` re-cites every citation whose lines didn't change and lists the
   claims to re-verify; they are re-verified and the pages fixed before anyone quotes them.
3. After vendoring a new release, update [Vendor/README.md](../Vendor/README.md) (sole canonical
   inventory for pins and Swift patches), [BACKEND.md](BACKEND.md#the-ledger), `NOTICE` /
   `Agello/Resources/NOTICE.txt`, and `docs/ROADMAP.md` `Current status`.
