# Custom LiteRT-LM Runtime & Apple Silicon Audit (2026-11-21)

Code-level architecture, performance, numerical accuracy, and iOS 27 / A19 Pro+ hardware audit across `../LiteRT-LM` (`main` @ `4318c4a1`, shipping release `agello-one-20261115`) and `iRT` (`main` @ `4d2363a`), cross-checked against Xcode's iOS 27.2 SDK headers (`Metal`, `MetalPerformancePrimitives`, `BackgroundTasks`), WWDC26 Session 330 (*Optimize custom machine learning operations with Metal tensors*), Apple Tech Talk 111432 (*Accelerate your machine learning workloads with the M5 and A19 GPUs*), `llguidance`'s `TokTrie` specification, and saved iPhone 17 Pro / Mac M6 telemetry runs.

This audit underpins the 6-phase A19 Pro+ engineering plan in [ROADMAP.md](ROADMAP.md).

---

## Executive Scorecard

| Subsystem | Grade | Strong Today | Primary Findings & Headroom |
| --- | :---: | --- | --- |
| **Apple10/11 MPP Prefill (`ConvAppleMPP`)** | **A−** | `mpp::tensor_ops::matmul2d` (`int8 × int8 -> int32`, `half × half -> half`), `M<=128` in-place INT4 (`80c07920`), INT8 KV write (`704 -> 539 ms` / 1K tok on A19 Pro) | `tmp[128*64]` consumes **32,768 / 32,768 B (100%)** of core threadgroup RAM (**1 TG/core cap**); linear raster tile walk leaves Neural Accelerators ~50% utilized vs. **Morton Z-order** (Tech Talk 111432); prefill attention materializes 128 MB Q×K instead of **MSL 4.1 Cooperative-Tensor FlashAttention** (WWDC26-330) |
| **Speculative Decode (`LlmLiteRtMtpDrafter`)** | **A−** | 1-layer Medusa/MTP drafter (3 steps → 4-token verify, **46–60 tok/s** on iPhone 17 Pro), adaptive `ContextDrafts` + `verify_8`, `USER_INTERACTIVE` QoS | `TopPSampler` (`verifier_sampler_` & `verify8_sampler_`) runs on CPU and **`memcpy`s 3.5–4.0 MiB of logits/round** from unified-memory `MTLBuffer`s; bandit rates never reset across turns or chats |
| **ML Drift Decode Kernels (`FullyConnected`, `RMSNorm`)** | **B** | Custom `row_tile` multi-row decode (`block_spatial = 16`), T4 runtime attention window skip, E2 ring-KV bounds clamp, fused online softmax | Zero `simd_sum` (uses shared-memory barrier trees); **`GetLocalBatchSize` drops to `1` on `verify`/`verify_8` → 32–48 barriers/WG**; **302 unfused `RMSNorm + Mul` pairs** (604/1,726 ops = 35% of graph); missing `MTLComputePipelineDescriptor` hints (`requiredThreadsPerThreadgroup`, `MTLMutabilityImmutable`) |
| **Unified Memory, Weight Cache & Hub State** | **A−** | Metal 4 `MTLBufferSparseTier1` 64K KV (`cc97925b`), 128K ring KV (`8,192 B/tok + 31.5 MB`), `mmap` + `newBufferWithBytesNoCopy:`, `LocksInPlace` (`89137792`) | `CacheBuilder::kMinAlignment = 4096` (violates 16 KB `newBufferWithBytesNoCopy:` length contract); `verify` before `verify_8` duplicates **25–35 MB**; ~6,910 un-deduplicated shader compiles/load; Hub pins 32K `ONE_HOT` file (`6353a233…`) without 128K ring KV or `verify_8` |
| **Numerical Precision & RoPE (`0..131,071`)** | **A−** | Exact `INT32` `FLOOR_DIV`/`FLOOR_MOD` + FP64-precomputed `GATHER` high tables (`window_128k.py`) avoid FP16 `65,504` overflow and depth-dependent drift through 128K | Low-part `FP16(l) * FP16(f_i)` creates periodic **0.239 rad** max phase error (droppable **300×** to **< 0.00078 rad** with a 256 KiB `GATHER` table); `AddValuesToCacheKernel` uses FP16 `inverse_scale`; `llguidance` missing `0x20` decode and `0xFF` special-token marker |
| **iOS Lifecycle, Swift 6.4 & Background GPU** | **C+** | `GPUGate` atomic guard on new entrypoints; `BackgroundWork` (`BGContinuedProcessingTask` with `.gpu` and `.fail`); serialized engine actor | **`P0` `gpus_ReturnNotPermittedKillClient` + Swift 6 XPC Trap:** `enterBackground()` returns without `beginBackgroundTask` or `wait_until_done`; `BackgroundWork.expirationHandler` inherits `@MainActor` isolation on a background XPC queue; helper cancel actively blits KV on GPU in background |

---

## 1. Resolution of Two Open Performance Mysteries

### 1.1 Why `AGELLO_MTP_REPLAY=1` (`+13–17%`) Did Not Carry Over to GPU-Resident Round Stage 3 (`=1`: `−1.3%` iPhone / `+2.6%` M6)

1. **Artificial GPU overlap in Replay:** In `../LiteRT-LM/runtime/executor/llm_litert_mtp_drafter.cc:1501-1551`, `AGELLO_MTP_REPLAY=1` pre-wrote static inputs and never chained outputs (`drafter[0..2]` read static inputs and `verify` read disjoint pre-written inputs, sharing only `kv_cache_{22,23}` touched at CB #4 of 9). Metal's command queue overlapped all three drafters concurrently with `verify` layers `0..21` (`26.5 ms` summed GPU work compressed into `23.5 ms` wall time on M6; adding a single `MTLSharedEvent` barrier in `mode='e'` dropped M6 from **`+12.3%` → `+2.9%`**). Real speculative decoding has an unbreakable serial RAW chain (`draft 0 → argmax → gather → draft 1 → … → verify`) where cross-step overlap is impossible.
2. **Narrow remaining host gap (`2.53 ms/round`, 5.7%):** After `4780b5c5` (`USER_INTERACTIVE` QoS), `89137792` (`LocksInPlace`), and `6da75396` (mask skip), Release telemetry (`build/phone/runs/round1-20261117/release.jsonl`) measures `mtp.round = 44.54 ms` vs. `gpu.drafter + gpu.verify = 42.02 ms` (`2.53 ms` total non-GPU wall time on iPhone 17 Pro, `~1.13 ms` on M6).
3. **Stage 3 spent that margin on extra CBs, a 1-TG argmax, and CPU verification:** `../LiteRT-LM/runtime/executor/agello_resident_round.mm:198-238, 305-322` added 6–7 extra `MTLCommandBuffer`s/round (`18 → 24–25` CBs), launched `agello_argmax_f16` with **`MTLSizeMake(1, 1, 1)`** (1 of 6 GPU cores, scalar `half`, 10 `threadgroup_barrier`s, zero `simd_max`), and still ran `verifier_sampler_` on CPU (`2.10 MB` `memcpy`).
4. **Prefill-outlier filter artifact in `round1/load.txt`:** Rep 1 of `release` `explain` ran cold (`49.8 tok/s`, prefill `1,168 tok/s`) while reps 2–5 settled at `47.2 tok/s` (`~1,050 tok/s`). Because the 8% prefill filter dropped reps 2–5 of `release` while keeping all 5 reps of `next` (`47.4 tok/s`), `round1` reported `−4.7%` instead of `+0.8%` steady-state.

### 1.2 Why Mapping PLE Slowed Prefill (`−3.8%` iPhone / `−1.5%` M6)

Stage 3 wrapped the **836.8 MB** `tf_lite_per_layer_embedder` `mmap` in `newBufferWithBytesNoCopy:` (`MTLStorageModeShared`), wiring/faulting cold PLE pages into GPU/IOMMU page tables (+157 MB to +872 MB footprint) and adding page-fault overhead to CPU `LookupPrefill` across 42 INT4 tables. Stage 3 (`=1`) is closed; the drafter chain (`=2`) remains the default.

### 1.3 Exact Per-Round Host Breakdown (iPhone 17 Pro vs. Mac M6)

| Phase in Single 4-Token MTP Round | Code Path | iPhone 17 Pro | Mac M6 |
| --- | --- | :---: | :---: |
| Outer `Tasks` + `Executor::Decode` + 84 `TensorBuffer::Duplicate()` clones | `tasks.cc:345-441`, `state.cc:1000-1043` | `~0.18 ms` | `~0.07 ms` |
| 3 × Drafter CPU INT2 embedder + 114-op Metal encode + 3 `waitUntilCompleted` wakeups | `llm_litert_mtp_drafter.cc:747-768`, `gpu_backend_metal.mm:240-295` | `~1.03 ms` | `~0.47 ms` |
| 3 × Drafter `512 KiB` logits `memcpy` + `GreedyHalf` | `top_p_cpu_sampler.cc:218-239` | `~0.35 ms` | `~0.15 ms` |
| Verifier 42-table CPU PLE gather (`172 KiB`) + unhidden tail of 1,726-op / 9-CB encode + wakeup | `llm_litert_mtp_drafter.cc:1167-1252`, `inference_context.mm:817-850` | `~0.45 ms` | `~0.22 ms` |
| Verifier `2.00 MiB` logits `memcpy` + 4-row `GreedyHalf` | `top_p_cpu_sampler.cc:218-239` | `~0.55 ms` | `~0.22 ms` |
| **Total Non-GPU Host Time / Round** | `mtp.round - (gpu.drafter + gpu.verify)` | **`~2.56 ms`** *(measured `2.40–2.73`)* | **`~1.13 ms`** |

---

## 2. Reliability, Swift 6.4 Concurrency & iOS Lifecycle Findings

1. **Swift 6 Runtime Isolation Trap in `BackgroundWork.expirationHandler` (`AgelloiOS/System/BackgroundWork.swift:9-66`):**
   - `BackgroundWork` is `@MainActor final class`, so `task.expirationHandler = { [weak self] in … }` (`line 56`) formed inside `@MainActor func begin(...)` inherits `@MainActor` isolation in Swift 6. Because `BackgroundTasks.framework` invokes `expirationHandler` on a background XPC queue, Swift 6's `_swift_task_checkIsolatedSwift` prologue traps before `Task { @MainActor in … }` runs.
   - `expirationHandler` (`line 60`) and `AppState.stop()` → `BackgroundWork.shared.end(success: false)` (`line 109`) also call `task.setTaskCompleted(success: false)` *before* async `engine.cancel()` finishes draining GPU command buffers, revoking `.gpu` entitlement mid-dispatch.
   - `isActive` (`task != nil`, `line 31`) has a startup race between `BGTaskScheduler.shared.submit(request)` and the launch handler.
2. **Five Background GPU Kill Paths (`gpus_ReturnNotPermittedKillClient`):**
   - `AgelloiOS/App/AgelloApp.swift:50-60` ignores `.inactive`; `Agello/AppState+Reply.swift:237-267` acquires no `UIApplication.shared.beginBackgroundTask` and returns synchronously while C++ worker threads keep committing `MTLCommandBuffer`s. `litert_lm_conversation_wait_until_done` (`../LiteRT-LM/c/conversation.cc:752-764`) is unexposed in `Vendor/LiteRT-LM`.
   - `LlmLiteRtMtpDrafter::Draft` (`llm_litert_mtp_drafter.cc:1303-1577`) commits 18 CBs/round without checking `cancelled` between `drafter[0..2]` and `verify`; post-Think `<thought>` rewind (`conversation.cc:775-834`) runs `RunPrefillAsync` with a fresh `cancelled = false` atomic.
   - **Active background GPU blit triggered by helper cancel (`Agello/Inference/ChatEngine.swift:578-619`):** `endHelperAfterFailure` calls `endHelper(keep: true)` → `_ = try? conversation?.getTokenCount()` (`line 590`) without checking `GPUGate.isOpen`, committing a Metal `BlitMetalRanges` KV restore (`metal_raw_buffer.mm:74-95`) in the background — and then `line 618` sets `lastHelperKeptConversation = false`, discarding it.
   - `Agello/Knowledge/Embedding.swift:96-101` (`embed(query:)`) skips `GPUGate.isOpen` once loaded; `KnowledgeBase.releaseMemory()` can race `unload()` against `embedBatch`.
   - `Vendor/LiteRT-LM/swift/ConversationStream.swift:307-325` calls `StreamTable.shared.retire(id)` *before* awaiting async `WebSearchTool`, blinding `cancelProcess()` between tool rounds.
3. **Metal Delegate, Alignment & Tooling Bugs:**
   - **Un-ended `MTLComputeCommandEncoder` on error (`../LiteRT-LM/agello/litert/ml_drift_delegate/delegate/delegate_kernel_litert.cc:259-323`):** Mid-loop `LITERT_ASSIGN_OR_RETURN` after `PreConvert` returns without `EndComputeEncoding()`.
   - **4 KB vs. 16 KB zero-copy alignment (`cache_builder.h:45`, `shared_memory_manager_metal.h:247`, `gpu_backend_metal.mm:421`):** `kMinAlignment = 4096` leaves `raw_bytes_count` unaligned to Apple Silicon's 16 KB `vm_page_size` for `newBufferWithBytesNoCopy:` (fails `MTL_DEBUG_LAYER=1`; silently falls back to dirty heap copies if `nil`) and creates hundreds of separate `mmap` VMAs instead of slicing one file-wide `mmap`.
   - **Fork `telemetry.py` crash (`../LiteRT-LM/tools/agello-bench/telemetry.py:135`):** `v["max_us"]` raises `KeyError: 'max_us'` on `.jsonl` bench outputs (`v.get("max_us", 0.0)` fixes it).

---

## 3. Speculative Decoding & ML Drift Decode Findings

1. **Hidden `3.5–4.0 MiB/round` CPU Logits `memcpy` (`top_p_cpu_sampler.cc:218-239`, `sampler_factory.cc:757-796`):**
   - `CreateGreedySampler` falls back to CPU `TopPSampler` (`libLiteRtTopKMetalSampler` is closed-source and absent) for `drafter_sampler_`, `verifier_sampler_`, and `verify8_sampler_`.
   - `mutable_logits_tensor.Read(absl::MakeSpan(logits_f16_))` `std::memcpy`s `3.50 MiB/round` (`3 × 512 KiB + 2.0 MiB`) on `verify` and `4.00 MiB/round` on `verify_8` out of already CPU-addressable `MTLStorageModeShared` buffers before read-only `GreedyHalf`. Locking in place (`TensorBufferScopedLock` `kRead`) + ARM NEON `vmaxq_f16` (or encoding multi-TG `simd_max` argmax onto `PostConvert`'s CB) eliminates the copy with zero extra command buffers.
2. **Cross-Turn `ContextDrafts` Bandit Poisoning (`llm_litert_mtp_drafter.h:340-342`, `.cc:1371-1385`, `agello_context_drafts.cc:113`):**
   - `context_rate_`, `drafter_rate_`, and `offered_rounds_` persist across turns and chats; free-writing trigram misses (`~0.025 tok/ms`) suppress `verify_8` on 7 of 8 rounds for 60–120+ tokens of a subsequent copy/edit turn. Also `agello_context_drafts.cc:113` checks `<= size - 1` instead of `<= size`.
3. **ML Drift `FullyConnected` & `RMSNorm` Kernel Bottlenecks:**
   - **Zero `simd_sum` + 16× barrier cliff (`fully_connected_util.cc:294-345`, `fully_connected.cc:852-860`):** `verify` and `verify_8` use `block_spatial = 16`, tripping `if (block_spatial <= 8)` → `local_batch_size = 1` → **32–48 sequential `threadgroup_barrier`s per threadgroup**. Replacing shared-memory trees with `simd_sum` (+ at most 1 cross-SIMD pass) drops this to 0–1 barrier.
   - **302 Unfused `RMSNorm + Mul` Pairs (`gpu_model_builder.cc:3096-3124`, `mean_stddev_normalization.cc:244-360`):** `RMSNormalization` omits `gamma` (emitting 302 separate `Mul` dispatches = 604/1,726 ops = 35% of graph) and computes unused `mean` without `simd_sum`.
   - **Missing Pipeline & Resource Hints (`compute_task.mm:261-320`, `metal_arguments.mm:436-458`, `work_group_picking.cc:303-322`):** Uses bare `[device newComputePipelineStateWithFunction:]` instead of `MTLComputePipelineDescriptor` (`requiredThreadsPerThreadgroup`, `threadGroupSizeIsMultipleOfThreadExecutionWidth = YES`, `buffers[i].mutability = MTLMutabilityImmutable`); `AddResourcesToEncoder` sets `MTLResourceUsageRead | MTLResourceUsageWrite` on read-only weights; `GetWorkGroupSizeForApple` picks `{8, 1, 1}` (75% idle SIMD lanes) on 1D kernels.
   - **M-series 640-barrier K-loop (`fully_connected.cc:831-841`) & FP16 `floor()` nibble unpack (`common/task/util.cc:686-771`):** Worth benchmarking integer bit-mask unpack vs. `floor()` on A19 Pro ALUs.

---

## 4. Prefill, A19 Pro Neural Accelerators (MPP) & Apple Silicon Features

Cross-checked against iOS 27.2 SDK headers, WWDC26 Session 330, and Apple Tech Talk 111432:

1. **`ConvAppleMPP` 32,768-Byte Threadgroup Ceiling (`conv_apple_mpp.cc:438-444`):** `N_TILE=128, M_TILE=64` with `int32` accumulators allocates `__local int tmp[128 * 64]` = **32,768 B (100% of Apple Silicon's 32 KiB per-core threadgroup memory)**, capping occupancy to **1 TG/core**. Applying scale/zero-point/bias directly in `cooperative_tensor` registers via `c_tile.get_multidimensional_index(i)` drops threadgroup memory to **0 B** (2–3× occupancy).
2. **Morton Z-Order Threadgroup Walk (`Tech Talk 111432`):** `ConvAppleMPP` (`conv_apple_mpp.cc:316-320`) dispatches `(gid.x, gid.y)` in linear raster order (~50% Neural Accelerator utilization on LLC-bound GEMMs). Bit-deinterleaving into **Morton Z-order** raises utilization toward 100% (~33% faster 4K×4K GEMMs in Apple's trace).
3. **Coarse K-Chunk Sync & Apple10 QK Window Skip (`conv_apple_mpp.cc:137-141`, `bounded_attention_kernel.cc:84-120`):** `dynamic_length_v<int>` lets 4 SIMD groups drift across K tiles; coarse K-chunking with `threadgroup_barrier(mem_none)` (no `a_loc`) restores cache lock-step and enables sliding-window QK skip on Apple10. `MaskBoundsOp` linearly scans all 65,536 mask keys in 1 thread/row (`{8,1,1}`) instead of stopping at `params[2]`. Also 47 `kUint8` PLE linear weights miss `80c07920`'s `kInt8` check (`gpu_model_builder.cc:1342`).
4. **MSL 4.1 (`ios(27.0)`) FlashAttention & Native `int2b_format` (`WWDC26-330`):** Cooperative-tensor `execution_simdgroup` + `reduce_rows` + `map_iterator` + `get_left_input_cooperative_tensor` fuses prefill `SoftMax(Q×K)×V` without materializing the **128 MB** `[1024, 65536]` score matrix; `int2b_format` accelerates the **168 MB INT2 LM head** in `prefill_*`/`verify_8`.
5. **Shader Compilation Deduplication + `MTLBinaryArchive`:** Caching `(msl_source, defines) -> id<MTLComputePipelineState>` collapses ~6,910 serial compiles/load to ~250 unique PSOs (`~8 s → ~1.5 s` cold, `~1.2 s → ~0.3 s` warm, `−25 MB` PSO RAM).
6. **Vision/Audio & ANE Co-Execution:** Vision GPU delegation is blocked by `VisionAdapter::Initialize` omitting `SetHardwareAccelerators(kGpu)` (`vision_litert_compiled_model_executor.cc:362-376`), `OneHotOperationParser::IsSupported` checking `axis` against dim *size* instead of rank (`model_builder.cc:4084-4095`), and ~6 2D patch preamble ops. Moving `EmbeddingGemma 2` (768-dim), streaming dictation (`SpeechAnalyzer`), and evaluated ViT/Conformer encoders onto A19 Pro's 16-core ANE (`CoreAI` / `CoreML` `.cpuAndNeuralEngine` + `.continued-processing.inference`) eliminates GPU contention and thermal impact.

---

## 5. Memory Pools, Sparse KV & App Calibration

1. **`verify_8` Intermediate Pool Duplication (`memory_manager.mm:115-120`, `verify_n.py:649-673`):** `verify` (size $S_4$) delegates before `verify_8` ($2 S_4$), preventing `SharedBuffersPool` (`found >= req && found <= 2 * req`) from reusing buffers (+25–35 MB). Delegating `verify_8` first shares 100% of intermediate buffers.
2. **`SparseKvMapper` Trim & Zero-Blit Snapshots (`runtime/executor/litert/state.cc:525-600`):** Map/unmap sync and the `32,000` straddling-tile bitmap are race-free, but `TrimKvMapping` is not called on `Executor::Reset()` or `SetCurrentStep` rewinds. `MTL4CommandQueue.copyMappings` can replace GPU blits for whole-tile helper snapshots.
3. **`DeviceProfile`, `ContextBudget` & `gpu_info.cc` (`Agello/Inference/DeviceProfile.swift:52-123`, `InferencePlanner.swift:140-159`, `gpu_info.cc:718-736`):**
   - `kvBytesPerToken = 28_672` overestimates the 128K ring-KV file (`8,192 B/tok + 31.5 MB`) by 3.5×.
   - `ContextBudget.replyReserve` reserves `16,384–20,480` tokens at 64K; capping at `4,096 + thinkingBudget` unlocks ~56–60K usable single-prompt tokens.
   - `gpu_info.cc` prefix-shadows `"apple m4 ultra"` and `"apple m6 pro/max/ultra"` onto base 10/12-CU entries, bypassing G1 (`e5e4c6eb`).

---

## 6. Numerical Accuracy & `llguidance` Constrained Decoding

1. **Exact Binary16 RoPE Sweep (`0..131,071`, `tools/model-surgery/window_128k.py`):** Zero overflow and zero depth-dependent error growth across all 131,072 positions. Max error is a periodic **`0.239 rad`** from `FP16(l) * FP16(f_i)` (`l = 0..511`) plus `0.00098` from the legacy `+2.0` table bias. Replacing the low-part `MUL + SIN/COS` with an unshifted `[512, F]` `GATHER` table (+256 KiB total) cuts max error **300×** to **`< 0.00078 rad`** and removes 6 ops/signature.
2. **Kernel Numerics:** `AddValuesToCacheKernel` (`add_values_to_cache_kernel.cc:99-164`) computes `(clamped - min) * inverse_scale` in FP16 (`0.125` ULP jitter shifting ~12.5% of INT8 KV boundaries by ±1 bin; FP32 makes it bit-exact). Padded-row `Softmax` (`softmax.cc:145`) writes `1.0f / 0.0f = +Inf` when `row_end == 0` (`sum > 0 ? 1/sum : 0` guards it). Keep `CalculationsPrecision::kF16` I/O (changing globally to `kF32F16` disables `ConvAppleMPP` at `conv_apple_mpp.cc:103`) while testing FP32 `c_tile` accumulation on 64K PV.
3. **`llguidance` `TokTrie` & Tool+Think Constraints (`llg_constraint_provider.cc:82-98`, `tasks.cc:718-722`):**
   - `LlgConstraintProvider` passes raw SentencePiece `▁` (`\xE2\x96\x81`) and `<0xXX>` instead of decoded bytes (`0x20`, raw byte `0xXX`) and omits the **`0xFF` (`TokTrie::SPECIAL_TOKEN_MARKER`)** prefix on control tokens (`<|turn>`, `<turn|>`, `<|thought>`, `<thought|>`, `<|tool_call>`), breaking multi-word JSON schema enums.
   - `SuppressTokensConstraint` wraps outside `ThinkingBudgetConstraint`, so `<|thought>` (`109`) consumes `first_token_only` before the visible post-thought answer begins.
