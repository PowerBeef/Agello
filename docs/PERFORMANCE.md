# The performance plan: A19 Pro, A20 Pro and the full window

**Status: approved 2026-11-13 (the maintainer's go). Phase P0, the measurements, is next.** This is the detailed plan for
milestone B5 of [BACKEND.md](BACKEND.md) ("The performance work"): faster replies on the iPhone 17
Pro (A19 Pro) and the iPhone 18 Pro and iPhone Duo (A20 Pro), the least memory the app can hold,
the same output quality, and Gemma 4 E4B's full trained window of 131,072 tokens.

It comes from a read of the runtime's code on `agello-one` (`edb2c7db`), the records already on
disk (no new runs), the fork's reference, Apple's iOS 27.2 SDK headers, and published sources
(listed at the end). Every figure is marked:

- **[M]** measured, with its record: Mac figures are the M6 through `scripts/cli-bench.sh`
  (`build/cli/runs/`), iPhone figures the iPhone 17 Pro through `scripts/phone-bench.sh`
  (`build/phone/runs/b3`, 2026-11-12) or the harness (`build/device-harness/`), runtime builds
  `99b8f5f6ea49` (shipped) and `9128dc9c2055` (B3).
- **[A]** Apple's claim, **[P]** someone else's published measurement or claim.
- **[E]** an estimate: arithmetic from the measured figures, to be confirmed by the measuring
  step each change starts with.

Paths: `RT` is the runtime's checkout (`../agello-arms/next/LiteRT-LM`, branch `agello-one`),
`MD` its ML Drift (`RT/agello/ml_drift/ml_drift`), `LD` its Metal delegate
(`RT/agello/litert/ml_drift_delegate/delegate`), `REF` the fork's reference
(`../LiteRT-LM/docs/agello/reference`).

## In short

1. **Decode is close to the phone's memory bandwidth already.** A decode step reads 2.2 GB of
   weights in 37.2–37.7 ms on the iPhone, 58.8 GB/s [M], against about 77 GB/s for the A19 Pro's
   memory (LPDDR5X-9600 on a 64-bit bus; derived from its specs, Apple publishes none) [P]. A
   faster matrix-vector kernel can buy 10 % at most. Decode gets faster in three other ways: the
   GPU sits idle 14 % of every speculative round on the iPhone while the host works, against 7 %
   on the Mac [M]; more tokens per weight read (speculative decoding); and less heat.
2. **The A19 Pro's GPU neural accelerators serve prefill.** Prefill already runs its matrix
   products on them (`ConvAppleMPP`, int8 × int8, 25 TOPS on the M6 [M]), but converts every INT4
   weight to INT8 again on each run, computes local layers' attention over the whole context
   instead of their 512-token window, and converts the cache to FP16 each run. The iOS 27 SDK has
   a native int8 × int4 matrix product (`MPPTensorOpsMatMul2d.h`, MSL 4.0) and cooperative tensors
   for a fused attention: both remove work without changing a bit of the output.
3. **The weights don't count against the app's memory limit; context does.** The 2.2 GB of GPU
   weights are clean file pages wrapped without a copy [M]. What counts: the KV cache (917.5 MB at
   32,000 positions, 655 MB of it for local layers that only ever read 512 positions), about
   61 KB per position of unfused prefill attention buffers kept after a long prompt, 1.2–1.5 GB
   held by the vision encoder after the first image, and a full-length copy of the KV cache for
   each helper [M]. The app's limit is often 6.44 GB, not 8.59 GB [M]: plan for 6.44.
4. **The full 131,072-token window needs no re-export.** A graph-only edit of the model file
   (like the rotary fix) lifts the 32,003 export limit, with the weights byte for byte. It fits
   only once local caches become 1,536-slot rings and prefill stops building context-sized score
   buffers: then 128K holds about 2.2 GB steady and 3.7 GB at its peak, against about 11.6 GB
   today [E].
5. **The A20 Pro brings 50 % more memory bandwidth [A]**, so decode should gain about 40 % with no
   change [E]. The plan tunes on the phones, not the Mac: the M6 is another GPU family (Apple11)
   with about twice the A19 Pro's bandwidth.

## Where a reply's time and memory go today

### Time (iPhone 17 Pro, B3 build, 32,000-token window, speculative decoding on) [M]

| | `explain` (Think) | `email` |
| --- | --- | --- |
| One speculative round | 55.7 ms, 2.36 tokens (42 tok/s) | 50.5 ms, 2.46 tokens (49 tok/s) |
| Verify run on the GPU (4 positions) | 43.2 ms (77.5 %) | 39.2 ms |
| Drafter on the GPU (3 runs) | 4.6 ms | 3.3 ms |
| Host work around them (encode, commit, wake, logits copies, CPU picks) | 7.9 ms; the GPU waits | 8.0 ms |
| Drafts kept | 45 % | 48 % |
| First token | — | 0.535 s: prefill 439 ms (three 128-token runs), a plain decode step 39 ms, then a whole speculative round before anything streams |

- A plain decode step is 37.2–38.1 ms on the GPU; a 4-position verify costs 1.04–1.09 times
  that, so the weight reads dominate both.
- Prefill: 782 ms per 1,024-token run (1,310 tok/s), 141 ms per 128-token run, whatever it
  holds. `file-report` (4,879 tokens) waits 4.10 s for its first token.
- Every host-side span on the iPhone takes 3.3 to 4.2 times the Mac's for the same work, in every
  run: the host side of a step is a steady 9.3–9.6 ms, the Mac's 1.6–2.7 ms. The runtime's
  execution thread asks for no quality of service (`RT/runtime/framework/worker_thread_pthread.cc:77`
  creates it with default attributes and only names it).
- Heat: `explain` lost 25 % between the first round and the next two, all on the GPU's side,
  while the phone reported "nominal".

### Memory (iPhone 17 Pro) [M]

| | 8K window | 32K window |
| --- | --- | --- |
| After load | 1.23 GB | 2.88 GB |
| After a long prompt | 1.17 GB (2.3K tokens) | 3.35 GB (8.4K tokens) |
| Of which KV cache | 234.9 MB | 917.5 MB |
| Other Metal memory that grows with the window | ~0.5 GB | ~1.95 GB: about 61 KB per position beyond the KV's 28.7 KB |
| First image | +1.21 GB | +1.48 GB, held until the engine is released |
| Peak with helpers (web suite, 6.44 GB limit) | — | 5.68 GB, a memory warning at each helper |

- Not counted: the decoder's weights (the ML Drift weight cache, mapped and wrapped with
  `newBufferWithBytesNoCopy`, `LD/gpu_backend_metal.mm:355-392`), the 837 MB of per-layer
  embedding tables and the token embedder (mapped sections of the model file).
- The limit: 8.59 GB in most October runs, 6.44 GB for whole runs in November, iOS 27.2.1
  included. Memory warnings start about 1.3 GB below it.

### What the runtime does on the GPU (M6 per kernel, level 4; the iPhone has no per-kernel record yet) [M]

| Graph | Largest kernels |
| --- | --- |
| Decode (1,726 nodes) | `fc1x1_int4_weights` 68 % at 133 GB/s (87 % of the M6's ~153 GB/s); the INT2 LM head 5.8 %; RMS norms 3.8 %; softmax 3.6 %; ~1,100 elementwise and layout nodes 8–10 % |
| Prefill, 1,024 tokens | `convolution_int8(conv_apple_mpp)` 39.7 % (25 TOPS); select and softmax 26.7 % before T4's bounded attention; `weights_convert_uint4_to_int8` 8.3 %, 26.4 ms per run whatever the chunk size (28 % of a 128-token run) |

- An MTP round is 18 command buffers and about 2,260 dispatches, re-encoded every run
  (`MD/metal/inference_context.mm:767-801`). Indirect command buffers are written but switched
  off (`add_icb_support = false &&`, `inference_context.mm:175`).
- Classic Metal only: no `MTL4CommandQueue`, argument tables, residency requests or binary
  archives. Shaders compile from source at every load, about 6,910 compiles across the five
  graphs, not deduplicated (`inference_context.mm:293-298`); a cold load takes 7.2–9.6 s on the
  iPhone, a warm one 1.1–1.3 s.
- Decode attention reads only the filled length, and local layers only their window (T4). Prefill
  attention on Apple10 does neither for local layers (`MD/common/kernels/conv_apple_mpp.cc:127-139`).

## The hardware

| | iPhone 17 Pro, Pro Max (A19 Pro) | iPhone Air (A19 Pro) | iPhone 18 Pro, Pro Max, iPhone Duo (A20 Pro) | Dev Mac (M6) |
| --- | --- | --- | --- | --- |
| GPU | 6 cores with a neural accelerator in each [A] | 5 cores [A] | 7 cores, "up to 40 % faster than A19 Pro" [A] | 12 cores [A] |
| Memory bandwidth | ~77 GB/s [P, from specs] | same | "50 % more than A19 Pro" [A], ~115 GB/s [E] | 153–170 GB/s [A/P] |
| RAM | 12 GB | 12 GB | 12 GB [P] | up to 32 GB |
| Metal family | Apple10 [A, feature set tables 2026-10-23] | Apple10 | not yet listed by Apple | Apple11 [A] |
| What ML Drift assumes | A19 Pro, 6 units, Apple10 (`MD/common/gpu_info.cc:704, 909`) | A19, 5 units | A20 Pro, 7 units, Apple10 (`:705, 911`) | M6, Apple10, units approximate |
| Sustained GPU (20-minute stress tests) | 61–65 % of peak [P] | — | 63 % (18 Pro), 79 % (18 Pro Max) [P]; Apple claims +40 % sustained [A] | — |

What the neural accelerators do, and what reaches them:

- Matrix products only, in each GPU core beside the ALUs, "designed to accelerate dense
  compute-bound work such as the prefill stage of an LLM" [A, WWDC26 session 330]. On a 5-core
  A19: about 7.5 TFLOPS FP16 and 13.5 TOPS int8 against 3.2 TFLOPS on the ordinary FP16 path [P].
  Decode is bound by memory, so Apple's own MLX measurements on the M5 show time to first token
  3.3–4.1 times faster than the M4 and generation only 1.19–1.27 times, tracking bandwidth [A].
- They're reached through Metal Performance Primitives' tensor operations in Metal Shading
  Language 4 (`mpp::tensor_ops::matmul2d`). The iOS 27.2 SDK lists, among others,
  `int8_t × int4b_format → int32_t` and `uint8_t × uint4b_format → int32_t`
  (`MetalPerformancePrimitives.framework/Headers/MPPTensorOpsMatMul2d.h:56-57`, MSL 4.0),
  `half × int4b_format`, `int8_t × int2b_format` and FP8/FP4 (MSL 4.1), cooperative tensors as
  matmul inputs and row reductions for a fused attention (deployment target 27.0), and persistent
  kernels (`MTLComputePipeline.h`, iOS 27.0). ML Drift caps the language at MSL 4.0
  (`MD/metal/common.mm:255-272`).
- Apple's advice: kernels written on `simdgroup_matrix` should move to these tensor operations
  [A, tech talk 111432]. Its 4K × 4K demo went from over 2 s to about 0.33 s with tensor
  operations and a Morton-order walk of the threadgroups [A].
- The Neural Engine stays out: the backend is GPU-only by the maintainer's choice, E4B ran at
  15.7 tok/s on it against about 27 on the GPU [P], and since iOS 27 its memory counts against
  the app [A, release notes].

Consequences for the plan:

- Tune on the phones. The Mac is Apple11 with twice the bandwidth, and the iPhone's host-side
  behavior differs (above): a Mac gain is a lead, as BACKEND.md already says.
- The A20 Pro's extra bandwidth is the largest decode gain on the list, and it's free: the plan
  only has to keep the kernels bandwidth-bound and avoid name-based tuning that misses a new chip.
- Sustained speed is a power budget of about 5–6 W [P]: every byte not read is heat not made, so
  the decode tracks below also delay throttling.

## The plan

Seven tracks. Each change is judged as BACKEND.md says ("How a change is judged": `cli-bench.sh`
on a quiet Mac, `phone-bench.sh` on the iPhone, replies compared and read, the ledger), plus the
gates named in its row. "Exact" means the change shouldn't alter a single token: identical replies
are its test. Gains in different rows of a track can overlap; the track says when they do.

### Track 0. Measure what the plan is missing

None of these changes the app; each settles a figure the plan only estimates.

| # | Measurement | Why |
| --- | --- | --- |
| 0.1 | A telemetry level-4 run on the iPhone (none exists), and one on the M6 after T4 | Every kernel share above is the M6's, partly from before T4 |
| 0.2 | An Instruments System Trace of a reply on the iPhone: core type, clock and wake-up latency of the execution thread | Explains the steady 9.5 ms host side before Track A changes it |
| 0.3 | A stream-read kernel on the iPhone | The A19 Pro's real bandwidth: the ceiling every decode estimate leans on |
| 0.4 | Memory: log the jetsam limit per run, ML Drift's memory plan per graph (a hook in `MD/metal/memory_manager.mm`), and the footprint after each helper | Confirms the 61 KB per position attribution and the unexplained 1.99 GB outside Metal at the end of the web suite |
| 0.5 | A long-context baseline at 32K: a keyed multi-needle table and probe 12's digit copies through the app | The reference later changes and 64K/128K are judged against |
| 0.6 | The phone bench's rest rule for long cases (open since B3) | Heat decided `explain` there; Track A's gains are smaller than that noise |

### Track A. Keep the GPU busy during decode

The iPhone spends about 8 ms of every 50–56 ms round with the GPU idle [M]. These changes share
that budget, so together they're capped at about +15 % [E].

| # | Change | Where | Gain | Risk |
| --- | --- | --- | --- | --- |
| A1 | Give the execution thread `QOS_CLASS_USER_INTERACTIVE` (after 0.2 says what the thread gets now) | `RT/runtime/framework/worker_thread_pthread.cc:77` | +6 to +13 % decode on the iPhone, the upper bound being the idle gap [E] | None; exact |
| A2 | Stream the first token before the first speculative round | `RT/runtime/executor/llm_litert_compiled_model_executor.cc` (priming, ~`:1427-1468` per the analysis) | First token −50 ms on the iPhone (`email` 0.535 → ~0.48 s) [E] | None; exact |
| A3 | Pick greedy tokens on the GPU and read back ids, not 2 MB of verify logits and 3 × 512 KB of drafter logits; first step, scan the shared buffer in place without the copy | `RT/runtime/components/top_p_cpu_sampler.cc:144-164, 212-250`; ML Drift's top-k op | +3 to +5 % [E] | Ties must keep "first maximum" |
| A4 | One GPU-resident round: drafter three times, then verify, chained with one wait; the embedding gathers on the GPU | `RT/runtime/executor/llm_litert_mtp_drafter.cc:514-711` | +10 to +12 % on the iPhone, overlapping A1–A3 [E] | None if the picks match; a large change |
| A5 | Stop re-encoding each run: indirect command buffers back on, or MTL4 argument tables with a residency set | `MD/metal/inference_context.mm:175, 767-801`; `LD/gpu_backend_metal.mm:503-534` | +4 to +5 % on the iPhone [E] | None |
| A6 | Fuse the small kernels: RMS norm into the next matrix product, elementwise chains into epilogues | ML Drift's graph transformations | +5 to +8 % decode, more on the drafter, where INT4 is only 42 % of its time [E] | Bits change: read the replies |

### Track B. More tokens per weight read

A round reads the weights once whatever it keeps, so every extra kept token is nearly free.
Everything here keeps the verifier's own picks, so replies stay identical unless a row says so.

| # | Change | Gain | Risk |
| --- | --- | --- | --- |
| B1 | Cut the drafter's head (262,144 × 256 INT4, 33.5 MB, 82 % of the drafter's weights) to the most frequent ~32K tokens, ids remapped in the runtime (`tools/model-surgery`) | Drafter −2 to −3 ms per round on the iPhone, +4 to +5 % [E] | Exact; acceptance may drop slightly: measure it |
| B2 | Drafts copied from the context (prompt lookup or suffix trees) when the reply repeats it: summaries, quotes, edits of a document; MTP otherwise, chosen per round | Up to 2–2.5 times on such tasks in the literature [P]; little on free writing | Exact (greedy verify) |
| B3 | Speculative sampling that keeps the target's distribution (accept with min(1, p/q)) so Regenerate's seeded replies keep MTP; today they turn it off and decode at about half speed (47 against 97 tok/s on the Mac [M]) | Regenerate about twice as fast [E] | Exact in distribution; probe 18 checks the seeds still vary |
| B4 | Speculative decoding for JSON helpers: re-test whether draft and verify still share one grammar matcher in our build (`agello-inference-rules`), and fix the runtime if they do | Titles, memories and web queries 1.7–2 times faster [E] | The grammar must hold: the `web` and `inference` suites |
| B5 | Longer drafts (4 to 7): needs a longer `verify` signature (file surgery) and decode attention past 16 rows (C3) | Only once a draft step is cheap (A4, B1): +10 % on `file-report`, ~0 on `explain` [E] | Exact |

### Track C. The decode kernels

The ceiling is close (above), so this track is about keeping 4-row verify as cheap as one row
and long contexts bandwidth-bound.

| # | Change | Where | Gain | Risk |
| --- | --- | --- | --- | --- |
| C1 | A leaner INT4 matrix-vector kernel: FP32 accumulation with the scale applied once per row, the bit-trick unpack already written and switched off, 16-byte loads, `simd_sum` instead of a threadgroup tree | `MD/common/kernels/fully_connected.cc:483, 642, 838`; `MD/common/task/util.cc:686-737` | ≤10 % (iPhone decode step ~34 against 37.4 ms at best) [E] | Precision improves, bits change: read the replies |
| C2 | The INT2 LM head (168 MB read every step) gets the same treatment | same | ~1 % [E] | same |
| C3 | Decode attention at long context: split the key reduction across more threadgroups (16 on the iPhone today) with FP32 accumulation of the value products (FP16 today), and a grouped-query kernel past 16 rows | `MD/common/kernels/fully_connected.cc:702-720`; port of `LD/composite/sdpa_transposed_kernel.cc:1120` with INT8, window and runtime bounds | Needed at 64K–128K (a step reads 1.9 GB of KV at 128K) | FP32 accumulation is the safer numerics at 128K |

### Track D. Prefill on the neural accelerators

| # | Change | Where | Gain | Risk |
| --- | --- | --- | --- | --- |
| D1 | Native INT4 in prefill: lay the weights out once, in the weight cache, as a 2D INT4 operand that MPP's `uint8 × uint4b → int32` reads directly and a new decode kernel reads too, and drop the per-run conversion. First step: wire the in-kernel conversion already written and never selected (`CreateConvAppleMPPInt8(…, ExternalWeights)`) for 128-token runs | `MD/common/gpu_model_builder.cc:1041-1083, 1351`; `conv_apple_mpp.cc:743-765`; `MD/common/selectors/convolution_selector.cc:388-398` | Short prompts' prefill −35 to −45 % (`email` first token ~0.35 s); 1,024-token runs −7 to −10 % [E] | Exact: same INT8 activations, integer accumulation |
| D2 | Prefill attention: the 512-token window for local layers, INT8 keys and values read directly (`half × uint8`, 46 conversions per run dropped), then one fused attention kernel on cooperative tensors with FP32 softmax statistics (the pattern of WWDC26 session 330) | `conv_apple_mpp.cc:127-139`; `LD/composite/bounded_attention.cc` | 5–10 % at 5K-token prompts, 25–35 % at 30K [E]; removes the context-sized score buffers (E3) | Window and INT8 reads exact; fusion changes the summing order |
| D3 | `ConvAppleMPP` epilogue in registers instead of a 32 KB threadgroup staging array; activation quantization folded into the RMS norm before it; Morton-order threadgroups and tiles tuned on the phone | `conv_apple_mpp.cc:302, 436` | 4–8 % of prefill [E] | Bits may change |
| D4 | Chunking from measured costs: padding (118 padded tokens cost `email` ~84 ms), the 512 threshold, maybe 256 and 512 signatures | `RT/runtime/executor/litert_compiled_model_executor_utils.cc:507-628` | Up to 4 % of long prompts, ~80 ms on some short ones [E] | Chunking can shift FP16 sums |

### Track E. Memory

| # | Change | Where | Saved | Risk |
| --- | --- | --- | --- | --- |
| E1 | Create the vision encoder on the first image instead of at load, and release its working memory after each encode | `RT/runtime/framework/resource_management/resource_manager.cc:862-878`; `threaded_execution_manager.cc:179-184` | 1.21–1.48 GB whenever an image was sent [M] | 0.2–0.5 s per image to re-create [E] |
| E2 | Ring-buffer local caches of 1,536 slots (1,024-token chunks plus the 511-token window): the file declares them, the in-graph window mask becomes ring-aware, the runtime writes the update length it now leaves at zero (`utils.cc:678-697`: rings would silently get no writes), and the drafter's reads of cache 22 follow | file surgery; `RT/runtime/executor/litert_compiled_model_executor_utils.cc`; `LD/composite/add_values_to_cache_*` | 624 MB at 32K (KV 917.5 → 293.6 MB), 1.31 GB at 64K, 2.65 GB at 128K; each helper copy shrinks the same [E, arithmetic] | Exact; local layers read all 1,536 slots unless the window kernels learn the ring (~−2 % decode) |
| E3 | No context-sized prefill buffers: D2's fused attention; until then, only 128-token chunks above 16K | D2; signature choice at `llm_litert_compiled_model_executor.cc:2208-2223` | ~1.8 GB at 32K after a long prompt, ~7.5 GB at 128K [E] | The interim slows long prefill |
| E4 | Helper snapshots copy the filled positions only, and the keep rule counts filled bytes | `RT/runtime/executor/litert/state.cc:276-320`; `Agello/Inference/DeviceProfile.swift:63-67` | Up to 0.8 GB at 32K with a 4K chat [E]; 112 ms copies get shorter | Layout-aware copy for the transposed V |
| E5 | Release ML Drift's pooled intermediates after a prefill | `MD/metal/memory_manager.mm:269-372` | ~0.47 GB steady at 32K [M difference], mostly covered by E3 | A few ms per prefill |
| E6 | Lock shared buffers without host shadow copies; fill masks on the GPU | `LD/buffer_handler_metal.mm:479-582` | 65–200 MB [E] | None |
| E7 | Compress the per-layer embedding tables' zero points (44 MB of int32 zeros) | LiteRT's `compress_quantization_zero_points` (`RT/agello/litert/litert/runtime/litert_runtime_options.h:37`) | ~44 MB [E] | None |
| E8 | Release EmbeddingGemma when search has been idle, not only on a memory warning | `Agello/Knowledge/KnowledgeBase.swift:69-72`; `MemoryPolicy.swift:20-22` | ~0.12 GB [E] | 0.3–1 s on the next search |
| E9 | Budget for the 6.44 GB limit: the window rule (`DeviceProfile.swift:74-116`) and the keep rule were calibrated in runs that had 8.59 GB; add a "32K, an image and a helper at 6 GiB" step to the `memory` suite | app | Fewer warnings and releases | — |

Not worth it for memory: re-quantizing weights (they aren't counted, and quality would drop),
logits (under 8 MB), the drafter (45 MB, clean). On disk only: the weight cache repeats 2.2 GB of
the model file; shipping the GPU layout inside the file (BACKEND B5 thread 4) removes it.

### Track F. The full window

The model was trained for 131,072 positions (RULER 95.2 at 32K and 86.6 at 128K for the full-precision
model [P, Gemma 4 report]). Today the file sizes every context dimension to 32,003, the runtime can
only shrink that, and our rotary tables stop at 32,767.

| # | Change | What it takes | Risk |
| --- | --- | --- | --- |
| F1 | Resize the file: every 32,003 becomes the prime 131,101 (the runtime then allocates 131,072 when asked for the maximum, and anything below it on request), with the reshape parameters, `cache_update` sizes and the two position constants per graph rebuilt, in the main graph and the drafter. Weights byte for byte. `ContextBudget.allocatedPositions` follows the new file (32,768 then gives 32,768) | A `tools/model-surgery` script beside `patch_rope.py`; the runtime's magic-number code already does the rest (`RT/runtime/executor/magic_number_configs_helper.cc`, `RT/agello/litert/litert/runtime/magic_number_utils.cc`) | Identity at ≤ 32K is the gate |
| F2 | Extend the rotary fix to 131,072: compute the block split in INT32 (`FLOOR_DIV`, `FLOOR_MOD`), because the candidates `patch_rope.py:249` casts to float overflow FP16 past 65,519; keep 512-token blocks (emulated phase error 0.236 rad, not growing with position) or split in two levels for less intermediate memory | `patch_rope.py:51-52, 249-250` | Emulated, bounded; checked offline over all 131,072 positions |
| F3 | Decode at long context: C3, and the drafter's global block limited to a recent window (−0.8 GB read per round at 128K, drafts only) | Track C; drafter graph | Exact (verify decides) |
| F4 | Keep a chat's cache on flash: the 4 global caches plus the last 512 local positions (8 KB per token: ~90 MB for a 10K chat, ~1 GB at 128K), saved when the user leaves the chat or the app, restored instead of re-reading the history | LiteRT-LM's session save and restore; AppState's reseed path | Exact. At 128K a re-read costs minutes and a restore under a second [E] |
| F5 | INT4 for the global caches 5, 11 and 17, keeping cache 23 (read by layers 23, 29, 35, 41 and the drafter) in INT8, with per-position key scales | New cache write and read kernels | Measured risk: Gemma's attention scale of 1.0 makes it sensitive to KV error [P]. Only if 128K decode speed needs it, and only with the needle tables passing |

Budgets once E1–E4 are in [E]: steady 1.02 GB at 32K, 1.44 GB at 64K, 2.24 GB at 128K; peak with
an image or a helper copy 2.50, 2.92 and 3.72 GB. Today's layout would need about 6.1 GB at 64K and
11.6 GB at 128K.

What 128K will feel like [E]: prefill of a 128K document takes minutes even after Track D, so the
window serves documents read once and kept (F4, with `BackgroundWork` for long reads), not every
message. Decode at 128K reads 1.9 GB of cache per step beside 2.2 GB of weights: about 24 tok/s
with speculative decoding on the iPhone 17 Pro, about 33 with F3 and F5.

The window stays the app's choice, not a setting (no engine knobs, `product-not-a-sandbox`):
`DeviceProfile` picks the largest window the measured room allows, as it does now between 8K and 32K.

Quality gates for every window step:

1. Identity: the resized and ring files give the same greedy replies as today's at ≤ 32K (bench,
   probe 12).
2. Probe 12b: 48-digit copies answered at about 33K (past the old table edge), 65.5K (past FP16's
   largest integer), 96K and 130K, with controls that tell the rotary path from retrieval.
3. A keyed multi-needle table at 0–100 % depth of 32K, 64K and 128K, in the fix loop's table
   pattern.
4. A diffuse-attention probe (aggregating over many similar records), FP16 against FP32 on the Mac.
5. `test15` through the app at 64K and 128K with a real document; `calibrate` at both sizes.

### Track G. One hardware class, and the A20 Pro

| # | Change | Why |
| --- | --- | --- |
| G1 | Detect the GPU family with `supportsFamily` instead of the device name | ML Drift matches names (`MD/common/gpu_info.cc:690-768`). The A20 Pro is listed, but any chip name it doesn't know falls to Apple1 with 4 units, which turns off `ConvAppleMPP` and takes prefill off the neural accelerators |
| G2 | Compile at MSL 4.1 on iOS 27, and drop the Apple7–9 paths | Unlocks the int2, FP8 and FP4 operands and persistent kernels; less code to keep |
| G3 | Tile shapes and work-group splits measured on the A19 Pro (6 cores), then the A20 Pro (7), never taken from the Mac | The phones are a different family with half the bandwidth or less |
| G4 | Load time: deduplicate the per-node compiles and keep binary archives keyed by the runtime's build id; a cheaper `validate()` | Cold loads of 7.2–9.6 s; ~0.18 s off each warm load [E] |
| G5 | The A20 Pro: on the bench as soon as one is available. Until then `AGELLO_SIMULATE_APPLE_GPU="Apple A20 Pro"` exercises its code paths on the 17 Pro | Apple claims twice the FP8 rate on its accelerators [A via press]; FP8 weights would mean re-quantizing, a quality question for later, not this plan |

### Track H. Heat

- Measure sustained decode on the phone: ten minutes of replies, tokens per second by minute,
  thermal state beside it (the bench's `explain` already showed −25 % with the phone at "nominal").
- Everything in Tracks B and C cuts energy per token and so delays throttling; Track A trades
  a little CPU for GPU time and is measured for heat as well as speed.
- Keep passive GPU waits (benchmark mode stays off, as `ChatEngine.swift:194` sets it).
- Measure whether the chat's 60 frames per second while streaming take GPU time from the model.

## Order of work

| Phase | Contents | Why first |
| --- | --- | --- |
| P0 | Track 0 | Settles the figures the rest estimates |
| P1 | A1, A2, A3 (in-place scan), E1, E7, E8, E9, G1, D4 | Exact or near-exact, small, and E1 alone frees more memory than anything but the rings |
| P2 | D1, then D2 and D3 | Prefill on the accelerators; D2 also removes the context-sized buffers (E3) |
| P3 | A4, A5, A6, C1, C2, B1 | The decode pipeline and kernels |
| P4 | E2, E4, E5, E6 | The memory layout that 64K and 128K need |
| P5 | F1, F2, F3, F4, C3, then the gates; 64K first, then 128K | The full window |
| P6 | B2, B3, B4, B5, F5, G2 | Larger or quality-sensitive work |
| P7 | G3, G5 on the A20 Pro | When the hardware is on the bench |

Each phase ends in releases only through the existing gate: replies identical or read and judged
better, speed outside the noise band on the Mac and confirmed on the iPhone, the suites the change
touches, the ledger row. Release timing stays the maintainer's call.

What the plan expects on the iPhone 17 Pro once P1–P5 are in [E, to be replaced by ledger rows]:

| | Today [M] | Expected |
| --- | --- | --- |
| Decode, short context | 42–49 tok/s | about a quarter to a third faster |
| First token, short prompt (`email`) | 0.535 s | ~0.3 s |
| Prefill, 1,024-token runs | 1,310 tok/s | 15–25 % faster; much more at long context |
| Memory after a long prompt at 32K | 3.35 GB | ~1.0 GB |
| Largest window | 32,000 | 131,072 |
| On the A20 Pro | — | decode about 40 % above the 17 Pro from bandwidth alone |

## Left out, and why

- **The Neural Engine and Core AI:** the backend is GPU-only by choice; E4B is slower there and
  its memory counts against the app since iOS 27.
- **INT2 decoder weights, pruned LM heads, activation sparsity (TEAL):** they change the output.
  Apple's own 2-bit model lost about 3.4 MMLU points [P].
- **Dropping cache entries (H2O, SnapKV, StreamingLLM):** a later question may need what was
  dropped; follow-up turns are where these fail [P].
- **A persistent INT8 copy of the weights:** +1.95 GB, made unnecessary by D1.
- **A re-export from the checkpoint:** surgery reaches 128K with Google's weights byte for byte.
  A re-export would have to match their quantization and be judged against today's file.
- **Skipping the KV-sharing layers in prefill:** already done; the exported prefill runs only
  layers 0–23 (`../LiteRT-LM/docs/agello/E4B-GRAPH.md:33`).
- **Third-party drafters (DFlash):** fine-tuned for another checkpoint, 4.7 times the size of
  Gemma's drafter, another license.

## Corrections to the record

Found while reading. The BACKEND.md one is fixed; the fork's reference waits for its own pass:

- `REF/facts.md` F-019: the app turns benchmark mode off (`ChatEngine.swift:194`), so waits are
  passive. F-094: a decode or verify run is 9 command buffers, not 7.
- `REF/apple-platform.md` C1: the 6 GiB limit holds for whole runs, after loads included (November
  runs), not only before the first load.
- `REF/facts.md` F-063: the keep threshold counts 32,000 positions now, not 32,768.
- BACKEND.md, "Where it starts from": the 58–71 % of drafts kept came from the coding prompt; the
  bench's cases keep 44–60 % (Mac) and 45–57 % (iPhone) [M].

## Sources

Apple:

- Newsroom: iPhone 17 Pro (2025-09-09), iPhone Air (2025-09-09), M5 (2025-10-15), M6 (2026-08-25),
  iPhone 18 Pro (2026-09-09), iPhone Duo (2026-09-09).
- Metal Feature Set Tables (2026-10-23); the Metal Performance Primitives Programming Guide.
- WWDC26 session 330 (Metal tensors), 324 and 326 (Core AI); WWDC25 session 262 (Metal 4 machine
  learning); tech talk 111432 (M5 and A19 GPUs for machine learning); WWDC18 session 416 (memory).
- iOS & iPadOS 27 release notes; the `increased-memory-limit` entitlement page.
- Apple Machine Learning Research: "Exploring LLMs with MLX and the neural accelerators in the M5
  GPU" (2025-11-19); the Apple Foundation Models reports (2024, 2025, 2026).
- The iOS 27.2 SDK headers: `MPPTensorOpsMatMul2d.h`, `MPPTensorOpsAvailability.h`, `MTLTensor.h`,
  `MTL4MachineLearningCommandEncoder.h`, `MTLComputePipeline.h`, `MTLLibrary.h`.

Published measurements and papers:

- Gemma 4 technical report (arXiv 2607.02770); Google's Gemma 4 QAT and MTP pages; the LiteRT-LM
  Gemma 4 performance page.
- T. Zakharko, A19 neural accelerator benchmarks (2025-10-15); BaseRT (arXiv 2607.19438);
  integer-exact microscaling on MPP (arXiv 2611.00486); john-rocky's iPhone 17 Pro benchmarks and
  GPU-against-Neural-Engine runs; Tom's Guide and LTT Labs sustained-performance tests.
- MLX's quantized and tensor-op kernels and issues #3302, #3837, #3885; llama.cpp pull requests
  #16634, #29570, #29869.
- KIVI (2402.02750), KVQuant (2401.18079), QServe (2405.04532), Quest (2406.10774), MagicDec
  (2408.11049), SuffixDecoding (2411.04975), SCBench (2412.10319), Open-TQ-Metal (2604.16957),
  "LLM in a flash" (2312.11514).
