# The backend: our own runtime

A plan, from the maintainer's direction of 2026-11-10. Nothing in it is built yet: the Mac was
busy that day and the maintainer chose to wait for it, B1's code included. The order of work for
when the Mac or the iPhone is free again is in [ROADMAP.md](ROADMAP.md#next), "When testing is
available again".

Agello's backend stops being Google's LiteRT-LM with patches kept close to upstream. It becomes
our own code base, a hard fork, with one job: run our model file on Apple GPUs under iOS 27 as
fast as the hardware allows, at the quality the model has today.

## The direction

- **One backend, on the GPU.** We don't measure against Google's runtime or the CPU backend any
  more, and neither is built, cached or kept on this Mac as a reference. Both are behind ours in
  speed at the same quality, and that question is closed.
- **The harness judges performance.** A change is measured between two builds of our runtime:
  `scripts/cli-bench.sh` on this Mac ([CLI.md](CLI.md)) for the lead, the bench on the iPhone
  ([HARNESS.md](HARNESS.md)) for the confirmation.
- **Claude judges output quality, by reading.** Replies that are identical token for token need
  no judging. Where a change moves them, Claude reads both sides and gives the verdict: the same,
  better or worse. The answer checks (does the code run, did the reply end by itself) are
  evidence for that reading, not the verdict.
- **One hardware class.** iOS 27, iPhones with 12 GB (A19 Pro and later), and the Apple silicon
  Macs the tools run on. Code for anything else is weight.

## The maintainer's choices (2026-11-10)

| Question | Choice |
| --- | --- |
| Shape | **One repository.** Our LiteRT and ML Drift code moves into the runtime's repository as plain folders, only what the Apple build compiles. One commit is one runtime. |
| Upstream | **A read-only source.** No more merges or rebases. Google's repositories stay as read-only remotes; a fix, or support for a new model, is ported by hand when we want it. The #3913 thread is answered only if someone replies to us. |
| The app | **Both spare paths go:** the code for Google's binary, and the CPU backend (its setting and the fallback after a failed GPU load). The app runs our runtime on the GPU, or says clearly that it couldn't load and tries again. |

## Where it starts from

- Three repositories, each a GitHub fork: `PowerBeef/agello-litert-lm` (1,670 files, 34 commits
  of ours on the base `agello-base-20261013`), `PowerBeef/LiteRT` (7,802 files, 12 commits of
  ours) and `PowerBeef/ml-drift` (877 files, 8 of ours). The runtime's `WORKSPACE` pins the other
  two by commit and archive checksum, so a kernel change means a push, a new checksum and a
  re-pin before the runtime sees it.
- Most of those files serve other platforms: Android, Windows, Linux and the web, OpenCL, OpenGL
  and WebGPU beside Metal (ML Drift's Metal folder is 38 files of 877), vendor NPUs, converters,
  the Kotlin, JavaScript and Python bindings, a CMake build beside Bazel.
- The app ships release `agello-next-20261024` (build `99b8f5f6ea49`) with our patched model
  file, `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope`. The runtime serves that file, its MTP
  drafter and EmbeddingGemma, and nothing else.
- What the Mac command line measured on the M6 (shipped runtime, 32K window): 90 to 115 tok/s;
  a decode run is 72 % `fc1x1_int4_weights`; a prefill run is 43 % the int8 convolution and
  28 % `weights_convert_uint4_to_int8`; a decode step is 86 % the GPU's MTP verify run, and speed
  follows the share of drafts MTP keeps (58 to 71 %).
- **The CPU still does real work in the app.** The image and audio encoders run on the CPU
  (`ChatEngine.makeEngine`), and so does everything around the GPU: the tokenizer, sampling, the
  grammar for JSON. "GPU only" means the language model and the embedder; the CPU kernels the
  encoders use stay in the runtime until the encoders move (B5).

## Milestones

Each ends with a commit; in the runtime's repository, pushes and releases wait for the
maintainer's go, as before.

| | What | Done when |
| --- | --- | --- |
| **B0** | Land the measuring instruments: finish C7 of [CLI.md](CLI.md) (the probes are written and the runtime builds with them; the comparison with the shipped build was interrupted). | The new build's replies are identical to the shipped build's and its speed is inside the noise; the probes show in a run. |
| **B1** | The app sheds its two spare paths (below). | The unit tests pass natively and on the iPhone, with `inference`, `files`, `web`, `thinking` and `ui` on the iPhone. |
| **B2** | One repository: LiteRT and ML Drift imported at the pinned commits as folders, the build reading them in place of the archives. No source changes. | Replies identical to the build before the move, speed inside the noise, and a kernel edit rebuilds without a pin. |
| **B3** | Prune to what the Apple build compiles: other platforms, other GPU APIs, vendor NPUs, converters, the other bindings and build systems, and the path that runs the language model on the CPU. | The same check as B2, with the file count before and after recorded. |
| **B4** | The baseline: a noise run on a quiet Mac, the bench on the iPhone, and a ledger of what each later change bought. | Both baselines are committed with their noise bands. |
| **B5** | The performance work (below), one thread at a time. | Each thread: a gain outside the noise on the Mac, confirmed on the iPhone, with a quality verdict. |
| **B6** | Releases and instructions from the one repository: the release and vendoring scripts, the fork's reference, the `agello-litert-update` skill, this repo's docs. | A release built from the one repository ships in the app after its iPhone gate. |

B0 and B1 don't depend on each other. B2 comes before B3, and B4 before any B5 thread is judged.

### B1. What leaves the app

- **Google's binary.** The cache folders per context size and `EngineCache.runtimeBuildID` as an
  optional, helpers that empty the chat's conversation and the reseed after them
  (`runtimeKeepsSessions`, the 60 s helper delay), reply stats from benchmark mode
  (`RuntimeTelemetry.replacesBenchmark`), `Vendor/refresh-litert-lm.sh`, and the tests and probe
  notes that exist only for it (probe 14's per-size caches). The benchmark screen's line quoting
  Google's published speeds goes too.
- **The CPU backend.** `BackendPreference` and its control in Settings → Advanced, the CPU rungs
  of the load ladder (`InferencePlanner.attempts`), and the embedder's CPU retry. A GPU load that
  fails is retried, then reported; the text-only rung stays, since it's about the model file,
  not the backend.
- **Kept on purpose:** the memory-driven step-down (32K, 16K, 8K) and the helper path that
  releases the chat's conversation when memory is short. Those are about the iPhone, not about
  Google's runtime.
- `InferenceOptions` is decoded from saved settings: the stored `backendPreference` key must
  keep decoding (CLAUDE.md, "Settings decoding").
- The rules in `agello-inference-rules` are rewritten in the same commit: several describe
  Google's behaviour as a live case.

### B2 and B3. One repository

- **Import as it is first, prune second.** B2 copies the two trees at the commits the release
  pins and points the build at the folders, so the first build from one repository compiles the
  same sources. Only then does B3 delete, a group at a time, with the identical-replies check
  after each group. A wrong deletion shows as a build error or a changed reply, in the group
  that caused it.
- **What to keep is read from the build, not guessed:** the files the framework's targets
  depend on (`bazel query`), plus licences and notices.
- **History.** The import is one commit that names the source commits; the three old
  repositories keep the full history and stay reachable. Our comments on #3913 link into them
  (the `research/3913` tag, `tools/model-surgery/patch_rope.py`): those tags and paths must keep
  resolving, so nothing is deleted on GitHub without checking the links.
- **Licence.** Everything stays under Apache 2.0, with Google's notices kept and our changes
  stated (section 4), as today.
- **On GitHub, on the maintainer's go only:** which repository carries the one code base and
  under what name, its default branch, and archiving the other two. Until then the work lives on
  a local branch.

### B5. The performance work

Ordered by what the measurements say is largest. Each thread starts by measuring its own share
again on the baseline, since these figures come from a busy Mac.

1. **The decode kernel.** `fc1x1_int4_weights` is 72 % of a decode run: the one kernel to
   specialize for the A19 Pro's GPU and its Mac siblings.
2. **Weight conversion out of the hot path.** `weights_convert_uint4_to_int8` is 28 % of a
   prefill run. With one model file to serve, the conversion can move to load time, to the
   cache, or into the file itself.
3. **MTP.** A decode step is mostly the verify run, and speed tracks the drafts kept. Two
   levers: a cheaper verify run, and a drafter schedule that keeps more.
4. **The model file as part of the runtime.** One file means the runtime can be shaped to its
   graph: layouts and constants fixed ahead of time, work moved into the file by
   `tools/model-surgery`, as the rotary fix already is.
5. **One hardware class.** Drop the kernel variants and fallbacks for older Apple GPU families,
   then survey what Metal on iOS 27 offers that the code doesn't use, from Apple's documentation
   rather than from memory.
6. **Load time and memory.** Shader and pipeline compile time (C7 measures it), cache contents,
   the footprint at 32K: memory given back is room for the window on the iPhone.
7. **The encoders on the GPU.** Images and audio are encoded on the CPU today.
8. **Heat on the iPhone.** Late in long replies the phone slows about 20 % and the Mac doesn't,
   which points at heat; unconfirmed on the phone.

### How a change is judged

1. **Build** the change as the `next` build beside the shipped one.
2. **Performance, on the Mac:** `scripts/cli-bench.sh release next`, builds taking turns, on a
   quiet Mac. A change inside the noise band isn't a change.
3. **Quality:** `compare.txt` counts the replies identical to the base. For the others,
   `scripts/cli-replies.py` shows where each parts, and Claude reads both sides, with the answer
   checks' results beside them. The verdict and its reasons go in the ledger. "Worse" stops the
   change.
4. **Confirmation, on the iPhone:** the bench against its baseline, and the suites the change
   touches. Mac numbers are a lead: the phone's speed, heat and memory decide.

## What it costs

- **Google's work stops arriving by itself.** A new Gemma, a new file format or an upstream fix
  is ported by hand, into code that will look less and less like theirs.
- **The first two steps buy no speed.** B2 and B3 are there so that every later change is one
  commit in one place.
- **B1 changes shipping code.** Without the CPU fallback, a phone whose GPU load fails gets an
  error where it used to get a slow answer. On the 12 GB floor that should be rare; the load
  log will say if it isn't.
- **Disk.** A runtime build needs about 8 GB of Bazel output while it's worked on; the project
  budget (30 GB, 50 GB free) is tight around it.
