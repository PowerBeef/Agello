# LiteRT-LM in Agello

Agello runs Gemma 4 E4B and EmbeddingGemma through Google's LiteRT-LM. This page says which
LiteRT-LM the app ships, what it sets, what the runtime does that matters to the app, and where to
read the rest.

The rest is the **LiteRT-LM reference** in our fork: [`docs/agello/reference/`](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/README.md) on
the `agello` branch of `PowerBeef/agello-litert-lm`, cloned at `../LiteRT-LM/docs/agello/reference/`.
It covers LiteRT-LM, LiteRT, ML Drift and the Gemma 4 models, Apple paths in depth. Every statement
in it is a claim with sources, checked by an independent verifier, and every number to quote is a
row in [`facts.md`](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md) with its conditions and a safe wording. It documents our source
build (`agello-next`); where the shipped runtime differs, it says so.

## What ships

| Part | What | Reference |
| --- | --- | --- |
| Swift wrapper | The fork's `agello` branch at `85b1a776`: LiteRT-LM v0.18.0 plus two patches in `swift/Conversation.swift` (a failed tool call is answered with an error the model reads; a stream holds its conversation weakly). `Vendor/LiteRT-LM` holds it byte for byte. | [F-003](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-003), [patches.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/patches.md) |
| Native runtime | Google's prebuilt, checksummed v0.18.0 `CLiteRTLM.xcframework`. None of our runtime commits (LiteRT-LM, LiteRT, ML Drift) reach users. | [F-018](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-018), [versions.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/versions.md) |
| Our source build | `agello-next`: Google's 0.19.0 nightly plus our commits, built with our LiteRT and ML Drift forks. `Vendor/use-local-litert.sh` swaps it in for test runs; it isn't shipped. | [build-and-release.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/build-and-release.md) |
| Chat model | `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` at `a1693e22` (3,660,726,272 bytes): the litert-community file with its rotary positions split into 512-token blocks, the #3913 fix. | [F-020](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-020), [models/gemma4-e4b.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/models/gemma4-e4b.md) |
| Embedding model | `litert-community/embeddinggemma-2-text-270m-litert-lm` (164,626,432 bytes), downloaded from `main`, not pinned to a revision. | [F-029](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-029), [models/embeddinggemma.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/models/embeddinggemma.md) |

## What Agello sets

All through the Swift API, in `ChatEngine.swift`, `Embedding.swift` and `EngineCache.swift`; the
full table, with what's left at defaults, is in
[configuration.md, "What Agello sets"](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/configuration.md#what-agello-sets).

- **Every load:** `enableBenchmark` and `filterChannelContentFromKvCache` on; speculative decoding
  (MTP) from the plan; GPU first, then CPU; vision and audio on the CPU when enabled; `maxNumTokens`
  from the plan; a cache folder from `EngineCache`.
- **Each new engine:** a one-token reply to "Hi" (`validate()`), with no sampler settings.
- **Chat:** system prompt, history, tools, sampler, thinking budget and visual token budget per
  conversation; `sendMessageStream` with an output cap from `ContextBudget`.
- **Helpers:** JSON helpers turn MTP off and use a JSON-schema response format; transcription
  samples greedily; the others pass no sampler.
- **Embeddings:** GPU then CPU, normalized, 256 dimensions, batches of 8.

## Words to get right

- **Context length** means four things: the *trained* context (128K for E2B and E4B), the file's
  *export window* (32K), the *allocated* context (`maxNumTokens`; a 32K setting gets 32,000
  positions) and the *filled* length (tokens in the cache). Say which.
  ([F-048 to F-050](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-048))
- **Which runtime.** A speed or memory figure names its build (Google's v0.18.0 binary or ours, with
  its build id) and its date.
- **GPU Neural Accelerators**, not "Neural Engine": ML Drift reaches the GPU's matrix units on
  Apple10 GPUs; this stack doesn't use the Neural Engine.

The rest is in [glossary.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/glossary.md).

## What the reference found that affects Agello

| Finding | Effect | Status | Reference |
| --- | --- | --- | --- |
| `enableBenchmark` makes LiteRT-LM request active (busy-wait) GPU waits, in both builds | A CPU core spins during every GPU wait; our passive-wait commit never applies in the app | from the code | [F-019](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-019) |
| The engine's sampler takes its parameters from the first session that samples, and `validate()` samples first | The chat's temperature, top-k and top-p may not reach plain decode steps | from the code; no run has checked it | [configuration.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/configuration.md#what-agello-sets) |
| The E4B file exports at most 280 visual tokens per image | "Detailed (560)" sends 280, like "Balanced" | from the file and the code | [F-066](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-066) |
| With tools declared, a tool-call block the parser rejects sends two final error chunks; the wrapper releases its stream context on each | A use-after-free in the shipped wrapper | from the code; not reproduced | [swift-api.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/swift-api.md#error-chunks-and-the-retained-context) |
| MTP and a JSON or regex constraint share one grammar matcher across drafts | Constrained output can break the schema, in Google's binary and ours; JSON helpers keep MTP off | from the code, matches what Agello saw on device | [troubleshooting.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/troubleshooting.md#json-constrained-replies-break-with-mtp-on) |
| EmbeddingGemma loads up to 1,024 tokens by default and runs at FP16 on the GPU | A passage plus its prefix must fit in 1,022 tokens; the model card advises against float16, and no FP32 comparison exists | from the file and the code; FP16 effect open | [F-056](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-056), [F-123](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-123) |
| The chat template inside the E4B file is older than Google's Hugging Face template | The file's template is what runs; don't quote the Hugging Face one as Agello's | from the file | [F-032](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-032) |
| The app's memory limit on an iPhone 17 Pro is 8 GiB; 6 GiB is an early reading in some runs | Tests that read the limit at launch can size themselves to the wrong value | measured | [F-071](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/facts.md#f-071) |

## Where to look

| Topic | Page |
| --- | --- |
| One chat turn end to end: Swift, C, conversation, session, executor, GPU; threads | [stack.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/stack.md) |
| Engine, sessions, helper conversations, KV snapshots | [litert-lm/engine-and-sessions.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/engine-and-sessions.md) |
| Prefill, decode, MTP, the vision and audio executors | [litert-lm/executors.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/executors.md) |
| Conversations, channels and thinking, tool calls | [litert-lm/conversation.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/conversation.md) |
| Chat template, tokenizer, special tokens | [models/tokenizer-and-chat-format.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/models/tokenizer-and-chat-format.md) |
| Sampling, constrained decoding, stop tokens | [litert-lm/components.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/components.md) |
| The Swift API Agello calls; the C API under it | [litert-lm/swift-api.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/swift-api.md), [litert-lm/c-api.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert-lm/c-api.md) |
| Every setting: default, when it's read, effect on Apple | [configuration.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/configuration.md) |
| Memory: weights, KV sizes, caches on disk, iOS limits | [memory.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/memory.md), [apple-platform.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/apple-platform.md) |
| Errors, status codes, failure modes, Agello's rules traced to their causes | [troubleshooting.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/troubleshooting.md) |
| The GPU path: LiteRT, the ML Drift delegate, kernels, Metal | [litert/](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/litert/runtime.md), [ml-drift/](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/ml-drift/architecture.md) |
| Gemma 4 E4B, E2B, the family, EmbeddingGemma | [models/](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/models/gemma4-e4b.md) |
| What ships, what's documented, what changed between them | [versions.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/versions.md) |
| Our patches, why, evidence, upstream status | [patches.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/patches.md) |
| Upstream issues and pull requests, commit messages, user-doc checklist | [contributing.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/contributing.md) |
| agello-bench, telemetry, model inspection | [tools.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/tools.md) |
| Google's own Gemma docs ([gemma.ai](https://gemma.ai/)): model cards, prompt format, MTP, LiteRT-LM deployment, release dates; what they add and where their visual guides don't fit E2B/E4B | [models/gemma4-family.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/models/gemma4-family.md#googles-documentation-site) |

## Writing about the runtime or the models

- Quote numbers from `facts.md`, with their conditions and its safe wording.
- Follow the checklist in [contributing.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/contributing.md) for user docs, commit messages
  and anything posted upstream: name the build and date with any speed or memory figure, and say
  whether a statement is about the trained model, the exported file or the runtime.

## Updating

1. Engine changes follow the `agello-inference-rules` skill; LiteRT-LM updates, the fork and
   upstream work follow `agello-litert-update`.
2. After a re-pin, a rebase or a model update, re-verify the reference as
   [maintenance.md](https://github.com/PowerBeef/agello-litert-lm/blob/agello/docs/agello/reference/maintenance.md) describes: `tools/agello-docs/check_refs.py --repin` lists
   the claims whose cited code moved; they are re-verified and the pages fixed before anyone quotes
   them.
3. When Agello ships our build, update this page's "What ships" table, the README's performance
   table (from a fresh calibration with its build id) and `CLAUDE.md`.
