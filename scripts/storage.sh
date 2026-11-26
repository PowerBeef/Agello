#!/bin/sh
# Agello's disk use on this Mac: every place the project writes, its size, and whether it's kept,
# to review, or scratch, against a budget.
# Usage:
#   scripts/storage.sh           the full report, largest first
#   scripts/storage.sh brief     a summary (the session-start hook and every harness run print it)
#   scripts/storage.sh clean     delete the scratch; never anything kept or to review
# Budget: the project stays under STORAGE_BUDGET_GB (40) and / keeps STORAGE_MIN_FREE_GB (50)
# free. Model files in the app containers are APFS clones of ~/Models/agello and count once
# (scripts/lib/clones.py checks their blocks). Ask the user before deleting a kept or reviewed item.
# shellcheck disable=SC2088 # labels show ~ for the reader; paths use $HOME
set -u
MODE="${1:-report}"
MAIN="$(cd "$(dirname "$0")/.." && pwd)"
# From a worktree, measure the main checkout's project.
common="$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
  MAIN="$(dirname "$common")"
PROJECTS="$(dirname "$MAIN")"
MODELS="$HOME/Models/agello"
CONTAINERS="$HOME/Library/Containers"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
BAZEL_BASE="/private/var/tmp/_bazel_$(id -un)"
BAZEL_DISK="$HOME/.cache/bazel-disk"
# The worktree's .bazelrc.user cap (6 GB), which Bazel enforces only while its server idles.
BAZEL_DISK_CAP_KB=$((${STORAGE_BAZEL_DISK_CAP_MB:-6144} * 1024))
BUDGET_GB="${STORAGE_BUDGET_GB:-40}"
MIN_FREE_GB="${STORAGE_MIN_FREE_GB:-50}"

# Fail loudly instead of silently returning 0 GB when run inside a restricted sandbox.
for probe in "$DERIVED" "$MODELS" "$PROJECTS/LiteRT-LM"; do
  if ls "$probe" 2>&1 >/dev/null | grep -q "Operation not permitted"; then
    echo "scripts/storage.sh: cannot read $probe (Operation not permitted — rerun outside the terminal sandbox for an accurate report)." >&2
    exit 5
  fi
done

ROWS="$(mktemp)"
trap 'rm -f "$ROWS" "$ROWS.sorted"' EXIT

# Size in KB, 0 when missing.
kb() { du -sk "$1" 2>/dev/null | awk '{print $1} END {if (!NR) print 0}'; }
# row <keep|review|scratch|clone> <KB> <label> [path]: one line of the report. Clones are listed
# but not counted; clean deletes only scratch rows, by path.
row() {
  [ "${2:-0}" -gt 0 ] 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$ROWS"
}
gb() { awk -v k="$1" 'BEGIN {if (k < 52429) print "<0.1 GB"; else printf "%.1f GB\n", k / 1048576}'; }
# list <status> [min KB]: the summary's lines for one status.
list() {
  awk -F'\t' -v s="$1" -v min="${2:-0}" '$1 == s && $2 >= min {
    printf "    - %s (%s)\n", $3, ($2 < 52429 ? "<0.1 GB" : sprintf("%.1f GB", $2 / 1048576))
  }' "$ROWS.sorted"
}

# The repository's build folder: the default harness outputs stay, one-off OUT folders go once
# their numbers are recorded.
repo_build="$(kb "$MAIN/build")"
for d in "$MAIN"/build/*; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  size="$(kb "$d")"
  case "$name" in
    device-harness | mac-harness) row keep "$size" "build/$name: the latest harness results" ;;
    cli)
      cli_sub=0
      for c in "$d"/*; do
        [ -d "$c" ] || continue
        cname="$(basename "$c")"
        csize="$(kb "$c")"
        case "$cname" in
          release | test) ;;
          test-home)
            cli_sub=$((cli_sub + ${csize:-0}))
            row scratch "$csize" "build/cli/test-home: sandboxed HOME for cli-test.sh (recreated on demand)" "$c" ;;
          traces)
            cli_sub=$((cli_sub + ${csize:-0}))
            row scratch "$csize" "build/cli/traces: standalone agello ask reply traces" "$c" ;;
          runs)
            cli_sub=$((cli_sub + ${csize:-0}))
            row review "$csize" "build/cli/runs: recorded cli-bench.sh runs (delete once their numbers are recorded)" ;;
          arms)
            cli_sub=$((cli_sub + ${csize:-0}))
            row review "$csize" "build/cli/arms: saved comparison arm checkouts" ;;
          *)
            cli_sub=$((cli_sub + ${csize:-0}))
            row scratch "$csize" "build/cli/$cname: comparison arm SwiftPM build cache (rebuilds on demand)" "$c" ;;
        esac
      done
      cli_kept=$((size - cli_sub))
      [ "$cli_kept" -lt 0 ] && cli_kept=0
      row keep "$cli_kept" "build/cli: Mac CLI release and test builds (plus runtime.log)" ;;
    bench-venv) row keep "$size" "build/bench-venv: pytest for the bench's checks (bench-report.py rebuilds it when missing)" ;;
    gbench)
      hf_ds=0
      if [ -d "$d/hf_datasets" ]; then
        hf_ds="$(kb "$d/hf_datasets")"
        row scratch "$hf_ds" "build/gbench/hf_datasets: cached HuggingFace eval datasets (re-downloaded on demand)" "$d/hf_datasets"
      fi
      kept=$((size - hf_ds))
      [ "$kept" -lt 0 ] && kept=0
      row keep "$kept" "build/gbench: local gbench checkout, venv, and eval results" ;;
    phone)
      phone_runs=0
      if [ -d "$d/runs" ]; then
        phone_runs="$(kb "$d/runs")"
        row review "$phone_runs" "build/phone/runs: recorded phone-bench.sh runs (delete once their numbers are recorded)"
      fi
      kept=$((size - phone_runs))
      [ "$kept" -lt 0 ] && kept=0
      row keep "$kept" "build/phone: phone-bench.sh state" ;;
    sim) row scratch "$size" "build/sim: AgelloSim simulator DerivedData and loopback serve logs" "$d" ;;
    playwright-mcp) row scratch "$size" "build/playwright-mcp: old Playwright browser scratch" "$d" ;;
    screens) row scratch "$size" "build/screens: old screenshot staging folder" "$d" ;;
    device-run) row scratch "$size" "build/device-run: ad-hoc device-run.sh logs and screenshots" "$d" ;;
    lab-3913) row scratch "$size" "build/lab-3913: historical #3913 lab artifacts (superseded by v2)" "$d" ;;
    crashes)
      crashes_sub=0
      for cf in "$d"/*; do
        [ -e "$cf" ] || continue
        cfname="$(basename "$cf")"
        cfsize="$(kb "$cf")"
        crashes_sub=$((crashes_sub + ${cfsize:-0}))
        case "$cfname" in
          iRTChat-*.ips) row scratch "$cfsize" "build/crashes/$cfname: pre-rename iRTChat crash log" "$cf" ;;
          *) row review "$cfsize" "build/crashes/$cfname: pulled crash log" ;;
        esac
      done
      rem=$((size - crashes_sub))
      [ "$rem" -gt 0 ] && row review "$rem" "build/crashes: other crash files" ;;
    drafts) row review "$size" "build/drafts: local notes and draft docs" ;;
    archive) row review "$size" "build/archive: quarantined historical research and notes" ;;
    device-harness-* | mac-harness-*)
      row scratch "$size" "build/$name: one-off harness results (once their numbers are recorded)" "$d" ;;
    *) row review "$size" "build/$name: unclassified build directory (classify in scripts/storage.sh)" ;;
  esac
done

# Worktrees: each has its own build/ and DerivedData; remove them once merged and done.
git -C "$MAIN" worktree list --porcelain 2>/dev/null |
  awk '/^worktree /{p = substr($0, 10)} /^branch /{b = substr($0, 19); print p "\t" b}' |
  while IFS="$(printf '\t')" read -r path branch; do
    [ "$path" = "$MAIN" ] && continue
    merged=""
    git -C "$MAIN" merge-base --is-ancestor "refs/heads/$branch" main 2>/dev/null && merged=", merged into main"
    row review "$(kb "$path")" "worktree $branch$merged: remove it once its session is done"
  done

# DerivedData: one folder per checkout path; a folder whose checkout is gone is scratch.
for d in "$DERIVED"/Agello-*; do
  [ -d "$d" ] || continue
  project="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null)"
  if [ -n "$project" ] && [ -e "$project" ]; then
    row keep "$(kb "$d")" "DerivedData for $(dirname "$project")"
  else
    row scratch "$(kb "$d")" "DerivedData of a checkout that's gone (${project:-unknown})" "$d"
  fi
done

# Models: the app's, the #3913 lab, agello-bench's cache, and engine caches written beside them.
models=0
for f in "$MODELS"/*; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  case "$name" in
    *.litertlm | embeddinggemma-2-text-270m-ane) models=$((models + $(kb "$f"))) ;;
    embeddinggemma-2-text-270m-ane.aar)
      if [ -f "$MODELS/embeddinggemma-2-text-270m-ane/text_encoder.aimodel/main.mlirb" ] \
        && [ -f "$MODELS/embeddinggemma-2-text-270m-ane/embed_tokens.bin" ] \
        && [ -f "$MODELS/embeddinggemma-2-text-270m-ane/tokenizer.model" ]; then
        row scratch "$(kb "$f")" "~/Models/agello/$name: archive already unpacked to embeddinggemma-2-text-270m-ane/" "$f"
      else
        models=$((models + $(kb "$f")))
      fi ;;
    lab)
      # agello-bench's runs without --cache leave engine caches beside the lab models.
      lab=0
      for g in "$f"/*; do
        case "$(basename "$g")" in
          *_cache.bin | *.xnnpack_cache)
            row scratch "$(kb "$g")" "~/Models/agello/lab/$(basename "$g"): an engine cache written beside a lab model" "$g" ;;
          *-cache)
            # A lab model's engine caches (`agello ask --cache ~/Models/agello/lab/<model>-cache`):
            # one folder per runtime build, about 2.3 GB each. As for the command line's caches,
            # the two loaded last stay; an older build's folder is scratch.
            count=0
            # shellcheck disable=SC2012,SC2045 # newest first; the folders are named by build ids
            for h in $(ls -td "$g"/*/ 2>/dev/null); do
              h="${h%/}"
              count=$((count + 1))
              if [ "$count" -le 2 ]; then
                lab=$((lab + $(kb "$h")))
              else
                row scratch "$(kb "$h")" "~/Models/agello/lab/$(basename "$g")/$(basename "$h"): a lab model's GPU cache for an older runtime build" "$h"
              fi
            done ;;
          *) lab=$((lab + $(kb "$g"))) ;;
        esac
      done
      row keep "$lab" "~/Models/agello/lab: lab models and probe suites (the #3913 exports were deleted on 2026-11-03; a new round's files are scratch once its numbers are recorded)" ;;
    cache)
      # The Mac command line keeps one cache folder per runtime build (about 2.5 GB each), across
      # agello-cli/ and any custom --cache roots (agello-cli-*/), and every rebuilt runtime adds
      # one. The two loaded last stay (what ships, and the build being compared with it); an older
      # build's cache is scratch: it recompiles in one load.
      old=0
      count=0
      seen="|"
      # shellcheck disable=SC2012 # the folders are named by build ids
      builds="$(ls -td "$f"/agello-cli/*/kv-all-* "$f"/agello-cli-*/*/kv-all-* "$f"/agello-cli/kv-all-* "$f"/agello-cli-*/kv-all-* 2>/dev/null)"
      saved_ifs="$IFS"
      IFS='
'
      for g in $builds; do
        [ -d "$g" ] || continue
        parent="$(dirname "$g")"
        if [ "$(dirname "$parent")" = "$f" ]; then
          # Direct child of agello-cli/ or agello-cli-*/ (AGELLO_ENGINE_CACHE_DIR set to the root).
          count=$((count + 1))
          [ "$count" -le 2 ] && continue
          size="$(kb "$g")"
          old=$((old + ${size:-0}))
          row scratch "$size" "~/Models/agello/cache/${g#"$f"/}: the Mac command line's GPU cache for an older runtime build" "$g"
          build_id="$(basename "$g")"
          emb="$parent/embedding-${build_id#kv-all-}"
          if [ -d "$emb" ]; then
            emb_size="$(kb "$emb")"
            old=$((old + ${emb_size:-0}))
            row scratch "$emb_size" "~/Models/agello/cache/${emb#"$f"/}: the Mac command line's embedding cache for an older runtime build" "$emb"
          fi
        else
          case "$seen" in
            *"|$parent|"*) continue ;;
          esac
          seen="$seen$parent|"
          count=$((count + 1))
          [ "$count" -le 2 ] && continue
          size="$(kb "$parent")"
          old=$((old + ${size:-0}))
          row scratch "$size" "~/Models/agello/cache/${parent#"$f"/}: the Mac command line's GPU cache for an older runtime build" "$parent"
        fi
      done
      IFS="$saved_ifs"
      kept_cache=$(($(kb "$f") - old))
      [ "$kept_cache" -lt 0 ] && kept_cache=0
      row keep "$kept_cache" "~/Models/agello/cache: the GPU caches of agello-bench (--cache) and of the Mac command line (agello-cli*/, one folder per runtime build; the two loaded last are kept)" ;;
    revisions.txt) ;;
    *_cache.bin | *.xnnpack_cache | *cache*)
      row scratch "$(kb "$f")" "~/Models/agello/$name: an engine cache written beside the models" "$f" ;;
    *) row review "$(kb "$f")" "~/Models/agello/$name: not a model the app or the lab uses" ;;
  esac
done
row keep "$models" "~/Models/agello: the app's models"

# The app's container on this Mac: the iPhone app run here (a UUID folder).
for meta in "$CONTAINERS"/*/.com.apple.containermanagerd.metadata.plist; do
  grep -q "com\.patricedery\.agello" "$meta" 2>/dev/null || continue
  id="$(/usr/libexec/PlistBuddy -c 'Print :MCMMetadataIdentifier' "$meta" 2>/dev/null)"
  case "$id" in
    com.patricedery.agello) app="the iPhone app on this Mac" ;;
    *) continue ;;
  esac
  data="$(dirname "$meta")/Data"
  counted=0
  # Engine caches: EngineCache keeps the loaded build's folders and deletes the others at the
  # next load; until then another build's folders are scratch.
  caches="$data/Library/Caches/com.patricedery.agello.litertlm"
  # shellcheck disable=SC2012 # EngineCache's folder names are plain
  current="$(ls -t "$caches" 2>/dev/null | sed -n 's/^kv-all-//p' | head -n 1)"
  kept=0
  for c in "$caches"/*; do
    [ -e "$c" ] || continue
    size="$(kb "$c")"
    counted=$((counted + ${size:-0}))
    case "$(basename "$c")" in
      *-"$current") kept=$((kept + ${size:-0})) ;;
      *) if [ -n "$current" ]; then
           row scratch "$size" "$app: engine cache $(basename "$c") from another runtime build" "$c"
         else
           kept=$((kept + ${size:-0}))
         fi ;;
    esac
  done
  row keep "$kept" "$app: engine caches for the loaded runtime (a load takes 0.8 s with them, 7.5 s without)"
  # Model copies left in Caches (probe 3 kept its own EmbeddingGemma there until 2026-11-01).
  for f in "$data"/Library/Caches/*.litertlm; do
    [ -f "$f" ] || continue
    size="$(kb "$f")"
    counted=$((counted + ${size:-0}))
    row scratch "$size" "$app: a model copy in Caches ($(basename "$f"))" "$f"
  done
  # Models and lab models: clones of ~/Models/agello cost nothing; a full copy is to review.
  clones=0
  set -- "$data/Library/Application Support/Models"/*.litertlm "$data"/Documents/lab/*.litertlm
  files=""
  for f in "$@"; do [ -f "$f" ] && files=1; done
  if [ -n "$files" ]; then
    while IFS="$(printf '\t')" read -r kind size path; do
      counted=$((counted + size))
      if [ "$kind" = clone ]; then
        clones=$((clones + size))
      else
        row review "$size" "$app: $(basename "$path") is a full copy, not a clone (cp -c ~/Models/agello/… instead)"
      fi
    done <<EOF
$(for f in "$@"; do [ -f "$f" ] && printf '%s\n' "$f"; done | tr '\n' '\0' | xargs -0 python3 -I "$MAIN/scripts/lib/clones.py" "$MODELS")
EOF
  fi
  ane_dir="$data/Library/Application Support/Models/embeddinggemma-2-text-270m-ane"
  if [ -d "$ane_dir" ]; then
    ane_total="$(kb "$ane_dir")"
    counted=$((counted + ${ane_total:-0}))
    ane_out="$(python3 -I - "$MODELS/embeddinggemma-2-text-270m-ane" "$ane_dir" <<'PY'
import fcntl, os, struct, sys

F_LOG2PHYS_EXT = 65
ref_root, dst_root = sys.argv[1], sys.argv[2]

def blocks(path):
    size = os.path.getsize(path)
    if size == 0:
        return ()
    fd = os.open(path, os.O_RDONLY)
    try:
        out = []
        for offset in (0, (size // 2) & ~4095, max(size - 1, 0) & ~4095):
            res = fcntl.fcntl(fd, F_LOG2PHYS_EXT, struct.pack("<Iqq", 0, 4096, offset))
            out.append(struct.unpack("<Iqq", res)[2])
        return tuple(out)
    except OSError:
        return None
    finally:
        os.close(fd)

clone_kb = own_kb = 0
for folder, _, names in os.walk(dst_root):
    for name in names:
        dst = os.path.join(folder, name)
        if not os.path.isfile(dst) or os.path.islink(dst):
            continue
        kb = (os.stat(dst).st_blocks + 1) // 2
        rel = os.path.relpath(dst, dst_root)
        ref = os.path.join(ref_root, rel)
        dst_b = blocks(dst) if os.path.isfile(ref) else None
        ref_b = blocks(ref) if dst_b is not None else None
        if dst_b is not None and ref_b is not None and dst_b == ref_b:
            clone_kb += kb
        else:
            own_kb += kb
print(f"{clone_kb} {own_kb}")
PY
)"
    ane_clone="${ane_out%% *}"
    ane_own="${ane_out#* }"
    if [ "${ane_own:-0}" -gt 0 ]; then
      clones=$((clones + ${ane_clone:-0}))
      row review "$ane_own" "$app: embeddinggemma-2-text-270m-ane is a full copy, not a clone (cp -cR ~/Models/agello/embeddinggemma-2-text-270m-ane … instead)"
    else
      clones=$((clones + ${ane_total:-0}))
    fi
  fi
  row clone "$clones" "$app: model files that are clones of ~/Models/agello (no extra space)"
  rest=$(($(kb "$data") - counted))
  [ "$rest" -lt 0 ] && rest=0
  row keep "$rest" "$app: chats, files and settings"
done

# Bazel: the output base (incremental fork builds), its disk cache (capped) and downloads.
row keep "$(kb "$BAZEL_BASE")" "Bazel's output base for the fork (bazelisk clean --expunge in ../LiteRT-LM frees it)"
disk="$(kb "$BAZEL_DISK")"
if [ "${disk:-0}" -gt "$BAZEL_DISK_CAP_KB" ]; then
  row keep "$BAZEL_DISK_CAP_KB" "~/.cache/bazel-disk: Bazel's disk cache, up to its cap"
  row scratch $((disk - BAZEL_DISK_CAP_KB)) "~/.cache/bazel-disk beyond its cap (clean trims the oldest entries)" "$BAZEL_DISK"
else
  row keep "${disk:-0}" "~/.cache/bazel-disk: Bazel's disk cache (6 GB cap)"
fi
row keep "$(kb "$HOME/.cache/bazel-repo")" "~/.cache/bazel-repo: Bazel's downloads"

# The shared Hugging Face cache holds other projects' models and isn't counted. A repo of ours
# there means an `hf download` without --local-dir: a second copy of a model.
hub="$HOME/.cache/huggingface/hub"
for d in "$hub"/models--PowerBeef02--* "$hub"/models--litert-community--* "$hub"/models--mlboydaisuke--*; do
  [ -d "$d" ] || continue
  repo="$(basename "$d" | sed 's/^models--//; s/--/\//')"
  row review "$(kb "$d")" "~/.cache/huggingface: $repo, a project model in the shared HF cache (download with --local-dir; remove with hf cache rm $repo)"
done

# The fork checkouts, with agello-bench builds and release files apart.
bench="$PROJECTS/LiteRT-LM/tools/agello-bench"
benches=0
for b in "$bench"/.build-*; do
  [ -d "$b" ] || continue
  size="$(kb "$b")"
  benches=$((benches + ${size:-0}))
  case "$(basename "$b")" in
    .build-next) row keep "$size" "agello-bench's build of our runtime (.build-next)" ;;
    *) row review "$size" "agello-bench's $(basename "$b"): keep one build per arm in use" ;;
  esac
done
releases=0
for r in "$PROJECTS"/LiteRT-LM/dist/release/*; do
  [ -d "$r" ] || continue
  size="$(kb "$r")"
  releases=$((releases + ${size:-0}))
  row review "$size" "release files for $(basename "$r") in the fork's checkout (delete once published)"
done
row keep $(($(kb "$PROJECTS/LiteRT-LM") - benches - releases)) "../LiteRT-LM: the runtime's checkout (branch main) and its build"
# The repository itself, without build/ (counted above).
row keep $(($(kb "$MAIN") - ${repo_build:-0})) "this repository"

sort -t "$(printf '\t')" -k2,2nr "$ROWS" >"$ROWS.sorted"
total="$(awk -F'\t' '$1 != "clone" {s += $2} END {print s + 0}' "$ROWS.sorted")"
scratch="$(awk -F'\t' '$1 == "scratch" {s += $2} END {print s + 0}' "$ROWS.sorted")"
free_kb="$(df -k / | awk 'NR == 2 {print $4}')"
budget_kb=$((BUDGET_GB * 1048576))

summary() {
  echo "- Storage: the project takes $(gb "$total") of its ${BUDGET_GB} GB budget; $(gb "$free_kb") free on / (keep ${MIN_FREE_GB} GB). \`scripts/storage.sh\` itemizes it."
  if [ "$scratch" -gt 0 ]; then
    echo "  - Scratch, $(gb "$scratch"): run \`scripts/storage.sh clean\` (no harness run in progress):"
    list scratch
  fi
  # Items to review from 0.1 GB (the report lists the smaller ones).
  if awk -F'\t' '$1 == "review" && $2 >= 104858 {found = 1} END {exit !found}' "$ROWS.sorted"; then
    echo "  - To review with the user:"
    list review 104858
  fi
  if [ "$total" -gt "$budget_kb" ]; then
    echo "  - Over budget. The largest items:"
    awk -F'\t' '$1 != "clone" && n < 3 {printf "    - %s (%.1f GB)\n", $3, $2 / 1048576; n++}' "$ROWS.sorted"
    echo "    Clean the scratch, then ask the user which kept items can go."
  fi
  if [ "$free_kb" -lt $((MIN_FREE_GB * 1048576)) ]; then
    echo "  - Under ${MIN_FREE_GB} GB free on /: clean up before a build or a run."
  fi
}

case "$MODE" in
  brief) summary ;;
  report)
    echo "Agello's disk use, $(date +%Y-%m-%d):"
    awk -F'\t' '{size = $2 < 52429 ? "   <0.1" : sprintf("%7.1f", $2 / 1048576); printf "%s GB  %-7s %s\n", size, $1, $3}' "$ROWS.sorted"
    echo
    summary
    ;;
  clean)
    . "$MAIN/scripts/lib/harness-lock.sh"
    if harness_lock_info "$(harness_lock_dir "$MAIN")" >/dev/null; then
      echo "A harness run is in progress: clean after it ends." >&2
      exit 3
    fi
    awk -F'\t' '$1 == "scratch" {print $2 "\t" $4 "\t" $3}' "$ROWS.sorted" |
      while IFS="$(printf '\t')" read -r size path label; do
        case "$path" in
          "$BAZEL_DISK")
            # Oldest first, down to the cap.
            excess=$((size * 1024))
            find "$BAZEL_DISK" -type f -exec stat -f '%m %z %N' {} + | sort -n |
              awk -v e="$excess" '$0 && s < e {s += $2; sub(/^[0-9]+ [0-9]+ /, ""); print}' |
              tr '\n' '\0' | xargs -0 rm -f
            ;;
          "$MAIN"/build/* | "$DERIVED"/Agello-* | "$MODELS"/* | "$CONTAINERS"/*/Data/Library/Caches/*)
            rm -rf "$path"
            ;;
          *) echo "Skipped $path: outside the folders clean may touch." >&2; continue ;;
        esac
        echo "Deleted $label ($(gb "$size"))."
      done
    exec "$0" brief
    ;;
  *) echo "Usage: scripts/storage.sh [report|brief|clean]" >&2; exit 2 ;;
esac
