# Roadmap

Engineering Agello into the definitive local AI assistant and multi-step agent for **iPhone 17 Pro and newer** — purpose-built around **Gemma 4 E4B** and the **A19 Pro+ heterogeneous silicon architecture** (6-core Apple10+ GPU with per-core Neural Accelerators, Metal 4 / MSL 4.1, 16-core Apple Neural Engine, and 12 GB unified memory on iOS 27.0+).

Updated 2026-11-25. Technical backing: [archive/runtime-audit-2026-11-21.md](archive/runtime-audit-2026-11-21.md).

## Current status

The handoff between work sessions (injected automatically at startup by `.agents/hooks/session-start.sh`; keep `<= 3 KB`).

- **Active baseline (2026-11-25):**
  - **Runtime (`../LiteRT-LM`):** Shipped binary release `agello-one-20261124` (`c819aecb`, Build `8a7e34594612`, dual-slice `ios-arm64` + `macos-arm64`, SwiftPM checksum `336023ee…3de7c`, privacy manifest `nm -u` clean). Fork `main` & vendored `Vendor/LiteRT-LM/swift/` are at **`9c8c783d`** (`+4` post-release commits; `9f8c904e` C++/Rust template fixes queued for next binary cut).
  - **Chat model:** `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` / `gemma-4-E4B-it-agello-v2.litertlm` (`9935a811`, `3,686,465,536` B, SHA-256 `7d63a4d8…dac7e7b`: 1,536-slot rings, 128K Dual-`GATHER` RoPE, `verify_8`, 64K window) pinned in `ModelCatalog.e4b`.
  - **Embedding model:** `PowerBeef02/embeddinggemma-2-text-270m-coreai-ane` / `embeddinggemma-2-text-270m-ane.aar` (`41026d1c`, `128,245,086` B, SHA-256 `122c2d86…1b2ece`: 4-bucket INT4 Core AI ANE bundle) pinned in `ModelCatalog.embeddingGemma`.
  - **App (`iRT@b9f8e7d`):** Phases 1–6 + Audit Waves 1–2 verified on physical iPhone 17 Pro (`iPhone18,1`, A19 Pro, 12 GB, iOS 27.2.1). `agello serve` + `gbench`, `AgelloSim` Simulator bridge, and iOS Agentic Integrations **Phases A–C** (21 Swift tools, 7 Personal Tools toggles, 9 Action Cards, EventKit CRUD + `.destructive`/`.external` confirmations, `PlanConfirmationCard`, WeatherKit, AlarmKit + Live Activity, composable AppIntents + Focus Filter, Outbound Shortcuts Bridge + Recipes, Photos OCR, Folder Bookmarks, `PasteButton`, `ThermalPolicy`) verified on Mac CLI (`404/404` unit, `12/12` security `V1–V12`), `PLATFORM=mac` (`476/476` unit), and live `AgelloSim`.
  - **Completed logs:** Archived in [archive/roadmap-2026-11-phases-1-6.md](archive/roadmap-2026-11-phases-1-6.md).
- **Next milestone (Phases A–C complete & pushed; physical iPhone verification deferred while working remotely):**
  - Run physical iPhone 17 Pro hardware verification once connected locally (`scripts/device-harness.sh gate`, `security` `V1–V12`, real Shortcuts round-trip w/ `GPUGate` suspend/resume, signed WeatherKit + alerts, AlarmKit Lock Screen / Dynamic Island firing, Focus Filter transitions, PhotoKit OCR, and `MFMessageComposeViewController`/`MFMailComposeViewController`).
  - Cut the next dual-slice runtime binary (`9f8c904e..9c8c783d`) ahead of the next iPhone release pass.

---

## North Star & A19 Pro+ Silicon Architecture

Agello targets **iOS 27.0+ on 12 GB iPhones starting with iPhone 17 Pro / Pro Max and iPhone Air (A19 Pro / A20 Pro+)** — zero legacy OS shims, zero 8 GB compromises, zero cloud dependencies. Every workload is assigned to the A19 Pro+ compute unit engineered for its arithmetic intensity, memory access pattern, and power envelope:

```mermaid
flowchart LR
  subgraph A19Pro["A19 Pro / A20 Pro SoC (12 GB Unified Memory)"]
    subgraph GPU["6-Core Apple10+ GPU + Per-Core Neural Accelerators"]
      G1["Gemma 4 E4B Prefill<br/>MSL 4.1 TensorOps · Apple10 MPP · FlashAttention"]
      G2["Speculative Decode (50–65+ tok/s)<br/>MTP Drafter + ContextDrafts + verify / verify_8"]
      G3["Metal 4 Sparse & Ring KV<br/>64K/128K MTLBufferSparseTier1 + Zero-Blit Snapshots"]
    end

    subgraph ANE["16-Core Apple Neural Engine (CoreAI / CoreML / Speech)"]
      N1["EmbeddingGemma 2 (768-dim)<br/>Zero-GPU-Contention RAG, Memory & Web Rerank"]
      N2["Live Streaming SpeechAnalyzer<br/>Sub-100 ms Dictation & Neural Turn Endpointing"]
      N3["Multimodal Vision / Audio Encoders<br/>Concurrent ViT & Conformer Perception"]
    end

    subgraph CPU["A19 Pro P-Cores (USER_INTERACTIVE + NEON)"]
      C1["Zero-Copy NEON Sampling & 42-Table PLE Gather"]
      C2["llguidance TokTrie JSON Constraints & Swift 6.4 Agent Loop"]
    end
  end
```

| Compute Unit | Workloads Owned | Why This Unit Wins on A19 Pro+ |
| --- | --- | --- |
| **6-Core GPU + Neural Accelerators** (`Apple10`+, Metal 4, MSL 4.1 `mpp::tensor_ops`) | Gemma 4 E4B INT4/INT2 prefill & decode, 1-layer Medusa `mtp_drafter`, `verify` (4-tok) & `verify_8` (8-tok), Metal 4 sparse/ring KV caches | Asymmetric INT4/INT2 weights (`3.66 GB`), dynamic speculative verify trees, KV rewinds, and 64K sparse page mappings execute directly against unified L2/SLC + in-core matrix engines with zero cross-processor copies |
| **16-Core Neural Engine (ANE)** (`CoreAI` `.aimodel`, `CoreML` `.cpuAndNeuralEngine`, `SpeechAnalyzer`, `Vision`) | `EmbeddingGemma 2` batch/query vectors, live `SpeechAnalyzer` dictation & endpointing, OCR, and evaluated ViT/Conformer encoder offload | Fixed-shape dense encoders run on ANE at a fraction of GPU wattage without evicting E4B Metal residency sets, blocking the GPU command queue, or heating the phone before decode |
| **P-Cores + ARM NEON** (`QOS_CLASS_USER_INTERACTIVE`) | `LiteRTChatEngine` actor orchestration, `llguidance` `TokTrie` grammar masks, 42-table INT4 PLE row gathers, zero-copy `LocksInPlace` reads | Sub-millisecond control-plane latency (`~1.6 ms` host overhead/round) over unified memory without extra `MTLCommandBuffer` round-trips |

---

## Tracked Work-Item Ledger

Every roadmap deliverable has a stable ID checked off with its commit SHA once verified against its gate. Detailed narrative logs for Phases 1–6, Audit Waves 1–2, and Phases A–C live in [archive/roadmap-2026-11-phases-1-6.md](archive/roadmap-2026-11-phases-1-6.md).

| Done | ID | Pri | Repo | Work Item | Primary Verification Gate | Commit |
| :---: | :---: | :---: | :---: | --- | --- | :---: |
| [x] | **P1.1** | P0 | `iRT` + `LiteRT-LM` | Background GPU drain (`beginBackgroundTask` + `wait_until_done`), `nonisolated` `BackgroundWork`, `keep && GPUGate.isOpen`, inter-tool cancel | `cli-test.sh unit` + `PLATFORM=mac unit` + iPhone `ui` (26/26, incl. backgrounding) | `LiteRT-LM@517ab613` + `iRT@f05184e` |
| [x] | **P1.2** | P0 | `LiteRT-LM` | Zero-copy NEON `GreedyHalf` + direct `DSHWBC4` `GreedyHalfDSHWBC4`, `ContextDrafts` bandit reset, `<= size` fix, `telemetry.py` `max_us` | `bazelisk test` + `cli-bench.sh` + iPhone `phone-bench.sh` (`0` host copies) | `LiteRT-LM@73000de4` |
| [x] | **P1.3** | P1 | `LiteRT-LM` | Shader compile dedup (~6,910 → ~250) + `MTLBinaryArchive`, `MTLComputePipelineDescriptor` hints, 16 KB `CacheBuilder`, RAII encoder, `gpu_info.cc` | `MTL_DEBUG_LAYER=1` + 4 C++ tests + iPhone `phone-bench.sh`, `files`, `inference` | `LiteRT-LM@e99882fb` |
| [x] | **P2.1** | P1 | `LiteRT-LM` | `FullyConnected` `simd_sum` + `GetLocalBatchSize` fix on `verify`/`verify_8`, fused `RMSNorm + gamma` (−302 ops), `MTLResourceUsageRead`, `{32,1,1}` 1D WG, thread-local GPU wait deferral | 6 C++ tests + `MTL_DEBUG_LAYER=1` + iPhone `phone-bench.sh`, `files`, `inference` | `LiteRT-LM@834e0dba` + `17a935c8` |
| [x] | **P2.2** | P1 | `LiteRT-LM` | `ConvAppleMPP` built-in INT8→FP16 dequant (`c_tile.store` + linear walk tuned on A19 Pro), PV 12 KiB `STRIP_M=32` epilogue, window QK skip, parallel 256-thread `MaskBoundsOp` | 6 C++ tests + `MTL_DEBUG_LAYER=1` + iPhone 7-point ablation & `phone-bench.sh` (`+9.2%` `file-report` prefill) | `LiteRT-LM@05505e7f` + `17f74284` |
| [x] | **P2.3** | P2 | `LiteRT-LM` | MSL 4.1 (`ios(27.0)`), bitwise SWAR `WeightsConverter` + `int2b_format`/`int4b_format` TensorOps, cooperative-tensor `agello_flash_attention` (`D=256/512`) | 6 C++ tests + `MTL_DEBUG_LAYER=1` + iPhone `phone-bench.sh` (`−35.6 ms` even at 542 tok), `inference`, `files`, `memory` | `LiteRT-LM@e206f964` |
| [x] | **P3.1** | P1 | `LiteRT-LM` | Surgical model v2: unshifted Dual-`GATHER` 128K RoPE (`<0.001 rad`) + `ring_kv` + `verify_8` + `build_v2.sh` (published at `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope@9935a811`) | iPhone 17 Pro 64K `test28_WindowPositions` 12/12 exact (`3.18 GB`) + `test27_NeedleTable` 90/90 (`3.45 GB`) | `LiteRT-LM@bf9b55cc` |
| [x] | **P3.2** | P1 | `LiteRT-LM` | FP32 `AddValuesToCacheKernel` quantization math, padded-row `Softmax`/`Softmax1x1` guard, FP32 `ConvAppleMPP` PV `c_tile` accumulation | `MTL_DEBUG_LAYER=1` 0 warnings + 6 C++ tests + iPhone 64K `test28_WindowPositions` | `LiteRT-LM@b69748ce` |
| [x] | **P3.3** | P1 | `LiteRT-LM` + `iRT` | Delegate `verify_8` before `verify`/decode (100% shared pool), `TrimKvMapping` on reset/rewind, Metal 4 `copyBufferMappingsFromBuffer:` zero-blit helper snapshots, `DeviceProfile`/`ContextBudget` (~56–60K) + evicted-turn recall | 6 C++ + 317 CLI + 384 `PLATFORM=mac` unit + iPhone `memory` (4/4, 0 warnings), `files` (5/5), `ui` (26/26), `probes` 64K | `LiteRT-LM@2ef011cd` + `iRT@6943479` |
| [x] | **P4.1** | P1 | `iRT` | `EmbeddingGemma 2` (768-dim) on A19 Pro 16-core ANE (`CoreAI` 4-bucket INT4 `.aimodel` + `continued-processing.inference`) | Cosine `0.99923` min vs FP32 + iPhone `files` (5/5: **`0.86 s`** 40-p PDF, `7.7–9.2 ms` search, `45.9 ms` concurrent w/ GPU stream) | `iRT@5c89b0c` |
| [x] | **P4.2** | P1 | `LiteRT-LM` + `iRT` | Vision GPU (`ConvAppleMPP` INT8/FP16 + `VisionAdapter` + `OneHot`), lazy Audio + `USER_INTERACTIVE` QoS, image-before-text, ANE ViT/Conformer eval | iPhone multimodal `inference` (6/6: `0.90 s` warm GPU ViT init, `3.2–4.3 ms` warm Conformer reload, `0.89–0.90 s` voice) + `memory` (4/4, 0 warnings) | `LiteRT-LM@9d2e15ab` + `iRT@8382f04` |
| [x] | **P4.3** | P2 | `iRT` | iOS 27 `SpeechAnalyzer` ANE live streaming dictation + hybrid `NeuralTurnDetector` in `VoiceSession` | Live probe `30.8–33.7 ms` partials + `333` CLI / `400` Mac unit + iPhone `ui` (3/3) & `inference` `13`/`14` (AirPods manual check queued) | `iRT@e9f6c74` |
| [x] | **P5.1** | P1 | `LiteRT-LM` + `iRT` | `llguidance` `0x20`/`0xFF` `TokTrie` fix, default `AGELLO_JSON_MTP`, `SuppressTokensConstraint` inside Think, tool-turn `<thought>` continuity, required `@ToolParam`, recursive-descent FC parser (`8f9e7142`), `AppState.afterHelper` KV-bleed fix | 11 Bazel + 362 CLI unit + iPhone `inference` (6/6, incl. `test05b`, `test16`, `test17`), `thinking` (3/3), `web` (21/21 + 13/13) | `LiteRT-LM@7d80c7ec` + `8f9e7142`, `iRT@a96bd87` + `33db05e` |
| [x] | **P5.2** | P1 | `LiteRT-LM` + `iRT` | Autonomous workspace tools (`search_files`, `read_document_pages`, `search_past_chats`, `query_table_or_json`, `convert_units`) + parallel read-only dispatch + 13-language `LanguageSupport` | 362 CLI / 429 Mac iOS unit + iPhone `files` (8/8: `test05`, `test06` parallel `3.43 s`, `test07` multilingual 4/4 `13.02 s`) | `LiteRT-LM@7d80c7ec`, `iRT@a6d46d9` + `6864e2b` |
| [x] | **P5.3** | P1 | `iRT` | Opt-in `EventKit`/`Contacts`/`MapKit` tools + deterministic pre-execution confirmation cards + 100%-gated prompt-injection suite | 362 CLI / 429 Mac iOS unit + iPhone `security` (**100% pass**, `30.2 s`, `0/5` indirect attacks, deterministic deny/approve gate) | `iRT@fc3d375` |
| [x] | **P6.1** | P2 | `iRT` | `AppEntity`/`IndexedEntity` Siri/Shortcuts/Spotlight, multimodal Action Button/Control Center, research Live Activities, isolated `ComposerView` | iPhone `unit` (439/439) + `ui` (26/26, incl. `agello://voice-camera`, `testStreamingNeverJumps`, `testBackgroundDuringGeneration`, a11y audit) | `iRT@363b7cc` |
| [x] | **P6.2** | P2 | `iRT` | `phone-bench.sh` alternating thermal rest rules + iOS 27 `MetricKit` `.memoryException` & `ledger_phys_footprint_peak`/GPU/ANE telemetry | iPhone `phone-bench.sh release again=release` (**24/24 nominal**, **95.8% clean**, `0.5%` decode / `1.1%` prefill noise band, `0.14 GB` live ANE ledger) | `iRT@7076eef` |
| [x] | **A1** | P0 | `iRT` | Audit Wave 1: background GPU & SwiftData safety, SSRF/Billion-Laughs/`wrapFitted`/request-ID confirmation gate, Voice iOS 27 `AVFAudio`, iOS 27 `MetricKit` cleanup, `#if DEBUG` gates, `AgelloShare` privacy manifest, HF `41026d1c` `LICENSE`/`NOTICE`, `CoreAIEmbedder` stale-cache self-recovery | Mac + physical iPhone 17 Pro `unit` (456/456), `inference` (25/25), `files` (8/8), `thinking` (3/3), `security` (100%), `web` (9/9), `memory` (4/4) all PASS | `iRT@7ab1a63` |
| [x] | **A2** | P0 | `LiteRT-LM` + `iRT` | Audit Wave 2: Metal 4 / MSL 4.1 kernel & residency fixes, `SparseKvMapper`/`MetalResidentRound`/executor concurrency, UTF-8 FFI & constraint guards, model-surgery fixes, Swift wrapper & `followUpThinkingBudget` | Mac workbench + physical iPhone 17 Pro 100% PASS (`unit` 456/456, `probes` + 200-turn soak `+4.95 MB`, `inference` 25/25, `files` 8/8, `thinking` 3/3, `security` 100%, `web` 9/9, `memory` 4/4, `gate-device` 14/14 in `139 s`, `ui` 26/26 in `855 s`), released as `agello-one-20261124` | `LiteRT-LM@c819aecb` + vendored on `iRT` |
| [x] | **SIM** | P1 | `LiteRT-LM` + `iRT` | `agello serve` OpenAI `/v1` + ANE `/v1/embeddings` loopback server, `gbench` template fixes (`9f8c904e`), pure-Swift `LiteRTLMTools` split (`f98bbd46`), and unshipped `AgelloSim` iOS Simulator bridge (`scripts/sim-launch.sh`) | `gbench --golden-only` 16/16 + `ifeval` 90% + `mrcr` 60.5K + live `AgelloSim` streaming/ANE/Maps/EventKit + `cli-test.sh unit` 384/384 | `LiteRT-LM@9f8c904e` + `f98bbd46` |
| [x] | **PA** | P1 | `LiteRT-LM` + `iRT` | iOS Agentic Phase A: fixes `B1`–`B9` (`@ToolParam(allowedValues:)`, scalar coercion, `−432 tok` tool schema overhead), 6 inline `ActionCards` + `ToolCardRecorder`, public iOS handoffs (`NativeActions`), `PrepareMessageTool` + `TurnContactRoster`, `ScrollViewReader` fix | `cli-test.sh unit` 394/394 + `PLATFORM=mac unit` 466/466 + `cli-test.sh security` 0% breach + live `AgelloSim` 7/7 scenarios | `LiteRT-LM@99fc72a8` + `iRT@20e6c4a` |
| [x] | **PB** | P1 | `iRT` | iOS Agentic Phase B: EventKit CRUD (`read_calendar`, `manage_calendar_event`, `list_reminders`, `manage_reminder`) + `.destructive` confirmation tier, `WeatherKit` + `AlarmKit` Live Activity, composable `AppIntents` + `AgelloFocusFilter`, SIMD LUT ANE & `ThermalPolicy` | `cli-test.sh unit` 397/397 + `PLATFORM=mac unit` 469/469 + `cli-test.sh security` 0% breach + live `AgelloSim` CRUD/Snooze/ShortcutsLink | `iRT@6fdf12d` |
| [x] | **PC** | P1 | `LiteRT-LM` + `iRT` | iOS Agentic Phase C: Outbound Shortcuts Bridge (256-bit CSPRNG nonce + `GPUGate`-safe `enterBackground()` parking), multi-step `PlanConfirmationCard` (`BatchConfirmationPlanner` + `BatchConfirmHandler` + `skipped_by_user` parity) & `TurnSecurityContext` taint, Recipes, Photos Vision OCR, Folder Bookmarks, `PasteButton`, 3-tier `ToolBudget.plan` (5 calls at `>= 32K`) | `cli-test.sh unit` 404/404 + `PLATFORM=mac unit` 476/476 + `cli-test.sh security` **12/12 (`V1–V12`)** + live `AgelloSim` batch/Shortcuts/recipe/OCR verification (physical iPhone gate queued) | `LiteRT-LM@9c8c783d` + `iRT@b9f8e7d` |

---

## Hardware Targets & Verification Gates

Every phase is measured on **iPhone 17 Pro (A19 Pro, 12 GB, Release/Bench configuration, nominal thermal start)** against explicit engineering targets:

| Metric | Baseline (`agello-one-20261115`) | Measured (`agello-one-20261124` + v2 64K) | Target | Gate Suite / Tool |
| --- | --- | --- | --- | --- |
| **Time to First Token (short chat)** | `~0.68 s` (`email` cool) | **`0.64–0.85 s`** (`email` 1,278 tok at 64K; `typo-fix 0.65 s`) | **`<= 0.85 s`** (achieved) | `bench-direct.sh` / `phone-bench.sh` |
| **Prefill Throughput (`file-report` 6.2K)** | `1,321 tok/s` (`3.94 s` TTFT) | **`1,654 tok/s`** median / **`1,668 tok/s`** peak (`3.80 s` TTFT, 6,249 tok at 64K) | **`>= 1,600+ tok/s`** (achieved) | `phone-bench.sh` (`file-report`) |
| **Sustained Decode (chat / Think)** | `53.1 / 46.7 tok/s` (60% clean) | **`57.3–57.8 / 50.6–51.9 tok/s`** (**95.8%** clean, `0.5%` noise band, `0` host copies) | **`53–60 / 44–50+ tok/s`** (achieved) | `phone-bench.sh` + `bench` |
| **Copy / Rewrite Decode (`typo-fix`)** | `81.1 tok/s` (`verify_4`) | **`83.4–84.3 tok/s`** (v1); **`195.3 tok/s`** on M6 w/ v2 `verify_8` | **`85–130+ tok/s`** (v2 `verify_8`) | `phone-bench.sh` (code/doc edit) |
| **Model Load (warm)** | `~1.2–3 s` | **`~0.70 s`** (`engine.init` warm on iPhone w/ `MTLBinaryArchive`) | **`<= 0.7 s` warm** (achieved) | `phone-bench.sh` + `telemetry.py` |
| **40-Page PDF Index (768-dim)** | `1.9 s` on GPU (blocks E4B) | **`0.86 s` on A19 Pro ANE** (`7.7–9.2 ms` search, `45.9 ms` concurrent w/ GPU stream, `0.14 GB` ANE ledger) | **`<= 1.2 s` on ANE (0% GPU block, achieved)** | `files` suite |
| **64K Window Peak Footprint** | `2.49 GB` (lab 45K) | **`3.18 GB`** at full **65,536** (`3.26 GB` free); **`3.45 GB`** at 59K+`verify_8` (`1.53–1.70 GB` kernel peak in normal/file chats) | **`<= 3.5 GB`** at full 64K (achieved) | `memory` + `WindowQualityProbes` |
| **128K RoPE Max Phase Error (`0..131,071`)** | `0.239 rad` (old `window_128k.py`) | **`< 0.001 rad`** (Dual-`GATHER`, **12/12 exact to 65,534**, **90/90** needles) | **`< 0.001 rad`** (achieved) | `probes` (exact digit copy to 64K+) |
| **Background GPU / Adversarial Tool Kills** | Unprotected race paths | **`0` background GPU kills** (`ui` 26/26 + live call test); **`100%` injection block** across **12 vectors (`V1–V12`)** on real E4B (`V1–V6` verified on iPhone `security`; `V1–V12` queued for next iPhone pass) | **`0` kills / `100%` injection block (achieved)** | `ui` + `security` (`V1–V12`) |

### Manual checks

Physical-device checks queued for the next interactive iPhone session:
- AirPods routing in hands-free voice mode, barge-in, and ANE streaming dictation;
- Incoming phone call interruption and recovery during voice mode;
- Voice mode live camera in portrait and landscape;
- Cellular model download confirmation, pause/resume staging, and SHA-256 verification;
- Backgrounding mid-prefill, mid-MTP-decode, mid-helper, and during a `BGContinuedProcessingTask` Live Activity cancellation (verifying zero `gpus_ReturnNotPermittedKillClient` or XPC isolation traps);
- Phases A–C real-hardware flows: Apple Shortcuts `x-callback-url` round-trip with `GPUGate` suspend/resume, signed `WeatherKit` forecasts + weather alerts, `AlarmKit` Lock Screen / Dynamic Island firing & Pause/Resume/Cancel, `AgelloFocusFilter` transitions, `PhotoKit` real-library Vision OCR (including `.limited` access), and native `MFMessageComposeViewController`/`MFMailComposeViewController` compose sheets.
