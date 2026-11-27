---
name: agello-litert-update
description: Update the vendored LiteRT-LM package (Vendor/LiteRT-LM), work in the PowerBeef/agello-litert-lm fork (../LiteRT-LM), or report and prepare fixes for upstream. Use when asked about LiteRT-LM versions, upgrades, patches, the fork, or upstream issues.
---

# Updating LiteRT-LM

**Hard-fork policy ([docs/BACKEND.md](../../../docs/BACKEND.md)):** Agello runs our own LiteRT-LM fork on Metal GPU. Google's upstream repository is a read-only source — never sync, merge, or rebase onto upstream, and never vendor or measure Google's binary (WebGPU/CPU arms are gone).

**One repository, one branch, one checkout:** `PowerBeef/agello-litert-lm`, branch `main`, checked out at `../LiteRT-LM`. LiteRT (`agello/litert`) and ML Drift (`agello/ml_drift`) live in-tree as Bazel `local_repository` folders: edit them in place and run `agello/build-xcframework.sh` (output in `dist/`). `main` also holds `docs/agello/`, `tools/agello-bench/`, `tools/agello-docs/`, and `tools/model-surgery/`. Because the tree is pruned to Apple build inputs, after deleting files verify with `bazelisk clean` and `agello/build-xcframework.sh --disk_cache=` (the cache hides missing headers). Never export LiteRT with plain `git archive` (pulls Google LFS prebuilts).

**Vendored surface (`Vendor/LiteRT-LM`):** Holds only what Xcode/SwiftPM needs (`Package.swift`, `swift/`, `LICENSE`) because upstream Git LFS breaks SwiftPM resolution. **Binary release vs `swift/` commits are tracked separately in [Vendor/README.md](../../../Vendor/README.md):** Swift-only changes on fork `main` can lead the shipped `CLiteRTLM.xcframework` release until the next binary cut. Keep `Vendor/LiteRT-LM/swift/` (including `swift/BUILD`) byte-identical to `../LiteRT-LM/swift/` (`diff -rq ../LiteRT-LM/swift Vendor/LiteRT-LM/swift`).

**Living engineering ledger ([docs/BACKEND_KNOWLEDGE_BASE.md](../../../docs/BACKEND_KNOWLEDGE_BASE.md)):** **Before** proposing or implementing any Metal/MSL 4.1 kernel, speculative-decoding, KV/pool, executor, ANE, or `tools/model-surgery/` change, consult **Part 4 (Worth Revisiting Later, incl. `§4.1` M6 Mac vs. iPhone 17 Pro Silicon Divergence Matrix, `§4.2` v3 Prototypes, `§4.3` High-ROI Runtime Tracks, `§4.4` Wave 3 Backlog)** and **Part 6 ("Do Not Repeat" Graveyard)** so dead ends and M6-only illusions are never repeated. **After** measuring on Mac (`cli-bench.sh`) and/or physical iPhone (`phone-bench.sh`, `device-harness.sh`), record the outcome in `docs/BACKEND_KNOWLEDGE_BASE.md` following **Part 7 (How to Maintain This Living Document)** — **including negative/flat trials, reverted commits, and M6-win / iPhone-loss divergences** — in the same commit.

## The fork (`../LiteRT-LM`)

Open `../LiteRT-LM` alongside `iRT` in a multi-root Antigravity workspace (all rules, skills, and hooks live in `iRT`).

| Item | Value |
| --- | --- |
| `origin` | `PowerBeef/agello-litert-lm` (push here only on user go) |
| `upstream` | `google-ai-edge/LiteRT-LM` (fetch only; push `DISABLED`) |
| `main` | The sole branch (0.19.0 nightly base `agello-base-20261013` + our commits, LiteRT & ML Drift in-tree) |
| `research/3913` tag | Preserved #3913 reproduction & scripts (do not delete) |

**Branch policy:** One branch (`main`) on GitHub — never recreate upstream mirrors, side branches, or a branch named `agello` (would break GitHub redirect links from #3913 and the Hugging Face model card). Retired branch and pre-monorepo history is archived in [docs/archive/litert-issue-3913-log-2026-11.md](../../../docs/archive/litert-issue-3913-log-2026-11.md).

**Fresh clone setup (LFS skipped):**
```sh
cd ..
GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none https://github.com/PowerBeef/agello-litert-lm.git LiteRT-LM
cd LiteRT-LM
git lfs install --local --skip-smudge
git config lfs.https://github.com/google-ai-edge/LiteRT-LM.git/info/lfs.locksverify false
git remote add upstream https://github.com/google-ai-edge/LiteRT-LM.git
git remote set-url --push upstream DISABLED
git fetch upstream --tags
git switch main
```
(`locksverify false` avoids `.lfsconfig` pre-push lock errors against Google's repo when pushing to `origin`.)

### Reporting issues upstream

Upstream's `CONTRIBUTING.md` does not accept external PRs (merges arrive via `copybara-service`). See `../LiteRT-LM/docs/agello/reference/contributing.md` for evidence templates:
1. Reproduce on device and fix on our `main`.
2. With explicit user go-ahead, open a GitHub **issue** upstream with measurements and a link to our `main` commit (zero AI/agent attribution). Never open PRs or merge upstream back.

## Issue #3913 & v2 surgical model workflow

Google's stock Gemma 4 E4B file computes RoPE angles from FP16 position copies, duplicating digits past position 2,048 on Apple GPUs (Issue #3913; full Oct–Nov 2026 GitHub comment chronology, composite-export A/B data, and #4001 notes are archived in [docs/archive/litert-issue-3913-log-2026-11.md](../../../docs/archive/litert-issue-3913-log-2026-11.md)). Check upstream activity with `gh api repos/google-ai-edge/LiteRT-LM/issues/3913/comments` or `huggingface` MCP (`hf_fs` on `hf://models/mlboydaisuke`).

- **Shipped v2 artifact:** `ModelCatalog.e4b` pins `gemma-4-E4B-it-agello-v2.litertlm` from `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` (built deterministically from `patch_rope.py --split --block 512` via `tools/model-surgery/build_v2.sh`: 1,536-slot `ring_kv` → 128K shared Dual-`GATHER` RoPE `<0.001 rad` → `verify_8`; weights unchanged). Keep `gemma-4-E4B-it-fp16-rope.litertlm` untouched on HF `main` for external #3913 users.
- **When `litert-community` updates E4B** (inspect with `huggingface` MCP; download/upload via `/opt/homebrew/bin/hf` with `BypassSandbox: true`):
  1. Check file revisions via `hub_repo_details` or `hf models list litert-community/gemma-4-E4B-it-litert-lm --format json`.
  2. Download to scratch (`--local-dir <scratch>`, never `~/.cache/huggingface`).
  3. Run `patch_rope.py --split --block 512`, then `tools/model-surgery/build_v2.sh`.
  4. On explicit user go-ahead, upload both artifacts to `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope` with updated SHA-256s and source revision (zero AI attribution).
  5. Update `ModelCatalog.e4b` (`revision`, `sizeBytes`, `sha256`) from verified Hub LFS metadata (EmbeddingGemma 2 pins identically in `ModelCatalog.embeddingGemma`).
  6. Run `test15_LongContextDigitFidelity`, `test27_NeedleTable`, and `test28_WindowPositions`.
- **When Google fixes #3913:** Run `ONLY=AgelloDeviceTests/ProbeScenarioTests/test10_PositionBoundary scripts/device-harness.sh research-probes` (or pass `TEST_RUNNER_HARNESS_RESEARCH_PROBES=1` with `probes` — `test10_PositionBoundary` skips under plain `probes`).
- **Lab models for probes:** Download with `hf download <repo> <file> --local-dir ~/Models/agello/lab` (`BypassSandbox: true`), verify `lfs.sha256`, copy to device `Documents/lab` via `devicectl device copy to`, and remove with `TEST_RUNNER_LAB_REMOVE=<file> ONLY=AgelloDeviceTests/ProbeScenarioTests/test13_RemoveLabModels scripts/device-harness.sh probes`.

## Patches & source builds

- **Swift & C++ patch inventory:** [Vendor/README.md](../../../Vendor/README.md) is the single source of truth for all Swift wrapper patches (with verification tests) and runtime C++/Metal changes. Each patched file keeps an Apache 2.0 §4 modification notice, and `NOTICE` (synced to `Agello/Resources/NOTICE.txt`) records the change.
- **Fork docs:** `../LiteRT-LM/docs/agello/` holds `BUILD.md`, `TELEMETRY.md`, and `reference/` (mapped by [docs/LITERT-LM.md](../../../docs/LITERT-LM.md)). Note `reference/facts.md` is pinned to `b7b856a0` (`2026-11-17`, v1 32K) until its next `tools/agello-docs/repin.py` pass — cross-check `docs/ROADMAP.md`, [docs/BACKEND_KNOWLEDGE_BASE.md](../../../docs/BACKEND_KNOWLEDGE_BASE.md), and `Vendor/README.md`.
- **Building (`BypassSandbox: true`, `WaitMsBeforeAsync: 500`):**
  ```sh
  ../LiteRT-LM/agello/build-xcframework.sh --mac-only   # fast macos-arm64 rebuild for Mac CLI iteration (~2x faster)
  ../LiteRT-LM/agello/build-xcframework.sh              # full dual-slice ios-arm64 + macos-arm64 -> dist/CLiteRTLM.xcframework
  ```
  - Writes `dist/CLiteRTLM.xcframework` and `dist/BUILD-INFO.txt`. First clean build takes ~9 min; incremental builds reuse Bazel output base and `~/.cache/bazel-disk`.
  - **After an Xcode update:** If `xcode-locator` fails immediately, run `bazelisk sync --configure --repo_env=HERMETIC_PYTHON_VERSION=3.13`.
  - **Never edit `../LiteRT-LM` sources while Bazel builds:** Corrupts local/disk action cache digests (recovery: delete `~/.cache/bazel-disk`, `bazelisk clean`, rebuild; verify with `strings` on a new symbol).
  - Builds embed provenance (`litert_lm_get_build_info()` → `EngineCache.runtimeBuildID`), so binaries are never byte-identical; compare replies and timings via `scripts/cli-bench.sh release next` (Mac) or `scripts/phone-bench.sh release next` (iPhone). Copy `dist/` aside and pass `NAME=/abs/path` to hold an arm across tree edits.
- **Testing locally in Agello:** Run `Vendor/use-local-litert.sh` (`BypassSandbox: true`), which *copies* `../LiteRT-LM/dist/` into `Vendor/LiteRT-LM` — rerun after every rebuild and verify `runtimeBuild` in `harness-report.json`. **Never commit `Vendor/LiteRT-LM` pointing at a local build.**
- **Releasing & vendoring:**
  1. Dry-run on fork: `../LiteRT-LM/agello/release-xcframework.sh <tag>` (writes `dist/release/<tag>/` + `THIRD_PARTY_NOTICES.md`). Note `--publish` rebuilds first — to publish the exact tested dry-run zip, run its `gh release create` command on `dist/release/<tag>/` after explicit user go-ahead (verify slices against `BUILD-INFO.txt`), then delete `dist/release/<tag>/`.
  2. Vendor in `iRT`: `REF=<commit on main> TAG=<release tag> ./Vendor/use-release-litert.sh`.
  3. Update [Vendor/README.md](../../../Vendor/README.md), `docs/BACKEND.md`, [docs/BACKEND_KNOWLEDGE_BASE.md](../../../docs/BACKEND_KNOWLEDGE_BASE.md) (Part 7), `docs/ROADMAP.md`, and `NOTICE` (from regenerated `THIRD_PARTY_NOTICES.md`, synced verbatim to `Agello/Resources/NOTICE.txt`).
- **Benchmarking & telemetry:** `tools/agello-bench` (`LITERTLM_PACKAGE=<checkout> swift build -c release --scratch-path .build-<arm>`), `compare.py`, `telemetry.py`; env vars `AGELLO_TELEMETRY=<0-4>`, `AGELLO_TELEMETRY_OUT`, `AGELLO_TELEMETRY_GRAPH_DIR`, `AGELLO_VERIFY_DIRECT_COPIES=1` (`../LiteRT-LM/docs/agello/TELEMETRY.md`).

## Checking upstream, API boundaries & verification

1. **Inspect upstream (read-only):** `gh release view --repo google-ai-edge/LiteRT-LM` and `git fetch upstream --tags && git diff agello-base-20261013 <tag> -- swift/` to spot Swift API shifts or fixes worth hand-porting to `main` on user go-ahead.
2. **Fix API changes at the exact import boundary:**
   - `import LiteRTLM` (native XCFramework): strictly 3 `Agello/` files (`Inference/ChatEngine.swift`, `Knowledge/LiteRTEmbedder.swift`, `AppState+Benchmark.swift`) plus `AgelloCLI/Sources/Serve*.swift`.
   - `import LiteRTLMTools` (pure-Swift package product, zero binary dependency): `Inference/Tools.swift`, `Inference/PersonalActionTools.swift`, `Inference/AutomationTools.swift`, `AppState+Tools.swift`, `Inference/ChatEngineProtocol.swift`, and `AgelloSim/RemoteChatEngine.swift`.
   - Obey all rules in `agello-inference-rules`.
3. **Re-check the privacy manifest:** `CLiteRTLM.framework` ships no `.xcprivacy` of its own; `Agello/PrivacyInfo.xcprivacy` declares its required-reason APIs (`stat`/`fstat`/`lstat` → `C617.1`, `mach_absolute_time` → `35F9.1`; `AgelloShare/PrivacyInfo.xcprivacy` declares `C617.1`). After building, verify no new categories appeared:
   ```sh
   F=$(find ~/Library/Developer/Xcode/DerivedData/Agello-*/SourcePackages/artifacts/litert-lm \
     -path "*ios-arm64/CLiteRTLM.framework/CLiteRTLM" | head -1)
   nm -u "$F" | grep -E "_(stat|fstat|fstatat|lstat|getattrlist.*|statfs|fstatfs|statvfs|fstatvfs|mach_absolute_time)$|NSUserDefaults|systemUptime"
   find "$(dirname "$F")" -name "*.xcprivacy"
   ```
4. **Verify (Mac workbench → physical iPhone gate):**
   - Run `scripts/cli-test.sh unit`, targeted scenarios + `MTL_DEBUG_LAYER=1`, `scripts/cli-bench.sh`, and `AgelloSim` (`scripts/sim-launch.sh`) first.
   - Ask the user, then run `scripts/device-harness.sh gate` (`~7.5–9 min`) on physical iPhone. Add `probes` or `soak` if KV/pool/constraint internals changed; save `calibrate`, `bench`, and `phone-bench.sh` for speed milestones or release cuts.
   - Record all measured results (shipped wins in Part 2, probes in Part 3, M6-vs-iPhone divergences / deferred candidates in Part 4, superseded paths in Part 5, and failed/reverted arms in Part 6, following Part 7) in [docs/BACKEND_KNOWLEDGE_BASE.md](../../../docs/BACKEND_KNOWLEDGE_BASE.md) in the same commit, then commit cleanly on `main` (zero AI attribution).
