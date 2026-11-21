# The backend: our own runtime

A plan, from the maintainer's direction of 2026-11-10. Where it stands (2026-11-15): B0, B1 (its
iPhone suites passed on 2026-11-12), B2 and B3 are done. The runtime is one repository,
`PowerBeef/agello-litert-lm`, with one branch, `main`, since 2026-11-15, and one checkout on this
Mac, `../LiteRT-LM`. Both halves of B4 are done: the Mac's ("The ledger", below) and the iPhone's, the bench on
the fork's `c137900d`, accepted as the baseline on 2026-11-17. B5, the performance work
([PERFORMANCE.md](PERFORMANCE.md)), is under way. B6 is in part: the first release built from the
one repository, `agello-one-20261115` (fork `6da75396`, build `0c749789100a`), ships in the app
since 2026-11-15 (commit `39daed1`), after the iPhone comparisons of that build (the ledger).
Still missing for B6: the fork's reference pages describe the three-repository layout in places,
and the phone suites weren't rerun on the vendored package (the maintainer's choice: it is the
build the comparisons ran). What's left to run, in order, is in
[ROADMAP.md](ROADMAP.md#current-status), "Current status".

Agello's backend stops being Google's LiteRT-LM with patches kept close to upstream. It becomes
our own code base, a hard fork, with one job: run our model file on Apple GPUs under iOS 27 as
fast as the hardware allows, at the quality the model has today.

## The direction

- **One backend, on the GPU.** We don't measure against Google's runtime or the CPU backend any
  more, and neither is built, cached or kept on this Mac as a reference. Both are behind ours in
  speed at the same quality, and that question is closed.
- **The harness judges performance.** A change is measured between two builds of our runtime:
  `scripts/cli-bench.sh` on this Mac ([CLI.md](CLI.md)) for the lead, and on the iPhone
  `scripts/phone-bench.sh` (the same comparison, the builds installed in turns) with the bench
  ([HARNESS.md](HARNESS.md)) for the confirmation. When the Mac is busy, `phone-bench.sh` can
  lead: the Mac only builds for it.
- **Output quality is judged by reading.** Replies that are identical token for token need
  no judging. Where a change moves them, read both sides and give the verdict: the same,
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
- The app ships release `agello-one-20261115` (build `0c749789100a`, since 2026-11-15; before it
  `agello-next-20261024`, build `99b8f5f6ea49`) with our patched model file, `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope`. The runtime serves that file, its MTP
  drafter and EmbeddingGemma, and nothing else.
- What the Mac command line measured on the M6 (shipped runtime, 32K window): 90 to 115 tok/s;
  a decode run is 72 % `fc1x1_int4_weights`; a prefill run is 43 % the int8 convolution and
  28 % `weights_convert_uint4_to_int8`; a decode step is 86 % the GPU's MTP verify run, and speed
  follows the share of drafts MTP keeps (58 to 71 % on the coding prompt, 44 to 60 % on the
  bench's cases, and 45 to 57 % on the iPhone).
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
| **B1** (done 2026-11-12: `unit`, `inference`, `files`, `web`, `thinking` and `ui` on the iPhone) | The app sheds its two spare paths (below). | The unit tests pass natively and on the iPhone, with `inference`, `files`, `web`, `thinking` and `ui` on the iPhone. |
| **B2** (done 2026-11-11 on the branch `agello-one`: local until 2026-11-12, then on GitHub; the fork's `main` since 2026-11-15) | One repository: LiteRT and ML Drift imported at the pinned commits as folders, the build reading them in place of the archives. No source changes. | Replies identical to the build before the move, speed inside the noise, and a kernel edit rebuilds without a pin. |
| **B3** (pruned 2026-11-11; in release `agello-one-20261115`, whose iPhone comparison stands for the owed speed run) | Prune to what the Apple build compiles: other platforms, other GPU APIs, vendor NPUs, converters, the other bindings and build systems, and the path that runs the language model on the CPU. | The same check as B2, with the file count before and after recorded. |
| **B4** (done: the Mac's half 2026-11-11, the iPhone's 2026-11-17) | The baseline: a noise run on a quiet Mac, the bench on the iPhone, and a ledger of what each later change bought. | Both baselines are committed with their noise bands. |
| **B5** (approved 2026-11-13: [PERFORMANCE.md](PERFORMANCE.md); under way: train 1, the sparse KV caches and the window read from the model file done and released in `agello-one-20261115`, 2026-11-15) | The performance work (below), one thread at a time. | Each thread: a gain outside the noise on the Mac, confirmed on the iPhone, with a quality verdict. |
| **B6** (in part 2026-11-15: release `agello-one-20261115` built from the one repository and vendored; left: the fork's reference pages) | Releases and instructions from the one repository: the release and vendoring scripts, the fork's reference, the `agello-litert-update` skill, this repo's docs. | A release built from the one repository ships in the app after its iPhone gate. |

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
  keep decoding (AGENTS.md, "Settings decoding").
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
  app's before the change. On the iPhone it passed on 2026-11-12 (the B1 row above and the ledger).

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
- **On GitHub (the maintainer's go, 2026-11-15):** `PowerBeef/agello-litert-lm` carries the one
  code base on one branch, `main`: the runtime (`agello-one`) with the docs, bench and model tools
  of the old `agello` branch merged in. Google's copy of `main` and the branches `agello-next`
  and `agello-one` are deleted; `agello` was renamed, so GitHub redirects links to it; the
  releases keep their tags. `PowerBeef/LiteRT` and `PowerBeef/ml-drift` keep our changes as their
  one branch, `main`, and are archived. On this Mac the one checkout is `../LiteRT-LM`.

As built, B2 (2026-11-11), on the local branch `agello-one` of the runtime's checkout
(`../agello-arms/next/LiteRT-LM` then, `../LiteRT-LM` since 2026-11-15; commit `e3c93749`; on GitHub since 2026-11-12, without the import's Google prebuilt LFS files, ROADMAP "State left on this Mac"):

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

As built, B3 (2026-11-11), three commits on `agello-one` (`7e4d9b8d`, `a9553bde`, `edb2c7db`):

- **10,348 files became 3,548.** What the build needs was read from Bazel: `cquery` of
  `//agello:CLiteRTLM` for the iPhone and Mac slices (2,246 files of ours), plus what the
  `WORKSPACE` names itself (patches, build files for outside libraries, the Cargo manifests),
  the Swift wrapper, the build scripts and every licence.
- **Three groups, each built and checked** for identical replies on the bench (4 of 4 each):
  1. 1,171 files: the Kotlin, Python, JS and omni trees, CMake, CI, upstream docs, tools.
  2. 4,751 files in folders the build never enters: LiteRT's vendor back ends (Qualcomm,
     MediaTek, Google Tensor, OpenVINO, Exynos) with their `WORKSPACE` declarations, the other
     TFLite delegates, the converter, the other bindings, ML Drift's OpenCL and OpenGL back
     ends, samples, tests in folders of their own.
  3. 878 unused sources, headers and scripts beside used ones (WebGPU, Android, Windows,
     NNAPI, the prebuilt library pointers).
- **Proved with a build from scratch.** Bazel's cache would hide a deleted header that some
  file includes without declaring it, so the last check was `bazelisk clean` and a build with
  no cache: 11,394 actions in 536 s, and it passes. Do the same after any later prune.
- **Left for later, on purpose:**
  - 1,172 test files beside code that's kept. Many no longer build (their test data and helper
    folders are gone). Whether the runtime keeps unit tests of its own is a choice to make.
  - Build files still declare targets for files that are gone (other platforms, tests), so
    `bazel build //...` fails while the framework builds. They want a pass of their own.
  - The CPU path for the language model inside the binary. The image and audio encoders still
    run on LiteRT's CPU kernels, so those stay until the encoders move to the GPU (B5).
  - The outside libraries the `WORKSPACE` still fetches for other platforms (Android's SDK and
    NDK rules among them).
- **Owed, then moot (2026-11-15):** the five-round speed run on an idle Mac (`ROUNDS=5
  scripts/cli-bench.sh release next -- --only explain,email,file-report`), on the build stamped
  with the last commit, `9128dc9c2055`. The one-round checks aren't speed readings, and the run
  of 2026-11-11 was too disturbed to count (the ledger has it). That build is deleted, and B3 is
  in release `agello-one-20261115`, whose iPhone comparison against the previous release covers
  it (the ledger).

### B5. The performance work

The detailed plan is [PERFORMANCE.md](PERFORMANCE.md) (approved 2026-11-13): what a reply costs on the
iPhone 17 Pro, what the A19 Pro and A20 Pro offer, and eight phases over seven tracks, measuring
first, up to the model's full 131,072-token window. The threads below were its starting list;
each is one of its rows now (1: C1; 2: D1; 3: Tracks A and B; 4: B1, E2, F1; 5: G1 to G3;
6: E1 to E9, G4; 7: left for later, E1 frees the image encoder's memory meanwhile; 8: Track H;
9: A1 and measurement 0.2).

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
9. **The host's side of a decode step** (found 2026-11-11 by `scripts/cli-load.py`). In one run
   in four on an idle Mac the GPU's time per step is unchanged and the host's goes from 1.6 ms
   to 5 to 8 ms: the same work costs the process three times the CPU time (0.82 s against
   0.26 s for one `email` reply), which reads as the scheduler running the runtime's threads on
   efficiency cores. It costs up to 21 % of decode speed on a short reply. To check: which
   quality of service the runtime's threads ask for, whether the iPhone shows the same two
   speeds (it would look like the phone's unexplained slow replies), and what pinning the
   decode thread to the performance cores' class gives.

### How a change is judged

1. **Build** the change as the `next` build beside the shipped one.
2. **Performance, on the Mac:** `ROUNDS=5 scripts/cli-bench.sh release next`, builds taking
   turns. The run checks the Mac is quiet before it starts (`scripts/mac-ready.sh`), reads from
   its records which runs the Mac's load disturbed, adds rounds while a case lacks undisturbed
   ones, and compares on those ([CLI.md](CLI.md), "System load"). Leave the Mac alone while it
   runs, the agent session included. Read `compare.txt` and `load.txt`. A change inside the
   noise band isn't a change, and a build disturbed more often than the other is to be looked
   into, not filtered.
3. **Quality:** `compare.txt` counts the replies identical to the base. For the others,
   `scripts/cli-replies.py` shows where each parts, and both sides are read with the answer
   checks' results beside them. The verdict and its reasons go in the ledger. "Worse" stops the
   change.
4. **Confirmation, on the iPhone:** `scripts/phone-bench.sh release next` (the same reading as
   step 2, with heat where the Mac has load: [HARNESS.md](HARNESS.md), "Runtime builds on the
   iPhone"), the bench against its baseline, and the suites the change touches. Mac numbers are
   a lead: the phone's speed, heat and memory decide. With the Mac busy, the phone's comparison
   can come first: the Mac only builds the two apps.

## The ledger

What each change bought, from B4 on. Mac figures are the M6's, through the app's engine
(`scripts/cli-bench.sh`), 32,000-token window, speculative decoding on, medians over the rounds.
The Mac's records the rows cite under `build/cli/runs/` were deleted on 2026-11-15: the numbers
here are the record. The iPhone's, under `build/phone/runs/`, are kept.

**The Mac's baseline (2026-11-11):** the runtime shipped then, `agello-next-20261024` (build
`99b8f5f6ea49`), with the app's code after B1. Five rounds, the build against itself
(`build/cli/runs/noise`, deleted 2026-11-15).

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
- **Since the harness reads the load** (2026-11-11, [CLI.md](CLI.md), "System load"): 27 of that
  run's 40 records are undisturbed, and on those the two copies agree to 0.0 % on decode (each
  case's median within 0.6 %, intervals within 2.3 %) with the noise band at 1.1 %; prefill
  agrees to 0.6 %. Each build's best run of a case agrees to 0.2 % on decode.
- **Two different disturbances.** Other work on the GPU stretches the GPU's side of a decode
  step (up to three times, beside a process using it fully). The other stretches the host's
  side with the GPU's unchanged: the process's own CPU work runs about three times slower, in
  one run in four on an idle Mac, and a short reply loses up to 21 %. That one is a lead for
  B5, below.

**Changes:**

| Date | Change | Replies | Decode | Prefill | Verdict |
| --- | --- | --- | --- | --- | --- |
| 2026-11-11 | B0: the probes (`agello-next` `3118b5d4`, build `d5ed12808214`), 3 rounds | 4 of 4 identical | −0.0 % | +1.2 % | Same output; no cost at the everyday levels. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-11, 12 | B1: the app without the CPU backend and Google's-binary code (same runtime) | 4 of 4 identical to the app before it | inside the noise | inside the noise | Same output. On the iPhone (2026-11-12): `unit` 326 (1 skipped), `inference` 23/23, `files` 5/5, `thinking` 3/3, `web` 7/7 (its follow-up asked which gap was meant on the first run and answered 6 min 26 s on the rerun: the model over that run's pages, the history was there), `ui` 25 with one failure that wasn't B1's: `testLongSummarySurvivesBackgrounding` waited for a section-by-section summary, which the sample report hasn't needed since 32K; with the window held at 8K (`--uitest-window`) it passes. |
| 2026-11-11, 12 | B3: the pruning (`agello-one` `edb2c7db`, build `9128dc9c2055`) | 4 of 4 identical on the Mac, four times; 18 of 18 on the iPhone | iPhone: +0.1 % (email) and +0.2 % (file-report) on undisturbed runs; explain set by heat | iPhone: +2.7 % (email, a 266-token prompt) and +0.2 % (file-report); first token −1.5 % and −0.2 % | Same output and, where the phone stayed cool, the same speed. On the iPhone (`scripts/phone-bench.sh`, 3 rounds, 2026-11-12) the host's side of a decode step is the same on both builds (9.5 and 9.6 ms); explain lost up to 25 % on the GPU's side to heat while the phone said nominal, so its −3.3 % is the order the builds ran in, not the build. The Mac's five-round run of 2026-11-11 doesn't count (another project had the Mac: 27 of 40 records disturbed; best runs +0.8 % decode, −0.4 % prefill). Explain is settled by the Mac's run on a quiet Mac, or a phone run with a longer rest. Released in `agello-one-20261115` (2026-11-15), whose iPhone comparison covers it. |
| 2026-11-11 | B2: one repository (`agello-one` `e3c93749`, build `8998da09bac2`), 5 rounds | 4 of 4 identical | −0.1 % on the 21 undisturbed records of 40 (+0.9 % on all) | −1.9 %, on those as on all: inside prefill's band (2.9 % at most) | Same output and the same speed. Other work on the Mac disturbed the run (the GPU at 96 to 98 % before two records). Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | P1, A1 and E7 ([PERFORMANCE.md](PERFORMANCE.md)): the runtime's threads ask for the interactive quality of service; the CPU embedding tables keep one zero point (`agello-one` `4780b5c5`, build `3161b7599b48`), 5 rounds against B3 (`build/cli/runs/a1e7`) | 4 of 4 identical | +0.2 % (band 0.4 %) | −0.0 % | Same output and speed on a quiet Mac, whose host side is already 1.3 ms a step. The host's side slowed in 2 of B3's 20 runs (+4 %, +7 %) and in none of the new build's: consistent with A1, too few to count. A1's real test is the iPhone, whose host side is a steady 9.5 ms. E7: 41 MB less outside Metal (959 → 918 MB, median of 25 records), as estimated. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | P1, A2: the first token streams before the first speculative round (the executor hands the priming token back alone and runs its round in the next call; the detokenizer releases the first decode at once), `agello-one` `53a08cb1`, build `5ea349996252`, 5 rounds against A1+E7 (`build/cli/runs/a2`) | 4 of 4 identical | +0.2 % | +0.2 % (all records) | First token on `email` −10.3 % over all records (95 % interval −12.2 to −8.7 %, band 1.1 %), `file-report` −1.3 % and −1.4 %, `explain` (Think) unchanged: its first token is the thinking channel's. The undisturbed-only reading shows `email`'s prefill −8.9 %, an artifact: the base had one clean run of eight, its fastest ever. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | P1, E1: the vision encoder is created by the first image and released after it (`agello-one` `cd9775ed`, build `6ef45c6d1c55`), against A2 with `agello ask` (an image, two follow-ups) and the bench's `email` (`build/cli/runs/e1`) | identical (image and follow-ups) | — | — | Memory: after an image 3,774 MB against 4,384 (−610 MB), peak 3,843 against 4,384; a text-only reply 3,537 MB against 4,052 (−515 MB), since the encoder is never created. The image turn took 2.11 s against 2.30. On the iPhone the encoder's working memory was 1.2–1.5 GB: the `memory` suite will say what it gives there. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | P2, D1 first step: prefill runs of up to 128 rows read the INT4 weights in place, expanded to INT8 inside the kernel, instead of a conversion pass every run (`agello-one` `80c07920`, build `af3cb7416765`), 5 rounds against E1 (`build/cli/runs/d1a`) | 4 of 4 identical | −0.2 % | `email` +22.8 %, `explain` +9.1 %, `file-report` +0.8 % (all records) | First token `email` −16.7 %, `explain` −14.9 %. A 128-token run's kernels go from 79.9 to 56.2 ms at level 4 (the expansion adds 5 ms to the matrix products, the 22 ms conversion goes). 1,024-token runs, all of `file-report`, keep the conversion: tried on them too (build `feef06bc0f20`), the matrix products took 248.6 ms a run against 180.8 (each weight tile expanded once per 64 rows) to save a 30 ms pass, so the limit stays at 128. The native int8 × int4 product, prototyped on the M6 the same day (`agello/experiments/int4_mpp.swift`, `32123c8f`), is no faster than int8 there: 1,024-token runs keep the conversion (PERFORMANCE.md, D1). Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | P4, E2: ring-buffer local KV caches. The model file's 20 local caches get 1,536 slots (`tools/model-surgery/ring_kv.py`, fork `agello` `290a1eec`; sha256 `23551f43…2fa2b46e`), and the runtime runs them (`agello-one` `a44d5f25`, build `61c7aa5a57cd`: the update length for rings, window detection on position keys only, the value product's loop clamped). The ring file against the original through the same build, 3 rounds (`build/cli/runs/e2`) | 1 of 4 identical; the others part at near-synonyms ("would appreciate" / "am concerned") and read as good; checks 5/5 on both | −3.9 to +6.5 % (mixed, about the noise) | +4.4 to +19.0 % | Memory after each reply 850 to 870 MB less at the 32,000-token window (3,925 → 3,058 MB on `explain`, 4,340 → 3,510 on `file-report`), peak 1.45 GB less; first token −4 to −16 %. A 60-record rewrite decoding past the wrap is exact on both, and questions over 1,642- and 3,257-token logs are answered right. Found on the way: three runtime bugs that only rings reach (none changes the original model). Shipping it needs a release with these commits, the ring file on Hugging Face, and `ModelCatalog` and `DeviceProfile`'s memory rules updated: the maintainer's call. The runtime's part is released in `agello-one-20261115` (2026-11-15); the ring file wasn't published on its own: its rings are in the 128K file, which waits on the 64K quality gates. |
| 2026-11-13 | P4, F1, F2 and E3's interim: the full 131,072-token window. The ring file opened to 131,101 positions with the rotary split extended to 256 blocks (`tools/model-surgery/window_128k.py`, fork `agello` `72b715e3`; sha256 `1c2f8b03…f8b82a81`), and windows above 32K leave out the 1,024-token prefill (`agello-one` `3e60fafd`, build `cf1e947d6efd`), through `agello ask` at 21K to 91K tokens | 4 of 4 identical to the ring file's at 32K windows; at 91K tokens, 40- and 48-digit codes placed at 0, 40K and 75K copied exactly | Not measured (fidelity runs, the Mac not always quiet): 66–79 tok/s at 91K, 94–122 at 21K | 91K tokens in 63 s (1,450 tok/s in 128-token chunks), 44K in 24 s, 21K in 7.5 s (1,024-token chunks) | Peak footprint 3.06–3.17 GB at 91K (the guard is 8.59 GB), and 1.81 GB at a 64K window, below the 32K window's 3.04 GB since no 1,024-token buffers are built. Retrieval among 4,000 look-alike records falls with length: six crate questions at 5–95 % depth get 6/6 at 21K, 5/6 at 44K and 2/6 at 91K, the misses in the middle. A diagnostic build with 32-bit sums (not kept) gets 3/6 with the same kind of misses, and one miss sits at 18K, where the rotary math is the shipped model's: the model's own long-context limit, not the edit. Asked by record number instead of crate number, the model misses even at 21K. Out of reach through the app: messages past 98K tokens (the reply reserve is a quarter of the window), so positions past ~98K are untested on the GPU. Shipping it: a release, the file on Hugging Face (the maintainer's go), the catalog, the memory rules and the reply reserve for long windows. The runtime's part is released in `agello-one-20261115` (2026-11-15); the file isn't published (it waits on the 64K quality gates). |
| 2026-11-13 | P4, E4: a helper's snapshot of the chat copies the filled KV positions only (`agello-one` `37bdbbf5`, build `91a57edaa78b`): each cache's first step + 16 slots, in the buffers' own layout (checked on every buffer with `AGELLO_VERIFY_KV_PREFIX=1`), against F1 with `agello ask` (a 3.5K-token chat, the title and memory helpers, a follow-up) and the bench's `explain`, `email`, `file-report` (`build/cli/runs/e4`) | 4 of 4 identical, and both turns of the helper chat at 32K and 128K | +2.3 % (one round, inside the noise) | +3.5 % (one round) | A helper's save and restore move 202 MB instead of 1,835 MB at the 32K window (20 ms instead of 116), 121 MB instead of 2,210 MB at 131,072 (15 ms instead of 152). Peak footprint 3,921 against 4,683 MB at 32K, 3,240 against 4,211–4,255 MB at 128K. The app's keep rule (`DeviceProfile.keepsConversationAcrossHelpers`) still budgets a full-window copy: it can count filled positions only with a release that carries this. Released in `agello-one-20261115` (2026-11-15); the keep rule counts filled positions since app `e084e1f` (2026-11-14). |
| 2026-11-13 | P4, E5 tried: the shared pool's buffers marked purgeable-empty at the first run after a prefill, with the queue drained (on `agello-one` E4, not committed) | — | — | — | Not kept: no memory freed (3,625 → 3,625 MB at the release, 3,811 against 3,812 MB after the reply). The pages a run touches stay wired (2.47 GB of the process's 2.87 GB of GPU memory, `footprint`), and purgeable state only lets the system reclaim later. Releasing the 1,024-token prefill's 470 MB after a 3.5K-token prompt (up to ~1.6 GB after a 30K one) needs the buffers freed and the kernels rebound, or D2. (Its first reading put FP16 copies of the KV caches in decode; the graph dumps show they're the prefills' conversions, one buffer reused across layers: corrected in the next rows.) |
| 2026-11-13 | P4, E6: packed shared Metal buffers lock in place, without a host shadow or an unlock copy (`agello-one` `89137792`, build `774d4a932ddc`), 3 rounds against E4 (`build/cli/runs/e6`) and `agello ask` on a 3.5K-token chat | 4 of 4 identical, and the chat's two turns on both files | +0.4 % (band 0.6 %) | +1.3 % (+0.8 % on the 4.6K–4.9K-token cases, band 0.2 %) | Footprint −99 MB at 32K with today's file (3,811 → 3,712 MB), −73 MB with the ring file (2,897 → 2,824); host shadows 30 → 8, 631 MB of unlock copies gone; first token −6 to −9 % on the chat, −0.9 % on the bench. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | P4, the pool's lending rule: ML Drift's intermediate pool no longer lends a buffer more than twice the size needed and 16 MB over (`agello-one` `1f6e7f85`, build `1758e8777b13`), 3 rounds against E6 (`build/cli/runs/pool`) and `agello ask` | 4 of 4 identical, and short and 21K-token chats on both files | +0.4 % (band 0.1 %) | +1.2 % (`explain` −3.7 %: the first 1,024-token run of a process faults its own buffers in; `email` +9.0 %) | A fresh chat at 32K: 3,329 → 1,939 MB (tools on, a 247-token first message), 2,488 → 1,212 MB with the ring file. A graph that runs with a pool buffer keeps all of it wired until it's freed, and verify's small tensors were in the 1,024-token prefill's 524 MB buffers. After a message that runs the 1,024-token prefill the gain is about 80 MB: those buffers are wired again, and purgeable state doesn't release them (tried again, not kept). A 40K window, where E3's interim leaves that prefill out, held 1,362 MB against 2,508 at 32K before this rule. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | P4, the large prefill's own pool buffers freed between its runs and rebuilt before the next (`agello-one` `b96dedea`, build `e003f43c6776`), 3 rounds against the lending rule (`build/cli/runs/free`) and `agello ask` (21K, short, 3.3K-token messages at 32K; the 91K-token needle at 128K) | 4 of 4 identical, the chats' turns identical, the needle exact | +0.0 % (band 0.7 %) | −0.7 % (−1.5 % on `file-report`: each long prompt allocates and faults in 1.25 GB again) | Memory after a long prompt at 32K 3,635 → 2,457 MB, after the bench's cases 1.18–1.27 GB less (`file-report` 4,098 → 2,829 MB); first token +16–30 ms on long prompts, +0.6 % on the bench. With the lending rule, a 32K window no longer keeps the 1,024-token prefill's 1.25 GB, before or after a long prompt. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-13 | B5's runtime changes together (A1, E7, A2, E1, D1's first step, E2's fixes, E3's interim, E4, E6, the pool's two changes), the app's real-model scenarios natively (`scripts/cli-test.sh`), then A2's fix: the first decode is released early only when its text stays (`agello-one` `9be98b62`, build `01ec4570aa29`) | `inference` 22 of 23, `files` 5 of 5, `thinking` 3 of 3; the failure was A2's (`test90_Benchmark`: a `<pad>` decoded alone shows its name and beside another nothing, so the released text shrank); after the fix 23 of 23, and the bench's replies identical (4 of 4) | +0.1 % | — | First token unchanged with the fix (`email` −0.1 %, A2's gain kept). Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-14 | Train 1 on the iPhone 17 Pro: the runtime at `agello-one` `0d7e359c` (build `453b23814e69`: A1, E7, A2 and its fix, E1, D1's first step, E4, E6, the pool's lending rule and free-and-rebuild, D2's slices) against the shipped `99b8f5f6ea49`, `scripts/phone-bench.sh release next`, 3 rounds (`build/phone/runs/train1`) | 3 of 3 cases identical | +0.3 % (explain +1.1 %, file-report and email flat; noise 1.4 %) | +10.2 % (email +22 %, explain +7.3 %, file-report +2.2 %); first token −15.7 % (email −25 %, explain −17 %, file-report −3 %) | Train 1's speed and fidelity gate passed on the phone; its suites and the `memory` suite at 6.44 GB ran the same day and passed (two rows down). Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-14 | The window's step 1 (`agello-one` `6cfd1a28`, build `190b8eb4f343`): ring caches copied before a run would overwrite a rewind point's window and put back on the rewind (Think replies past 1,024 tokens), matching tokens prefilled again after a rewind, and prefill stopping between runs | Today's file: unchanged (unit 274/274, `inference` 23/23 natively). The 128K file: the bug shown with `AGELLO_VERIFY_RING_REWIND` (a 3,096-position rewind found 98 % of the window's bytes overwritten), the copy equal to the live cache over the window but for the V group the decode rewrites (same in full-length caches); the follow-up's facts right before and after, wording changed | — | — | Kept; a blocker for train 2 removed. The iPhone suites passed on this build (next row); the rewind fix's own check on the phone comes with the 64K quality gates. Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-14 | The window's step 1 on the iPhone 17 Pro (build `190b8eb4f343`, today's file): `scripts/device-harness.sh` `unit`, `inference`, `thinking`, `files`, `memory` | `unit` 339 (1 skipped), `inference` 23/23, `thinking` 3/3, `files` 5/5, `memory` 4/4 | — | — | Train 1's suites pass on the phone. Memory at the 6.0 GB envelope, 32K: 2.34 GB after load (0.46 GB ballast), 2.13 after a reply, 3.60 with an image, 2.63 after a 4K prompt, no warning; the plan's older table had 2.88 GB after load. |
| 2026-11-14 | The window's step 2 (`agello-one` `d3730b60`, build `889dea2b6618`): the 1,024-token prefill's pool of its own, freed buffers emptied, 1,024-token runs up to 64K | Identical to the shared pool's at 64K and 32K (the 128K file, two long prompts in a row); suites below | — | 64K, 44K tokens: first token 19.1 s against 24.1 with 128-token runs | Peak 2.96 GB at 64K (gate 3.0), 1.79 GB after the prompt (1.68 with 128-token runs, 2.46 shared); at 32K 1.22–1.56 GB after a 21K prompt against 1.65–1.92. Kept; the phone's 64K numbers next (done 2026-11-15, below). Released in `agello-one-20261115` (2026-11-15). |
| 2026-11-14 | The engine review's mask bounds ([PERFORMANCE.md](PERFORMANCE.md), "The engine review, adopted"): the delegate's converters drop their buffers after encoding (`agello-one` `1e2bc133`), global attention masks become per-row bounds in the Q·Kᵀ epilogue (`95b1bc88`) and the row-valid flag comes from them (`3a0ea85a`); `AGELLO_MASK_BOUNDS=0` restores the masks. The 128K file through `agello ask` | Identical at 64K and 32K and on an image prompt; unit, `inference`, `thinking`, `files` pass natively | Not measured then (the cost showed in the first release candidate, below) | 64K, 44K tokens: first token 19.6 → 17.7 s; 32K, 21K tokens: 7.53 → 7.18 s | Peak at 64K, 44K tokens 2,920 → 2,212 MB; at 32K, 21K tokens 1,937 → 1,560 MB. Kept; in the release with the prefill-only fix (the first release candidate's row, below). |
| 2026-11-14 | Sparse KV, steps 0–4 ([PERFORMANCE.md](PERFORMANCE.md), "The window: a fixed 64K with sparse KV caches"): step 0, the tile, blit and poison tests (`agello-one` `ff862efb`); steps 1–3, KV snapshots as GPU blits bounded by fill and the global KV as placement sparse buffers mapped as the chat fills (`12623257`); step 4, every prefill graph with a pool of its own, released after each prompt, and both the runtime's defaults (`d0b392a2`; `AGELLO_SPARSE_KV=0` and `AGELLO_PRIVATE_POOLS=none` restore the old configuration); then ModelInfo reads E4B's window and caches of any length are sparse (`cc97925b`). M6, the 128K file at 64K and the published file at 32K, through `agello ask` | Identical to the old configuration: a short chat, a 21K prompt with the helpers between turns, a 44K prompt, an image, and a 100-turn chat turn for turn; `inference` 23/23, `thinking` 3/3, `files` 5/5 natively; with the app's side (`e084e1f`) `unit` 275 natively | The same speed | The same speed | At 64K with the 128K file: a short chat 1,637 → 858 MB (peak 1,139), a 21K prompt with the helpers 1,701 → 1,092 MB (peak 2,205 → 1,597), a 44K prompt 1,765 → 1,323 MB (peak 2,212 → 1,770), a 21K prompt and an image 2,536 → 1,896 MB (peak 2,986 → 2,346). At 32K with the published file: a short chat 1,789 → 1,045 MB (peak 1,976 → 1,232), a 21K prompt with the helpers 1,754 → 1,603 MB (peak 2,543 → 2,371). Kept; released in `agello-one-20261115` (2026-11-15). |
| 2026-11-15 | The iPhone 17 Pro on the new defaults: runtime build `1b3e7a17630e` (sparse caches, prefill pools released, the window read from the file) with the app's fixed 64K (`e084e1f`), `scripts/device-harness.sh` and probes 24–26 (app `4fbc818`) | `unit` 340 (1 skipped), `inference` 23/23, `thinking` 3/3, `files` 5/5, `memory` 4/4; probe 24's needles 3/3 at 5K, 21K and 45K tokens | Probe 25, the replay ceiling: +13 to +17 % sustained over ten minutes (the bar was +8 %) | Probe 24 at 64K: 45,273 tokens in 50.5 s (897 tok/s), the phone warm | The A19 Pro has placement sparse buffers (tier 1, probe 26). The memory suite's 6.0 GB envelope (32K, the published file): 1.23 GB after load (2.34 before), 1.26 GB with an image (3.60), no memory warning. At a fixed 64K with the 128K file, a 45K prompt, the title helper and an image peak at 2.49 GB (the rule was 4.5 GB): the fixed 64K stands. The GPU-resident round is worth building. |
| 2026-11-15 | The first release candidate on the iPhone 17 Pro: build `14576c317c88` (the changes above, with the mask bounds in the decode and verify graphs too) against the shipped `99b8f5f6ea49`, `scripts/phone-bench.sh release next` (`build/phone/runs/20261115-003730`) | 3 of 3 cases identical | −2.8 % (every case −2.4 to −3.0 %; −4.7 % on the Mac) | +13.1 %; first token −16.8 % | Not released as built. The cause: the mask bounds ran in the decode and verify graphs, where they cost more than they save. The fix (`agello-one` `6da75396`) keeps them for prefill tails of 64 score rows or more. On the Mac after the fix: decode +0.7 % against the shipped runtime over four cases (noise 0.2 %); at 64K with a 44K prompt, against the candidate, decode 95.4 → 105.2 tok/s and the peak 1,770 → 1,678 MB; `inference` 23/23. |
| 2026-11-15 | The fixed candidate on the iPhone 17 Pro: build `0c749789100a` (`6da75396`) against `99b8f5f6ea49` (`build/phone/runs/20261115-122658`), then `explain` alone on a cool phone, six rounds (`build/phone/runs/explain-rerun`) | 3 of 3 cases identical; `explain` 12 of 12 | −0.3 % (email +0.8 %, file-report +1.0 %, explain −2.7 % [−4.8, −0.6] with the phone warm: heat disturbed 15 of 29 runs); `explain` on a cool phone +1.7 % [+0.9, +2.6] | +13.8 %; first token −16.6 %. `explain` cool: prefill +12.1 %, first token −18.5 % | Same output, decode the same, prefill and first token faster. The warm run's `explain` −2.7 % was heat (+1.2 % on the Mac). Passed: released. |
| 2026-11-15 | Release `agello-one-20261115` (fork `6da75396`, build `0c749789100a`), published on the maintainer's go and vendored in the app (commit `39daed1`), replacing `agello-next-20261024` (build `99b8f5f6ea49`) | The build of the comparison above | — | — | Ships. It carries the runtime's part of every change kept above, from B0 on; the ring and 128K model files aren't published. The phone suites weren't rerun on the vendored package (the maintainer's choice: it is the build the comparisons ran). |

The iPhone's baseline is the bench's (`scripts/bench/baseline.json`); a new one is due: B1 passed
there on 2026-11-12, and the committed baseline (2026-11-10) is on the previous runtime.
`scripts/phone-bench.sh` compares two runtime builds on the iPhone the way
`cli-bench.sh` does on the Mac; its noise band needs four rounds or more (the shipped build against
itself: `release again=release`).

## What it costs

- **Google's work stops arriving by itself.** A new Gemma, a new file format or an upstream fix
  is ported by hand, into code that will look less and less like theirs.
- **The first two steps buy no speed.** B2 and B3 are there so that every later change is one
  commit in one place.
- **B1 changes shipping code.** Without the CPU fallback, a phone whose GPU load fails gets an
  error where it used to get a slow answer. On the 12 GB floor that should be rare; the load
  log will say if it isn't.
- **Disk.** A runtime build needs about 8 GB of Bazel output while it's worked on; the project
  budget (40 GB since 2026-11-13, 50 GB free) is tight around it.
