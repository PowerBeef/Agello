# The backend: our own runtime

A plan, from the maintainer's direction of 2026-11-10. Where it stands (2026-11-11, the Mac free
again): B0 is done, B1 is written and passes on the Mac with its iPhone runs owed, the Mac's
half of B4 is measured ("The ledger", below), and B2 is done on a local branch (the runtime
builds from one repository). B3 to B6 aren't started. What's left to run, in
order, is in [ROADMAP.md](ROADMAP.md#next), "When testing is available again".

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
| **B0** (done 2026-11-11) | Land the measuring instruments: C7 of [CLI.md](CLI.md), the probes inside the runtime. | The new build's replies are identical to the shipped build's and its speed is inside the noise; the probes show in a run. |
| **B1** (written 2026-11-11; the iPhone runs are owed) | The app sheds its two spare paths (below). | The unit tests pass natively and on the iPhone, with `inference`, `files`, `web`, `thinking` and `ui` on the iPhone. |
| **B2** (done 2026-11-11, local branch `agello-one`) | One repository: LiteRT and ML Drift imported at the pinned commits as folders, the build reading them in place of the archives. No source changes. | Replies identical to the build before the move, speed inside the noise, and a kernel edit rebuilds without a pin. |
| **B3** | Prune to what the Apple build compiles: other platforms, other GPU APIs, vendor NPUs, converters, the other bindings and build systems, and the path that runs the language model on the CPU. | The same check as B2, with the file count before and after recorded. |
| **B4** (the Mac's half done 2026-11-11) | The baseline: a noise run on a quiet Mac, the bench on the iPhone, and a ledger of what each later change bought. | Both baselines are committed with their noise bands. |
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

As built (2026-11-11):

- The load ladder is two rungs, multimodal then text-only, on the GPU. The last rung gets a
  second try whatever the error; a load that still fails is reported. The embedder loads on the
  GPU, tried twice, and search by keywords covers a failure as before.
- `EngineCache` keeps this build's two folders (`kv-all-<id>`, `embedding-<id>`) and deletes
  everything else in its root. An installed app's cache keeps its name, so nothing recompiles.
- Reply stats come from the runtime's telemetry alone; benchmark mode is never on for a chat.
- Settings saved with a `backendPreference` decode and the key is ignored (a unit test holds it).
- Probe 14 stays, as the guard that the weights are one copy for every window. Probe 6 lost
  its CPU reference. The command line lost `--backend`. `Vendor/refresh-litert-lm.sh` is gone,
  its copying folded into `Vendor/use-release-litert.sh`.
- The image and audio encoders still run on the CPU: that's a B5 thread, not a fallback.
- Checked on the Mac: the app and all its test targets compile for the iPhone, 261 unit tests
  and the 23 `inference` scenarios pass natively, and the bench's replies are identical to the
  app's before the change. Not yet run on the iPhone.

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

As built, B2 (2026-11-11), on the local branch `agello-one` of the runtime's checkout
(`../agello-arms/next/LiteRT-LM`, commit `e3c93749`; nothing pushed, nothing changed on GitHub):

- LiteRT is in `agello/litert` (7,801 files) and ML Drift in `agello/ml_drift` (877), exported
  at the commits the release pinned and checked identical, file by file, to the two archives
  Bazel had downloaded for it. The `WORKSPACE` reads the folders (`local_repository`).
- Export with Git LFS off (`GIT_LFS_SKIP_SMUDGE=1` and the filter unset): a plain `git archive`
  of LiteRT downloads Google's prebuilt libraries (about 230 MB) in place of their pointers.
  That happened once here, and the files and the LFS objects were removed.
- The build stamp reports the two as in tree with the commit they came from; the build id
  follows this repository's commit alone. First build from the folders: 145 s, most of it from
  Bazel's disk cache, since the sources are the same bytes.
- An edit to `ml_drift/common/kernels/fully_connected.cc` rebuilt the framework in 6 s (26
  actions) with a new build id and no pin; restoring the file gave back the same binary.
- The checkout holds 10,348 files now: the pruning (B3) starts from there.

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
   quiet Mac, five rounds, with the Claude session that started it idle (a session streaming
   output takes the GPU: "The ledger"). Read the medians. A change inside the noise band isn't
   a change.
3. **Quality:** `compare.txt` counts the replies identical to the base. For the others,
   `scripts/cli-replies.py` shows where each parts, and Claude reads both sides, with the answer
   checks' results beside them. The verdict and its reasons go in the ledger. "Worse" stops the
   change.
4. **Confirmation, on the iPhone:** the bench against its baseline, and the suites the change
   touches. Mac numbers are a lead: the phone's speed, heat and memory decide.

## The ledger

What each change bought, from B4 on. Mac figures are the M6's, through the app's engine
(`scripts/cli-bench.sh`), 32,000-token window, speculative decoding on, medians over the rounds.

**The Mac's baseline (2026-11-11):** the shipped runtime, `agello-next-20261024` (build
`99b8f5f6ea49`), with the app's code after B1. Five rounds, the build against itself
(`build/cli/runs/noise`).

| Case | Prompt tokens | Prefill tok/s | Decode tok/s | First token |
| --- | --- | --- | --- | --- |
| `explain` (1,503 tokens written) | 1,125 | 1,947 | 91.8 | 0.30 s |
| `email` (159) | 266 | 1,065 | 97.1 | 0.30 s |
| `file-report` (172) | 4,879 | 2,531 | 105.7 | 2.0 s |
| `file-report`, second message (49) | 4,647 | 2,242 | 114.3 | 2.1 s |

**The noise band:**

- Two copies of the build agree to −0.2 % on decode and +0.3 % on prefill (geometric means of
  the medians), and to within 0.6 % and 1.4 % on every case.
- Single runs don't: one in five is more than 5 % under its case's median, by up to 14 % on
  `email`, whose decoding lasts 1.6 s. So five rounds and the medians, and the long cases
  (`explain`, `file-report`) for decode.
- The desktop's own GPU use sets the speed. With the GPU at 0 to 1 % before a run, `email`
  decodes at 101.7 tok/s; at about 14 % (a still desktop), 100.5; while a Claude session
  streams and edits in the app (15 to 22 %), 86 to 97. The first noise run, started with the
  session working, read +11.7 % between the two copies on `email` (`build/cli/runs/noise-session-busy`).
- Under these conditions a change of 1 % in the geometric mean is the smallest worth believing.

**Changes:**

| Date | Change | Replies | Decode | Prefill | Verdict |
| --- | --- | --- | --- | --- | --- |
| 2026-11-11 | B0: the probes (`agello-next` `3118b5d4`, build `d5ed12808214`), 3 rounds | 4 of 4 identical | −0.0 % | +1.2 % | Same output; no cost at the everyday levels. Not released. |
| 2026-11-11 | B1: the app without the CPU backend and Google's-binary code (same runtime) | 4 of 4 identical to the app before it | inside the noise | inside the noise | Same output. The iPhone runs are owed. |
| 2026-11-11 | B2: one repository (`agello-one` `e3c93749`, build `8998da09bac2`), 5 rounds | 4 of 4 identical | +0.9 % | −1.9 % | Same output; inside the noise of a run that other work on the Mac disturbed (7 of 40 records flagged, the GPU at 96 to 98 % before two of them). Not released. |

The iPhone's baseline is the bench's (`scripts/bench/baseline.json`); a new one is due once B1
has passed there.

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
