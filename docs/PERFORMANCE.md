# The performance plan: A19 Pro, A20 Pro and the full window

**Status: approved 2026-11-13 (the maintainer's go). Phase P0, the measurements, is next.** This is the detailed plan for
milestone B5 of [BACKEND.md](BACKEND.md) ("The performance work"): faster replies on the iPhone 17
Pro (A19 Pro) and the iPhone 18 Pro and iPhone Duo (A20 Pro), the least memory the app can hold,
the same output quality, and Gemma 4 E4B's full trained window of 131,072 tokens.

Changed on 2026-11-14 (the maintainer's choices): the work is tuned for the iPhone 17 Pro, the phone on
the bench; the iPhone 18 Pro must run what ships, and its own optimizations wait as notes in Track G.
The window is 32K growing to 64K, not 131,072 ("The window: 32K growing to 64K").

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
| D1, measured (2026-11-13, M6) | First step shipped on `agello-one` (`80c07920`): runs of up to 128 rows read the INT4 weights in place, prefill +23 % on `email`. The second step was prototyped (`agello/experiments/int4_mpp.swift`, all four ways exact): on 1,024-row runs int8 × int4 is no faster than int8 × int8 (1.95–2.27 ms per feed-forward product against 1.47–1.80), and staging the decode layout into a 4-bit tile costs 2.6–3.1 ms at every tiling tried, so those runs keep int8 plus conversion; the most a 4-bit design could save there is the conversion pass, about 7 % of a run. On 128-row runs the best kernel depends on the shape (staged 4-bit 0.46 ms against 0.73 for 2,560 → 10,240; the shipped kernel best on 10,240 → 2,560): a per-shape choice, to tune on the iPhone | — | — | — |
| D2 | Prefill attention: the 512-token window for local layers, INT8 keys and values read directly (`half × uint8`, 46 conversions per run dropped), then one fused attention kernel on cooperative tensors with FP32 softmax statistics (the pattern of WWDC26 session 330) | `conv_apple_mpp.cc:127-139`; `LD/composite/bounded_attention.cc` | 5–10 % at 5K-token prompts, 25–35 % at 30K [E]; removes the context-sized score buffers (E3) | Window and INT8 reads exact; fusion changes the summing order |
| D2, measured and designed (2026-11-13, M6) | Where prefill goes (level-4 kernel timing, the ring/128K file): at 21K tokens and a 32K window, weight products with their conversions 60 %, attention about 22 % (×V 9.4 %, Q·Kᵀ with its mask 6.8 %, window mask 2.6 %, softmax 2.2 %, mask building and KV conversions the rest); at 44K tokens and a 64K window 60 % and 29 %. The bigger lever is the chunk size: above 32K E3's interim allows only 128-token chunks, and the weight products cost 0.30 ms a token against 0.17 with 1,024-token chunks. A fused attention builds no score tensor, so it lifts that limit (91K tokens: an estimated 63 s → 45–50 s) and removes the 1.25 GB the 1,024-token prefill holds while it runs at 32K. Design: T4's pass (`bounded_attention.cc`), which already finds each attention tail and each local layer's window, replaces Q·Kᵀ → mask → softmax → ×V with one node; the kernel starts from the delegate's `FusedFlashAttentionPrefillOp` (8×8 SIMD-group products, online softmax with FP32 statistics), whose K and V addressing is the caches' layout (K `[heads][D/4][T][4]`, V `[heads][T/4][D][4]`, read off real buffers in E4), reads the INT8 caches directly (exact in FP16; the per-cache scales on the scores and the output), gains a head-size-512 tiling (the 32-row query block of 33 KB exceeds the 32 KB threadgroup limit), the local window, ring slots and the filled bound. Developed first as a standalone Metal experiment against a CPU reference (as D1), then ported; the fusion changes the summing order, so replies are read and the needle tables rerun. Sizing: at 91K tokens a fused kernel beats today's matrix-unit products only if each K/V tile serves many query rows (two KV heads for eight query heads, head size 512), which takes a split-head-size tiling on the matrix units: days of kernel work. The shortcut was measured and dropped: 1,024-token chunks up to a 64K window (E3's threshold raised) read a 44K-token prompt 20 % faster (23.2 → 18.6 s) but peak 3.1 GB higher (4,759 against 1,678 MB) and keep 2 GB after it; the score tensors are what the fused kernel removes | — | — | — |
| D2, step 1 and what's next (2026-11-13/14, M6) | Done: the 1,024-token prefill's attention runs in slices of query rows, each with a score tensor of at most 256 MB (`agello-one` `cc84dc50`): bit-identical, `inference` 23/23, peak at 32K 3,625 → 2,799 MB (today's file) and 2,719 → 1,928 MB (ring). With the 128-token limit lifted (trial), 44K tokens at 64K read in 18.5 s against 23.2 and 91K at 128K in 49.8 s against 61.9, answers exact, but 1.4–2.4 GB more memory stays after the reply. Not the masks: the masks were rewritten to read the runtime's own [rows, keys] mask or the positions without their four copies (`build/drafts/d2-rowmask.patch`, not kept), the graphs got leaner and memory rose 0.3–0.6 GB. It's the shared pool: the everyday graphs (decode, verify, the 128-token prefill) borrow the large prefill's bigger buffers and wire them whenever they run, so freeing the large prefill's own buffers (1 GB at 128K) leaves 4.9 GB against 2.5. Next: a private pool for the 1,024-token prefill, freed whole after each long prompt, then lift the limit. An independent review (Claude Fable 5.2) advised against the head-size-512 fused kernel for now (an estimated 3–6 % of prefill at 32K, 10–20 % at 128K, possibly negative: it streams more K/V per row) and pointed to a cheaper exact gain, the ×V product recomputing each probability's exponential once per 128-wide output tile | — | — | — |
| D2, the regime (2026-11-14, M6) | The review's step 1, measured (`agello-one` `0d7e359c`). Sweep on the 128K file, first token at 21K tokens/32K window and 44K/64K: the ×V product's tile 16×512 −2.8 % / +0.2 %, 32×256 −1.8 % / +0.2 %, replies identical (each output tile recomputes its rows' exponentials, fewer with wider tiles); score slices of 32 MB −1.3 % / +11.9 % and 8 MB +9.1 % / +12 %, and slices of 128 rows changed replies (the builder picks other kernels for runs of 128 rows or fewer), so slices keep at least 256 rows. Ceiling (`agello/experiments/mpp_ceiling.swift`): f16 × f16 matmul2d reaches 17–20 TFLOPS on attention shapes, about what attention already does in the model (~18 at 44K tokens), and f16 × int8 is slower (8–17): attention is arithmetic-bound near the M6's matrix units, so fusion or INT8 reads can't speed it up here; only less work can (windows, exact-zero skipping). The 16×512 ×V tile is the one to confirm on the bench, and every shape again on the A19 Pro | — | — | — |
| D3 | `ConvAppleMPP` epilogue in registers instead of a 32 KB threadgroup staging array; activation quantization folded into the RMS norm before it; Morton-order threadgroups and tiles tuned on the phone | `conv_apple_mpp.cc:302, 436` | 4–8 % of prefill [E] | Bits may change |
| D4 | Chunking from measured costs: padding (118 padded tokens cost `email` ~84 ms), the 512 threshold, maybe 256 and 512 signatures | `RT/runtime/executor/litert_compiled_model_executor_utils.cc:507-628` | Up to 4 % of long prompts, ~80 ms on some short ones [E] | Chunking can shift FP16 sums |

### Track E. Memory

| # | Change | Where | Saved | Risk |
| --- | --- | --- | --- | --- |
| E1 | Create the vision encoder on the first image instead of at load, and release its working memory after each encode | `RT/runtime/framework/resource_management/resource_manager.cc:862-878`; `threaded_execution_manager.cc:179-184` | 1.21–1.48 GB whenever an image was sent [M] | 0.2–0.5 s per image to re-create [E] |
| E2 | Ring-buffer local caches of 1,536 slots (1,024-token chunks plus the 511-token window): the file declares them, the in-graph window mask becomes ring-aware, the runtime writes the update length it now leaves at zero (`utils.cc:678-697`: rings would silently get no writes), and the drafter's reads of cache 22 follow | file surgery; `RT/runtime/executor/litert_compiled_model_executor_utils.cc`; `LD/composite/add_values_to_cache_*` | 624 MB at 32K (KV 917.5 → 293.6 MB), 1.31 GB at 64K, 2.65 GB at 128K; each helper copy shrinks the same [E, arithmetic] | Exact; local layers read all 1,536 slots unless the window kernels learn the ring (~−2 % decode) |
| E2, measured (2026-11-13, M6) | Done on the Mac: `ring_kv.py` (fork `agello` `290a1eec`) and `agello-one` `a44d5f25`. 850–870 MB less after each reply at 32,000 positions, 1.45 GB less at the peak, prefill up to 19 % faster, replies as good (ledger). The runtime fixes it needed: the ring's update length (`params[3]`), window detection on position keys only (the rotary fix's block selector had been read as a 512 window), and the value product's key loop clamped to the cache. Shipping it: a release, the ring file on Hugging Face (`PowerBeef02`, the maintainer's go), `ModelCatalog`, and the memory rules in `DeviceProfile` (KV is now 8,192 bytes per position plus 31.5 MB) | — | — | — |
| E3 | No context-sized prefill buffers: D2's fused attention; until then, only 128-token chunks above 16K | D2; signature choice at `llm_litert_compiled_model_executor.cc:2208-2223` | ~1.8 GB at 32K after a long prompt, ~7.5 GB at 128K [E] | The interim slows long prefill |
| E3's interim, measured (2026-11-13, M6) | Above a 32,768-token window the executor leaves out prefills of more than 128 tokens, and the drafter compiles without that selection (`agello-one` `3e60fafd`). A 91K-token prompt peaks at 3.06–3.17 GB instead of passing the 8.59 GB guard; a 64K window peaks at 1.81 GB, below the 32K window's 3.04 GB. Prefill at 91K runs at 1,450 tok/s (63 s). The 32K window keeps its 1,024-token prefill: moving the threshold to 16K, as planned, is still to measure | — | — | — |
| E4 | Helper snapshots copy the filled positions only, and the keep rule counts filled bytes | `RT/runtime/executor/litert/state.cc:276-320`; `Agello/Inference/DeviceProfile.swift:63-67` | Up to 0.8 GB at 32K with a 4K chat [E]; 112 ms copies get shorter | Layout-aware copy for the transposed V |
| E4, measured (2026-11-13, M6) | The runtime's half is done (`agello-one` `37bdbbf5`): a snapshot copies each cache's first step + 16 slots into anonymous memory of the buffer's length, so the rest is never resident, and a restore puts back the same byte runs. The caches are stored heads outermost, then groups of four along the last axis, then the other (the transposed V included, read off real buffers with `AGELLO_VERIFY_KV_PREFIX=1`). A 3.5K-token chat's helper copy: 202 MB instead of 1,835 MB at 32K, 121 MB instead of 2,210 MB at 128K, ~15–20 ms instead of 116–152; the peak 0.76–1.0 GB lower; replies identical. Left: the keep rule in `DeviceProfile` counts `kvBytesPerToken` × the chat's tokens once a release carries this (until then the app's runtime copies whole caches) | — | — | — |
| E5 | Release ML Drift's pooled intermediates after a prefill | `MD/metal/memory_manager.mm:269-372` | ~0.47 GB steady at 32K [M difference], mostly covered by E3 | A few ms per prefill |
| E5, tried (2026-11-13, M6) | Not kept. The pool is one per compiled model, shared by its four graphs: decode references 1.84 GB of buffers, the 1,024-token prefill 3.46 GB (1.6 GB its own), the 128-token prefill 2.04 GB, verify 1.84 GB (borrowing the two 524 MB score buffers for small tensors). The pages a run touches stay resident and wired: after a 3.5K-token prompt at 32K the chat holds 470 MB more than after a short one (3,812 against 3,342 MB), and of the process's 3.6 GB, 2.87 GB is GPU memory, 2.47 GB of it wired (`footprint`). Marking every pool buffer purgeable-empty at the first run after a prefill, with the queue drained, freed nothing: purgeable state only lets the system reclaim later, and wired pages stay counted. Freeing needs the buffers deallocated and every kernel rebound before the next prefill; D2 removes most of the same memory. Found on the way: the process holds 727 MB of CPU heap while decoding (E6's lead). (A first reading of the pool put an FP16 copy of each KV cache in decode; the GPU graph dumps show decode and verify read the INT8 caches directly, and the FP16 conversions, `weights_convert_uint8_to_float16`, are the prefills', one buffer reused layer after layer: see the pool row below.) | — | — | — |
| E6 | Lock shared buffers without host shadow copies; fill masks on the GPU | `LD/buffer_handler_metal.mm:479-582` | 65–200 MB [E] | None |
| E5b, the pool's lending rule (2026-11-13, M6) | Done (`agello-one` `1f6e7f85`): once a graph runs with a pool buffer, all of it stays wired until freed, and verify's and the 128-token prefill's small tensors were borrowing the 1,024-token prefill's 524 MB score buffers. A buffer more than twice the size needed and 16 MB over is no longer lent. A fresh chat at 32K: 3,329 → 1,939 MB with tools, 2,488 → 1,212 MB with the ring file; replies identical, speed the same. The gain lasts until a message runs the 1,024-token prefill (1,024 tokens or more in one prefill: a pasted document, file passages): then its buffers are wired again for the engine's life (about 80 MB left of the gain at 21K tokens). Keeping it after one needs those buffers freed and the kernels rebound after the prefill, the 1,024-token prefill kept for long prompts only (a speed trade, the maintainer's call), or D2 | — | — | — |
| E5c, the large prefill's buffers freed between its runs (2026-11-13, M6) | Done (`agello-one` `b96dedea`): when another graph runs after a prefill graph with at least 256 MB of pool buffers only it references, the queue drains and those buffers are freed (views kept on no buffer, kernels re-pointed); before that prefill runs again they're allocated again and re-pointed, with no recompilation. At 32K that's the 1,024-token prefill's 1.25 GB (a 500 MB buffer and three texture-backed ones). Memory after a long prompt 3,635 → 2,457 MB, after each bench case 1.18–1.27 GB less; replies identical; each long prompt pays the reallocation (prefill −0.7 %, first token +16–30 ms). The 128K window has nothing of 256 MB to free and is unchanged. Still above a fresh chat by ~0.5 GB after a long prompt: the 31–62 MB buffers the prefills share with decode and verify, which stay wired | — | — | — |
| E6, measured (2026-11-13, M6) | The first half is done (`agello-one` `89137792`): packed Metal buffers in shared storage (the prefill masks, embeddings and per-layer embeddings, the decode inputs) lock in place, with no host shadow and no copy on unlock. Host shadows 30 → 8, unlock copies 631 MB → 0 for a 3.5K-token chat; footprint −99 MB with today's file and −73 MB with the ring file at 32K; first token −6 to −9 % on that chat, prefill +1.3 % and replies identical on the bench. Left: filling masks on the GPU (the 1,024-row mask is 32 MB of CPU writes per chunk at 32K). The rest of the 552 MB CPU heap is TFLite's interpreter tables (quantization arrays 70 MB, subgraphs 56 MB), Metal's compiled programs (35 MB), XNNPACK (33 MB) and the tokenizer (21 MB) | — | — | — |
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
| F1, F2, measured (2026-11-13, M6) | Done on the Mac: `window_128k.py` (fork `agello` `72b715e3`) on the ring file; LiteRT-LM allocates 131,072 positions. Replies identical to the ring file's at 32K windows; at 91K tokens, codes placed at 0, 40K and 75K are copied exactly. Retrieval among 4,000 look-alike records falls with length (6/6 at 21K, 5/6 at 44K, 2/6 at 91K, misses in the middle) and doesn't change with 32-bit sums: the model's limit. Through the app a message tops out at 98K tokens at this window (`ContextBudget.replyReserve` holds a quarter of it for the reply), so gate 2's 130K copy needs a smaller reserve for long windows first, an app decision for when the window ships | — | — |
| The window's cost, measured (2026-11-14, M6) | The 128K file through the app's engine (`agello ask`, build `6b91d4d66fa4`), a fresh chat and one reply at each window: 1,294 MB at 32K, 1,316 at 48K, 1,673 at 64K, 1,999 at 96K, 2,490 at 128K, the peak within 5 MB of it. 48K costs almost nothing over 32K only because E3's interim drops the 1,024-token prefill above 32,768, so every prompt there prefills in 128-token runs: 23.2 against 18.5 s for 44K tokens on the Mac, and on the iPhone 8 × 141 ms against 782 ms per 1,024 tokens (1.44×). Decode doesn't follow the window (68–74 tok/s at every size, the GPU not quiet, so ±10 %), only the filled part (75 tok/s at 91K tokens against 94–122 at 21K). With rings the KV cache is 8,192 bytes per position plus a fixed 31.5 MB: 0.29 GB at 32K, 0.57 at 64K, 1.10 at 128K, against today's file's 0.92 GB at 32K | — |

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

**The target is the iPhone 17 Pro** (the maintainer's choice, 2026-11-14: it's the phone on the
bench, and there's no iPhone 18 Pro to measure). Every speed and tile choice is tuned and judged on
the A19 Pro. The iPhone 18 Pro must run what ships, at least as well: G1 keeps an unknown chip
from falling to the slowest kernels, and the memory rules carry over unchanged (both have 12 GB).
What would make the 18 Pro faster is kept as notes, below the table, for when the maintainer
upgrades.

| # | Change | Why |
| --- | --- | --- |
| G1 | Detect the GPU family with `supportsFamily` instead of the device name | ML Drift matches names (`MD/common/gpu_info.cc:690-768`). The A20 Pro is listed, but any chip name it doesn't know falls to Apple1 with 4 units, which turns off `ConvAppleMPP` and takes prefill off the neural accelerators |
| G2 | Compile at MSL 4.1 on iOS 27, and drop the Apple7–9 paths | Unlocks the int2, FP8 and FP4 operands and persistent kernels; less code to keep |
| G3 | Tile shapes and work-group splits measured on the A19 Pro (6 cores), never taken from the Mac | The phone is a different family with half the bandwidth or less |
| G4 | Load time: deduplicate the per-node compiles and keep binary archives keyed by the runtime's build id; a cheaper `validate()` | Cold loads of 7.2–9.6 s; ~0.18 s off each warm load [E] |
| G5 | The iPhone 18 Pro runs what ships: once before a release, the A20 Pro's code paths on the 17 Pro (`AGELLO_SIMULATE_APPLE_GPU="Apple A20 Pro"`: identical replies, the matrix-unit kernels on) | Correctness only; its speed is for the notes below |

**Notes for the iPhone 18 Pro (A20 Pro), for later.** Not scheduled; they wait for the hardware.

- Measure first: a day-one script (stream-read bandwidth, level-4 kernels, a System Trace, ten
  minutes of sustained decode, a per-device baseline in `phone-bench.sh`), and its family with
  `supportsFamily`. If it reports Apple11 like the M6, the Mac becomes its proxy, and the M6's
  "int8 × int4 is no faster" (D1) may hold there while failing on the A19 Pro.
- Bandwidth: Apple claims 50 % more [A], about +40 % decode from that alone [E]. The verify run
  would fall from about 43 to 29 ms [E], so the 8 ms host gap grows from 14 % to about 20 % of a
  speculative round: Track A (A3, A4) is worth more there than on the 17 Pro.
- Tiles and splits from a table keyed by family and core count (7 GPU cores against 6), filled by
  a short tuning run on the phone, instead of name or core-count constants (the 16 threadgroups
  of decode attention, the ×V and Q·Kᵀ tiles, D1's per-shape kernel choice).
- Heat: the 18 Pro reportedly sustains 63 % of peak and the 18 Pro Max 79 % [P]; tune sustained
  decode (Track H) per model.
- The accelerators' FP8 rate, twice the A19 Pro's by Apple's account [A via press]: FP8 weights
  mean re-quantizing and a quality question; left alone.
- The iPhone Duo shares the chip; its screens change the UI, not the runtime.


### Track H. Heat

- Measure sustained decode on the phone: ten minutes of replies, tokens per second by minute,
  thermal state beside it (the bench's `explain` already showed −25 % with the phone at "nominal").
- Everything in Tracks B and C cuts energy per token and so delays throttling; Track A trades
  a little CPU for GPU time and is measured for heat as well as speed.
- Keep passive GPU waits (benchmark mode stays off, as `ChatEngine.swift:194` sets it).
- Measure whether the chat's 60 frames per second while streaming take GPU time from the model.

## The window: 32K growing to 64K (adopted 2026-11-14)

The maintainer's choice, on an independent plan (Claude Fable 5.2; the full text is in
`build/drafts/adaptive-window-plan-fable-2026-11-14.md`, the window review before it in
`window-review-fable-2026-11-14.md`). Chats start at 32K and grow to 64K (65,536 positions) when an
input needs it; the app moves to a fixed 64K if the phone's peak allows (the decision below).
128K isn't a default. This section changes the order of work below where they differ.

**Three findings in the code** (read, not yet shown by a run):

1. Rewinds and ring caches. After a Think reply the conversation rewinds to its checkpoint
   (`SessionAdvanced::RewindToCheckpoint` → `SetCurrentStep`, which only moves the step). With
   1,536-slot rings, a rewind of more than 1,025 positions leaves the local layers reading slots
   later positions overwrote. Upstream turns rewinding off for rings, but only on its Artisan
   backend (`c/conversation.cc:543-553`); ours runs rings on the compiled-model executor with
   rewinding on. A blocker for train 2 at any window.
2. Prefill can't be stopped between its runs (`llm_litert_compiled_model_executor.cc`, the
   work-group loop): Stop and backgrounding wait out a long read.
3. Files are sent again with every message (`AppState.generate`, the file context is rebuilt per
   send; history keeps only the turns' text): about 13 s per follow-up for a 16K document on the
   phone today [E], 45–75 s at 44K.

**The growth.** Budgets: 24,512 input tokens at 32,768 (21,782 with Think), 57,280 at 65,536
with the reply reserve `min(window/4, 8,192) + Think budget`, capped at `window/3` (unchanged at
32K and below). It grows for a message that doesn't fit the 32K room (instead of
`messageTooLong`) and for a whole-document question over the 32K file budget (instead of the
section summaries); never for web results or history. It's a reload and a reseed inside the
prepare step ("Making room…" for 1–2 s, then the reading progress, Stop live), falling back to
today's behavior when the room isn't there. It shrinks only when a chat that fits 32K is opened.
The helper keep rule counts filled bytes (`8,192 × used + 31.5 MB + 400 MB`: 0.97 GB at a full
64K, not 2.28), and above 16K used a helper that can't keep the chat waits instead of wiping it.

**Order on the Mac**

1. Findings 1 and 2: shown, then fixed (a stop check between prefill runs; each ring's last 511
   slots, about 10.5 MB, kept at the checkpoint and written back on a long rewind). Gate: a Think
   reply over 1,100 tokens and a follow-up, the ring file against today's.
   **Done on the Mac (2026-11-14, `agello-one` `6cfd1a28`).** Shown: a 3,096-position rewind found
   98 % of the window's bytes overwritten. The fix copies the rings (31.5 MB) just before the first
   run that would overwrite the point's window, not at the checkpoint: the prompt's last token is
   written by the first decode, and the V caches' groups of four slots are rewritten as a group
   fills (in full-length caches too), so a copy at the checkpoint would put stale values back.
   Replies under 1,024 tokens copy nothing. Two more ring hazards closed: matching tokens after a
   rewind are prefilled again (upstream skipped the reuse only for Artisan rings), and any other
   rewind past the window fails instead of reading overwritten slots. The gate as written can't
   judge it: the two files' replies part about 30 tokens into a long Think reply at the same
   window, from summation order, before any rewind; the follow-up's facts were right before and
   after the fix. Still to do: the iPhone run, and a stop timed during a long read.
2. The private pool for the 1,024-token prefill (the order below's item 4, now first), with
   `kLongWindow` lifted to 65,536. Gate: identical replies, the soak, peak ≤ 3.0 GB at 44K.
   **Done on the Mac (2026-11-14, build `889dea2b6618`).** The pool's log (`AGELLO_LOG_POOL`) at
   64K showed every graph borrowing: the large prefill took decode's buffers, and the 128-token
   prefill and verify took its own, so after a long prompt only 512 MB of its 2.2 GB could be
   freed. Now the graph whose positions input holds 512 or more positions (the 1,024-token
   prefill, at every window) gets buffers of its own and lends none. The freed buffers' pages
   are emptied first: three of its 89 buffers (both 256 MB ones and a 128 MB one) stay referenced
   from outside the pool after the rebind (a retain count of 3, not 2) and had kept 640 MB
   resident; who holds them is still open. `kLongWindow` is 65,536. The 128K file on the M6:

   | | 64K, 44K tokens | 32K, 21K tokens |
   | --- | --- | --- |
   | First token | 19.1 s (24.1 with 128-token runs) | 7.6 s (unchanged) |
   | Peak | 2.96 GB (1.68 with 128-token runs, 3.00 shared) | 1.91 GB (2.04 shared) |
   | After the prompt | 1.79 GB (1.68 with 128-token runs, 2.46 shared) | 1.22–1.56 GB (1.65–1.92 shared) |

   Replies identical to the shared pool's at both windows, with two long prompts in a row, so
   the rebuild is exercised. Freeing the executor's 1,024-row input buffers too (two masks of
   [1, 1, 1,024, window] floats) changed nothing: tried and dropped. Left: the phone's numbers
   with 1,024-token runs at 64K (probe 24, then a helper and an image), and the soak.
3. App groundwork: the window from the file (`ContextBudget.exportWindow` falls back to 32,003
   today), the reply reserve, the keep rule, a 64K rung with its own room threshold, and
   `DeviceProfile.maxContextTokens(model:appMemoryLimitBytes:)` (no caller) removed.
4. A file sent once: follow-ups send only the question while the conversation holds it.
5. The growth path, with scripted-engine tests (`growsWhenMessageAloneExceeds32K`,
   `historyAndWebNeverGrow`, `failedLoadAt64KRestores32K`, `chatSwitchQueuesBehindGrowth`,
   `keepRuleCountsFilledBytes`, and the rest of the plan's list).
6. Reading progress, stop and resume at a run boundary, `BackgroundWork` for long reads.
7. Rewind to the checkpoint on cancel; then B2; a level-4 run at 44K and 57K filled (C3 back in
   only if decode attention passes 20 % of a round; E6's second half for the 8.4 MB masks);
   D4 after the pool; the 64K quality gates.

**On the iPhone**: P0 and the gates of trains 1 and 2 at 32K; then the 64K numbers (first token
at 5K, 21K, 44K and 57K, cool and hot; the peak at 6.44 GB with a 44K prompt, a helper and an
image; sustained decode at 44K and 57K; the first 64K load). The decision: a peak under 4.5 GB
with 1,024-token runs makes 64K fixed and the growth path unnecessary; 4.5–5.1 GB keeps it
adaptive; over 5.1 GB with 128-token runs, or 44K tokens taking over 90 s, means no 64K. The
1.99 GB outside Metal at the end of the `web` suite is explained first (Track 0.4).

**First pass on the iPhone 17 Pro (2026-11-14, probe 24, `AgelloDeviceTests/WindowCostProbe.swift`)**:
the 128K file through the app's pipeline on build `190b8eb4f343`, crate records with three
unique needles, then a 300-word follow-up in the same chat. Above 32,768 the interim rule holds,
so 64K reads in 128-token runs; peaks are the engine alone (no helper, no image).

| Window | Prompt | First token | Peak | Needles | Follow-up decode |
| --- | --- | --- | --- | --- | --- |
| 32K, 1,024-token runs | 5,843 tokens | 4.1 s | 1.95 GB | 3/3 | 34 tok/s |
| 32K | 21,058 | 15.2 s (1,382 tok/s) | 2.02 GB | 3/3 | 32 tok/s |
| 64K, 128-token runs | 5,843 | 5.6 s | 1.53 GB | 3/3 | 38 tok/s |
| 64K | 24,730 | 28.6 s (865 tok/s) | 1.28 GB | 3/3 | 27 tok/s |
| 64K | 45,273 | 59.5 s (761 tok/s) | 1.40 GB | 3/3 | 22 tok/s |

Against the decision rule: 45K tokens in 59.5 s (under 90) and a 1.40 GB peak (far under 5.1)
keep 64K in; the 1,024-token peak at 64K waits for the private pool. Memory isn't the cost at
64K with 128-token runs, time is: those runs read 1.3–1.6× slower than 1,024-token ones, so the
pool is worth 15–20 s on a 45K read, and decode falls about a third from 6K to 45K tokens filled
(C3's case). Single runs in one order, the phone warm from an hour of suites: heat and fill are
confounded, so the decode figures need an interleaved run before they decide anything.

**Quality gates at 64K**: identity at ≤ 32K between the 64K and 32K engines; 48-digit copies at
0–95 % of 57K and across position 32,767→32,768, all exact; positions 65,519–65,535; a needle
table at 21K, 32K, 44K, 50K and 57K (at least 15 of 18 each; the whole-file cap goes where it
holds); the FP32-sums build within 1 of 18 at 57K; twenty real documents read whole against
section summaries (at least as good in 16, none worse on facts); a 10-fact history probe after
growth.

**Releases** (timing stays the maintainer's call): R1, train 1 with files sent once and the stop
check; R2, the ring/128K file at a true 32,768 with the rewind fix, the old file kept until the
new one validates; R3, the growth behind a build flag (the private pool may ride dormant); R4,
fixed 64K if the phone allows. R2 and R3 never ship together.

**Dropped**: the 96K and 130K probes and the reserve override, 128K budgets, windows above 65,536
in `calibrate` (`kLongWindow` stays as a guard above 64K). **Deferred**: F5, the fused kernel, D3,
G2, C2, B1, B5, A6, C1, a KV transplant across engines; F4 unless reads backgrounded on the phone
fail.

## The engine review, adopted (2026-11-14)

The maintainer allowed tearing the engine down where that's the better path; an independent
ground-up review and its follow-up (Claude Fable 5.2: `build/drafts/engine-rebuild-review-fable-2026-11-14.md`,
`engine-rebuild-followup-fable-2026-11-14.md`) concluded not to: decode reads memory at about 59
of 77 GB/s and prefill sits near the matrix units' ceiling, so a new engine would buy load time
(7–9 s to 1–2 s [E]), not tokens per second. Rebuild how attention gets its masks; gate the
speculative round on a replay test; patch the rest. Adopted, Mac first (the phone is available
only now and then; no Mac step depends on P0):

1. The buffer holder: three of the large prefill's freed buffers keep a third reference, most
   likely the delegate's input converters (a task outside the graph's nodes keeps its destination
   and source buffers, `converter.mm`); re-point or drop them at release. Gate the residency set's
   adds on residency being enabled: it collects every bound input and output buffer, never
   removed.
2. The GPU options read and parsed on every Invoke (`delegate_metal.mm`): once, behind a switch.
3. A GPU graph dump and the pool's tenants; the peak against fill (5K, 21K, 44K).
4. Mask bounds: per-row `[rows, 4]` int32 `{ring_start, ring_len, lin_start, lin_end}` applied in
   the Q·Kᵀ epilogue, replacing the CPU-filled float masks, the bool mask and the mask node's
   second score tensor; ring wrap by a compare, linear loop bounds on global layers. Gate: identical
   replies, a ring-wrap prompt and an image prompt. Estimated 0.5–0.75 GiB less pool and 0.27 GiB
   less outside it at 64K; the phone's peak with a helper and an image under 4.5 GB [E].
5. Writers bounded by the filled length (the peak follows fill, not window), tile skipping in the
   ring files' local layers, padded rows skipped (time only).
6. The drafter's global read windowed (exact: verify decides), acceptance measured.
7. A replay harness: a reply's rounds replayed back to back with one wait, the ceiling of a
   GPU-resident round; under about +8 % sustained on the phone, the resident round is dropped.

On the iPhone when it's free: P0 with a System Trace, step 2's peak with a helper and an image,
the emptied buffers' footprint drop, the replay ceiling cool and after ten minutes, identical
replies for each switch. Decided there: the resident round, C3 and zero-skipping, a fused local
kernel (only above 10 % of a chunk), fusion for memory (only above 4.5 GB). Withdrawn by the
review: purgeable state as a trap (it works on buffers nothing runs on), decode's eight idle
128 MB buffers as a memory item (never touched), the row bound as a memory item.

## Order of work, revised (2026-11-14)

Adopted by the maintainer on 2026-11-14 after this session's Mac measurements and an independent
review (Claude Fable 5.2; the full text is in `build/drafts/roadmap-review-fable-2026-11-14.md`).
It replaces the phase order below, which stays as the record of the original plan; the estimates
there predate the measurements.

**On the Mac, now**

1. Two release candidates, built and gated, not published (release timing is the maintainer's
   call): train 1, everything bit-identical on today's file (A1, E7, A2 and its fix, E1, D1's first
   step, E4, E6, the pool's lending rule and the large prefill's free-and-rebuild, D2's slices);
   train 2, the ring file, then the 128K file. Gate per train: identical replies and every suite.
2. Tests for the pool's free-and-rebuild (`MD/metal/memory_manager.mm`): 1,024-token prefill →
   decode → prefill with a stop mid-prefill, a helper snapshot, an image and an engine release in
   between; a 200-turn soak asserting a flat footprint.
3. The ×V tile (16×512: −2.8 % first token at 21K, replies identical) confirmed on the bench;
   score slices chosen by the 128K peak (256 MB kept).
4. A private pool for the 1,024-token prefill, freed whole after each long prompt, so a 64K window
   can use 1,024-token chunks (the peak at 128K likely stays too high for them).
5. B2, drafts copied from the context (prompt lookup), the largest decode gain the Mac can
   measure: up to ~1.6× on summaries, edits and file answers.
6. B4 (speculative decoding for JSON helpers, every Search message waits on one), then B3
   (Regenerate with speculative decoding; changes seeded replies).
7. G1 now: unknown chip names fall to Apple1 (`MD/common/gpu_info.cc`), which turns the matrix-unit
   kernels off; families from `supportsFamily`, unknown chips to the newest family.
8. App groundwork: `DeviceProfile` memory rules (KV per position with rings, the 6.44 GB limit,
   E9), a smaller reply reserve for long windows, D4's chunking threshold re-fit, F4's design, A3
   written (exact; measured on the phone).

**On the iPhone**

9. P0 in one session: level-4 kernels, a System Trace, stream-read bandwidth, the jetsam limit per
   run, ABBA case order in `phone-bench.sh`.
10. Train 1's gate, with A1's real test (does the 9.5 ms host side move?) and the `memory` suite at
    6.44 GB.
11. Sustained decode (Track H): ten minutes, tok/s per minute, the verify run's GPU time as the
    thermometer; whether 60 fps streaming costs GPU time.
12. A3, A4, A5 decided from the trace (the track capped at about +10 %; A5's ICB path is off for
    graphs with external mutable tensors).
13. D1's second step and the tile shapes re-tested on the A19 Pro.
14. Train 2, then 64K with gates 2–5; C1 only with more than 15 % bandwidth headroom.

**Dropped or deferred**: the head-size-512 fused attention kernel and D3 (attention runs near the
M6's matrix-unit ceiling, D2 regime row), G2, F5, C2, B1, B5 (unless B2 shows long accepted runs),
A6 (until the iPhone's kernel shares), C3 and F3 (unless 128K becomes a product window), 128K as a
default window.

**Missing until now**: F4 (the KV cache on flash) is a prerequisite for windows above 32K, since
the phone has no GPU in the background and a long prefill dies when the user leaves; model-file
migration (an on-device graph patch checked by sha256 instead of a new download, and the cold
weight-cache rebuild measured); a stronger 128K quality attribution (INT8 KV, the rotary
emulation, positions past 98K); an energy figure beside tok/s; a rollback path for a runtime and
model-file pair; interaction tests (backgrounding mid-prefill with a pending pool release, a memory
warning during a helper snapshot).

**A20 Pro**: notes only, kept in Track G ("Notes for the iPhone 18 Pro") until the maintainer has
one; the plan targets the iPhone 17 Pro.

## Order of work (original, 2026-11-13)

| Phase | Contents | Why first |
| --- | --- | --- |
| P0 | Track 0 | Settles the figures the rest estimates |
| P1 | A1, A2, A3 (in-place scan), E1, E7, E8, E9, G1, D4 | Exact or near-exact, small, and E1 alone frees more memory than anything but the rings |
| P2 | D1, then D2 and D3 | Prefill on the accelerators; D2 also removes the context-sized buffers (E3) |
| P3 | A4, A5, A6, C1, C2, B1 | The decode pipeline and kernels |
| P4 | E2, E4, E5, E6 | The memory layout that 64K and 128K need |
| P5 | F1, F2, F3, F4, C3, then the gates; 64K first, then 128K | The full window |
| P6 | B2, B3, B4, B5, F5, G2 | Larger or quality-sensitive work |
| P7 | Track G's notes for the iPhone 18 Pro | When the maintainer has one |

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
