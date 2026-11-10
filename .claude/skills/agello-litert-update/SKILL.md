---
name: agello-litert-update
description: Update the vendored LiteRT-LM package (Vendor/LiteRT-LM), work in the PowerBeef/agello-litert-lm fork (../LiteRT-LM), or report and prepare fixes for upstream. Use when asked about LiteRT-LM versions, upgrades, patches, the fork, or upstream issues.
---

# Updating LiteRT-LM

`Vendor/LiteRT-LM` holds only the Swift package surface of our fork's
`agello-next` branch: `Package.swift` (with the checksummed
`CLiteRTLM.xcframework` download of our release, `agello-next-20261024` since
2026-10-28), `swift/`, and `LICENSE`. It's vendored because upstream Git LFS
breaks Swift Package Manager resolution.

## The fork

`PowerBeef/agello-litert-lm` (renamed from `PowerBeef/LiteRT-LM` on 2026-10-14; old
URLs redirect) is a fork of `google-ai-edge/LiteRT-LM`, cloned beside
this repo at `../LiteRT-LM`. `.claude/settings.json` lists it in
`additionalDirectories`, so its C++ and Swift sources are readable from this
project (its own CLAUDE.md and skills don't load):

| Item | Value |
| --- | --- |
| `origin` | `PowerBeef/agello-litert-lm` (push here) |
| `upstream` | `google-ai-edge/LiteRT-LM` (fetch only; push is disabled) |
| `agello` branch | Tag `v0.18.0` plus Agello's Swift patches (see below), for Google's prebuilt binary; `Vendor/LiteRT-LM` came from it until 2026-10-28. Also holds `docs/agello/` and `tools/agello-bench`. |
| `agello-next` branch | The source build (below): upstream's 0.19.0 nightly source (tag `agello-base-20261013`) plus our patches. Worktree at `../agello-arms/next/LiteRT-LM`. The app vendors its releases: `agello-next-20261024` (`f1b88286`) since 2026-10-28. |
| `research/3913` tag | The #3913 research (below); a branch until 2026-10-15, so links to `tree/research/3913` still resolve |
| Release tags | Live on upstream's `release/vX.Y.Z` branches (fetch from `upstream`), not on `main` |

Branch policy (decided 2026-10-15): each fork (this one, `PowerBeef/LiteRT`,
`PowerBeef/ml-drift`) keeps `main`, an upstream mirror, plus our branches; the
branches Google's repos had when the forks were made don't belong there.
`agello` and `agello-next` are due to merge into one `agello`: the iPhone
validated our build on 2026-11-02 and the app has shipped it since 2026-10-28.
Still to do, on the user's go (tag the old `agello` tip first: the commit of
Google's-binary wrapper must stay reachable).

Set it up on a new machine. The partial clone keeps full history but fetches
file contents on demand, and LFS stays skipped: upstream's LFS holds GBs of
prebuilt binaries that nothing here needs.

```sh
cd ..   # beside this repo
GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none https://github.com/PowerBeef/agello-litert-lm.git LiteRT-LM
cd LiteRT-LM
git lfs install --local --skip-smudge
git remote add upstream https://github.com/google-ai-edge/LiteRT-LM.git
git remote set-url --push upstream DISABLED
git fetch upstream --tags
git switch agello   # tracks origin/agello
```

Sync the fork's `main`: `git fetch upstream && git push origin upstream/main:main`.

### Contributing upstream

As of 2026-10-15, upstream's CONTRIBUTING.md says the repository is **not
accepting code contributions**: it asks for GitHub issues instead. Merged pull
requests come from Google's internal mirror (`copybara-service`); outside pull
requests are rarely merged (30 of 2,497 by 2026-10-15). The fork's
`docs/agello/reference/contributing.md` has each upstream's rules, issue and
commit templates, and the evidence checklist. So:

1. Reproduce the bug on the iPhone (harness probes) and fix it on a branch
   off `upstream/main` (or off `agello` when it only matters here).
2. Push the branch to the fork and open an **issue** upstream with the
   reproduction, measurements, and a link to the branch or commit.
3. Open a pull request only after re-reading CONTRIBUTING.md on
   `upstream/main`, in case the policy has changed.

Pushing to the fork, and anything posted upstream, needs the user's go-ahead.

### Issue #3913 (float16 rotary positions)

- Analysis posted on 2026-10-13:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6157362598
  (pointer on #2814). Follow-up with the model-side fix:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6159684389
- On 2026-10-14 and 15, picitujeromanov (an M1 Max losing digits below 2,048,
  fixed by 512-token blocks) and john-rocky (both patches confirmed on an M4 Max
  and a Pixel 8a) replied. Our answer, posted 2026-10-16, gives the 512-block
  results, the GPU families affected (the A15 is Apple8, not the M1's Apple7)
  and ML Drift's fp32 RoPE kernels as the widest fix:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6220359922
- On 2026-10-18 john-rocky showed a Gemma 4 E2B file exported with
  litert-torch's `odml.rope` composite (`--use_rope_composite=True`) exact at
  fp16 on an M4 Max, and asked for it as the default in
  google-ai-edge/litert-torch#1343 (triaged 2026-10-21, assigned to
  john-rocky). Our reply, posted 2026-10-23, accepts the offer to run that
  file on the M6 (WebGPU, iOS library, our build) and the iPhone 17 Pro, asks
  for an E4B export, and points to #4001:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6359855208
- 2026-10-24: john-rocky shared the E2B composite export
  (`mlboydaisuke/gemma-4-E2B-it-litert-lm-rope-composite`, 8,192-token cache,
  int8 weights, no MTP drafter). Probe 20 (`AgelloDeviceTests/LabSuiteProbe.swift`,
  the research suites on files in Documents/lab) and agello-bench ran it:
  118/118 exact on the iPhone 17 Pro, the iPhone app on the M6, Google's macOS
  library (WebGPU) and our build (Metal); the stock E2B 35/118 everywhere. The
  composite file was 2-3x slower, but its int8 recipe differs too, so we asked
  for the same export without the flag. Posted:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6385900547
  The lab files were deleted from `~/Models/agello/lab` on 2026-11-03, once
  the round below was posted (the phone's Documents/lab may still hold
  `e4b-ropecomposite.litertlm`: remove it with probe 13, under "Lab models").
- 2026-10-25: john-rocky posted the E2B export without the flag (the control,
  `gemma-4-E2B-it-no-ropecomposite.litertlm`), E2B composite with a 32,768
  cache (`…-ropecomposite-32k.litertlm`), both in the E2B repo, and the E4B
  composite (`mlboydaisuke/gemma-4-E4B-it-litert-lm-rope-composite`, 8.21 GB,
  int8). On his M4 Max: composites 118/118 (the 32k file 12/12 on `xl`
  t12000–t30000), the control 37/118, and flag vs no flag within 1 % in speed.
  Our runs (2026-11-02/03, probe 20 on the iPhone with our runtime, agello-bench
  on both M6 arms) agree: the control 37/118 everywhere and as fast as the
  composite; the 32k file 130/130 on the M6 but 2.2–3.7× slower to decode and
  killed by jetsam on the iPhone past ~500-token prompts (its footprint jumps
  to 5.6 GB); the E4B composite 118/118 everywhere, fitting the iPhone in the
  foreground (6.65 GB) but decoding 2.5–2.6× slower than our patched E4B.
  Posted 2026-11-03:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6596803301
- 2026-10-31: elbrinner (iPhone 15 Pro, E2B, v0.17.1, a RAG bench): fp32 fixes
  two long cases; a ~250-token case differs between Metal (fp16 and fp32) and
  CPU. Our reply asks whether the long prompts pass 2,048, points to the
  composite and `patch_rope.py`, and suggests greedy runs to rule out the
  samplers (Google's Metal sampler vs the CPU top-p one; seed 0 for every
  conversation on v0.18.0). Posted 2026-11-03:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6596859591
- LiteRT-LM #4001 reports the same failure on Android (Adreno 840 with E4B,
  Adreno 740 with E2B), FLOAT32 the only workaround. Don't present our patched
  file as its fix without A/B runs on that repro (asked there on 2026-10-17).
- As of 2026-11-10 the issue is open and assigned to a Google developer
  (hheydary); the last comments are ours of 2026-11-03, and the round on
  john-rocky's exports is finished. Check for replies with
  `gh api repos/google-ai-edge/LiteRT-LM/issues/3913/comments`, and for new
  exports with `hf_fs ls hf://models/mlboydaisuke` (or `hf models list --author
  mlboydaisuke`): the 2026-10-25 files went unseen for a week. Comments go out
  under the user's name, without Claude attribution.
- The follow-up also describes two WebGPU delegate bugs found while building
  the patch (FULLY_CONNECTED with float weights; REDUCE_MAX over a non-last
  axis). They don't reproduce as single ops: on 2026-10-13, standalone models
  with those exact patterns were exact on v0.18.0's WebGPU accelerator, fully
  accelerated, up to N=2048 and F=256. The failures came from the surrounding
  graph (INT32/BOOL producers: broadcast ADD, comparisons, CAST, SELECT_V2).
  The user decided not to file them, and posted a correction:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6160403434
  The check lives on the fork's `research/3913` tag, in
  `research/issue-3913/webgpu-op-check/` (commit `7cebaa0c`).
- Reproduction: the fork's `research/3913` tag, `research/issue-3913/`
  (graph-patch script, macOS runner, raw results, `summarize.py`).
- **The app ships our fix.** `ModelCatalog.e4b` downloads
  `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope`, pinned to a commit.
  - It's the litert-community file run through the fork's
    `tools/model-surgery/patch_rope.py --split --block 512`: rotary positions
    split as `512·h + l`, exact in FP16 up to 32,767 on every GPU tested (M1-class
    GPUs also lose precision in SIN/COS past ~1,650, which 2,048-token blocks,
    the first revision `13d5aa4c`, left in place); main model and MTP drafter;
    weights unchanged. `--block 2048` reproduces the first revision.
  - The output is deterministic: the model card lists the sha256 of both files.
- **When litert-community updates the E4B file** (the `hf` CLI and the
  plugin's Hub tools, CLAUDE.md "Hugging Face"; load `huggingface-skills:hf-cli`):
  1. See what changed: `hf models list litert-community/gemma-4-E4B-it-litert-lm --format json`
     (each file's `last_commit`), or `hub_repo_details`.
  2. Download it to scratch, never the shared cache:
     `hf download litert-community/gemma-4-E4B-it-litert-lm <file> --revision <commit> --local-dir <scratch>`.
  3. Run `patch_rope.py --split --block 512` on it.
  4. On the user's go, upload it to the same repo with the model card's sha256
     and source revision updated:
     `hf upload PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope <file> <file> --commit-message "…"`
     (no Claude attribution).
  5. Update `ModelCatalog.e4b` (`revision`, `sizeBytes`, `sha256`) from
     `hf models list PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope --revision <commit> --format json`:
     the file's `size` and `lfs.sha256`. Downloads are checked against it.
     EmbeddingGemma is pinned the same way (`ModelCatalog.embeddingGemma`).
  6. Run the `inference` suite (`test15_LongContextDigitFidelity`) and probe 12.
- **When Google fixes #3913** (a new LiteRT-LM release or a re-exported model):
  - Run `ONLY=AgelloDeviceTests/ProbeScenarioTests/test10_PositionBoundary scripts/device-harness.sh probes`
    against their file.
  - If FP16 copies exactly past position 2,048, the catalog can go back to
    their file.
- **Lab models for the probes:** download them with
  `hf download <repo> <file> --local-dir ~/Models/agello/lab` and check the sha256 against the
  poster's or the Hub's (`hf models list <repo> --format json`, `lfs.sha256`). Copy them to
  the app's `Documents/lab` with `devicectl device copy to`, and delete them with
  `TEST_RUNNER_LAB_REMOVE=<file> ONLY=…/test13_RemoveLabModels scripts/device-harness.sh probes`.
  - Probe 11 needs `ishift-2048.litertlm` (`patch_rope.py … -2048 … --int`).
  - Probe 12 needs `split.litertlm` (`--split --block 512`).

### Using patches in Agello

- **Swift wrapper patches** (`swift/`) are commits on the fork's `agello-next`
  branch, and the app vendors that branch at the release's commit
  (`Vendor/use-release-litert.sh`, below). `Vendor/README.md`, "Swift patches",
  lists the four of them with the probe or test that checks each: keep the list
  there. The `agello` branch carries the same patches on Google's v0.18.0.
  - Two are worth offering upstream as issues, with the user's go-ahead: the
    failed tool call answered with an `error` response instead of ending the
    reply, and the stream holding its conversation weakly (held strongly, the
    final callback deleted the conversation on LiteRT-LM's callback thread and
    stalled the engine for 10 minutes; releasing on another queue isn't enough).
  - Each patched file carries a modification notice (Apache 2.0, section 4),
    and `NOTICE` lists the change.
- **C++ runtime patches** reach the app through a rebuilt
  `CLiteRTLM.xcframework`: the source build below, released on the fork and
  vendored here ("Shipping it"). `Vendor/README.md`, "The runtime", lists what
  ours carries.

### The source build (`agello-next`)

The Apple-only re-engineering of LiteRT-LM builds the whole runtime from
source, Metal accelerator included, in three forks. Its docs are in the fork's
`docs/agello/` on `agello`: `reference/` (the verified reference for the
runtime, the models and our changes; Agello's `docs/LITERT-LM.md` maps topics
to its pages), `AUDIT.md` (dated, v0.18.0), `PARITY.md` (against Google's
nightly), `TELEMETRY.md`, and `tracks/` (one note per track).

| Checkout | Repository, branch |
| --- | --- |
| `../agello-arms/next/LiteRT-LM` | `PowerBeef/agello-litert-lm`, `agello-next` (a worktree of `../LiteRT-LM`) |
| `../LiteRT` | `PowerBeef/LiteRT`, `agello-next`: the Metal delegate and buffer handler, telemetry probes |
| `../ml-drift` | `PowerBeef/ml-drift`, `agello-next`: the GPU engine, kernel names and timing |

- **Build:** `agello/build-xcframework.sh` in the worktree writes
  `dist/CLiteRTLM.xcframework` and `dist/BUILD-INFO.txt` (commits, SHA-256s).
  Its `WORKSPACE` pins LiteRT and ML Drift by commit and archive sha256.
  - After an Xcode update the build fails at once in `xcode-locator`: run
    `bazelisk sync --configure --repo_env=HERMETIC_PYTHON_VERSION=3.13`
    (without the variable it picks Homebrew's newest Python). The new
    compiler then rebuilds everything, about 8 minutes on the M6.
  - Never edit the worktree's sources while Bazel builds: it can store
    objects compiled from the edited files under the old files' digests, in
    the local action cache and the disk cache, and a later build of the old
    sources gets them back (2026-10-24: an A/B "control" arm carried the fix).
    If it happens, delete `~/.cache/bazel-disk`, run `bazelisk clean` and
    rebuild; check an arm with `strings` on a symbol only the change adds.
- **Changing LiteRT or ML Drift:** uncomment the `--override_repository`
  lines in the worktree's `.bazelrc.user` to build from the local checkouts.
  After pushing, re-pin: the new commit and `shasum -a 256` of
  `https://github.com/PowerBeef/<repo>/archive/<commit>.tar.gz`. Comment the
  overrides out and rebuild: the framework gets a new build id (it isn't
  byte-identical), so compare replies (agello-bench `short`), not bytes.
  Then re-verify the reference: `reference/maintenance.md`, "After a re-pin or
  rebase" (`tools/agello-docs/check_refs.py --repin` lists the claims whose
  cited code moved).
- **Pushing `agello-next`:** from `../LiteRT-LM` (`git push origin
  agello-next`); from the worktree, Git LFS's pre-push lock check fails.
- **In Agello:** `Vendor/use-local-litert.sh` vendors the worktree's build
  (its header says how to switch back). It *copies* the framework: rerun it
  after every rebuild, and check the build id in the harness report's device
  record (`runtimeBuild`) before trusting a run. Never commit `Vendor/LiteRT-LM`
  while it points at the local build. Then verify on the iPhone
  (`agello-device-testing`); a `PLATFORM=mac` run only after asking the user,
  who often keeps the Mac busy.
- **Shipping it:** `agello/release-xcframework.sh <tag>` on the fork (a dry run
  without `--publish`; publishing needs the user's OK). `--publish` rebuilds
  first: to publish the dry run's files you tested, run the script's
  `gh release create` line on `dist/release/<tag>/` instead (done for
  `agello-next-20261024`; check the zip's slices against `BUILD-INFO.txt`). Then
  `REF=<commit> TAG=<tag> Vendor/use-release-litert.sh` here. `BUILD.md` on the
  fork covers the release, the third-party notices (for `NOTICE`) and the
  privacy manifest check (no new required-reason categories as of 2026-10-15).
- **Build provenance:** `litert_lm_get_build_info()` (our builds only) names
  the commits, flags and a build id; `EngineCache` keys its folders by that id,
  so switching between Google's binary and ours needs no cache juggling (the
  other build's folders are deleted at the next load).
- **Measuring:** `tools/agello-bench` on `agello` (build it against an arm
  with `LITERTLM_PACKAGE=<checkout> swift build -c release --scratch-path
  .build-<arm>`), ABAB runs, `compare.py` for changes with confidence
  intervals, `telemetry.py` for the engine's own breakdown.
- **Telemetry:** `AGELLO_TELEMETRY=<0-4>` (level), `AGELLO_TELEMETRY_OUT`
  (snapshot at exit), `AGELLO_TELEMETRY_GRAPH_DIR` (GPU graph dumps),
  `AGELLO_VERIFY_DIRECT_COPIES=1` (checks the direct Metal host copies). See
  `TELEMETRY.md`, and `agello-device-testing` for the harness side.

## 1. Check upstream

- Latest release: `gh release view --repo google-ai-edge/LiteRT-LM`. What the
  app runs is in `Vendor/README.md`: our build of `agello-next`, which follows
  upstream's source (base tag `agello-base-20261013`, a 0.19.0 nightly), not
  Google's release binaries.
- Read the release notes, and check issues the app works around, especially
  #3913 (GPU float16 digit duplication).
- Note any Swift API changes in `swift/` (Engine, Conversation, Config,
  ResponseFormat, Tool, EmbeddingEngine, ExperimentalFlags). In the fork:
  `git fetch upstream --tags && git diff agello-base-20261013 <new base> -- swift/`.
- Taking a new upstream version means rebasing `agello-next` onto the new
  base, rebuilding and releasing ("The source build", above), then re-verifying
  the fork's reference (`reference/maintenance.md`, "After a re-pin or
  rebase"). It's days of work across three forks: decide with the user first.

## 2. Vendor the release

```sh
REF=<agello-next commit> TAG=<release tag> ./Vendor/use-release-litert.sh
```

Then update the release and build id in `Vendor/README.md`, the README's
"Vendored LiteRT-LM" section, the code map in `docs/ARCHITECTURE.md`,
`docs/LITERT-LM.md`, and `NOTICE` (from the release's `THIRD_PARTY_NOTICES.md`,
copied to `Agello/Resources/NOTICE.txt`).

- Never vendor Google's tag directly (`REPO=google-ai-edge/LiteRT-LM REF=…`):
  it drops the patches.
- `REF=<agello commit> ./Vendor/refresh-litert-lm.sh` alone goes back to
  Google's v0.18.0 binary with the Swift patches. That undoes our runtime
  fixes: only on the user's decision.

## 3. Build and fix

Build for the iPhone. Fix API changes only in the files that import LiteRTLM
(CLAUDE.md, "Engine boundary": `Inference/ChatEngine.swift`,
`Inference/Tools.swift`, `Knowledge/Embedding.swift` and AppState's benchmark).
Keep every rule in the `agello-inference-rules` skill.

## 4. Re-check the privacy manifest

`CLiteRTLM.framework` is embedded without its own privacy manifest, so the
app's `Agello/PrivacyInfo.xcprivacy` declares its required-reason APIs. After
the build, list the binary's references:

```sh
F=$(find ~/Library/Developer/Xcode/DerivedData/Agello-*/SourcePackages/artifacts/litert-lm \
  -path "*ios-arm64/CLiteRTLM.framework/CLiteRTLM" | head -1)
nm -u "$F" | grep -E "_(stat|fstat|fstatat|lstat|getattrlist.*|statfs|fstatfs|statvfs|fstatvfs|mach_absolute_time)$|NSUserDefaults|systemUptime"
find "$(dirname "$F")" -name "*.xcprivacy"
```

v0.18.0 references `stat`, `fstat`, `fstatat`, `lstat` (file timestamp,
declared `C617.1`) and `mach_absolute_time` (system boot time, `35F9.1`). Any
new category needs an entry in the app's manifest. If the framework starts
shipping its own manifest, keep the app's entries for the app's own code
(UserDefaults `CA92.1`, disk space `E174.1`, file sizes `C617.1`).

## 5. Verify on the iPhone

Run these in order (see `agello-device-testing`):

1. `scripts/device-harness.sh probes`: LiteRT-LM feature probes (helper
   conversation, JSON, embeddings).
2. `inference`, then `files`.
3. `calibrate` when performance or memory may have changed. Compare with the
   roadmap's dated runs, and record the new ones there.
4. If the release mentions #3913, follow "When Google fixes #3913" above.

Commit the vendored release and the fixes separately.
