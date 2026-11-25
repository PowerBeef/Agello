#!/bin/sh
# Antigravity PreToolUse hook: keeps release/App Store screenshot pipelines and
# macOS notarization blocked while allowing iOS Simulator UI & feature testing
# via the unshipped `AgelloSim` loopback bridge (`scripts/sim-launch.sh`).
# Hardware speed benchmarks, Metal kernels, and memory envelopes stay on real
# hardware (M6 Mac / physical iPhone).
set -u

input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.toolCall.name // empty' 2>/dev/null)"
mcp_server="$(printf '%s' "$input" | jq -r '.toolCall.args.ServerName // empty' 2>/dev/null)"
mcp_tool="$(printf '%s' "$input" | jq -r '.toolCall.args.ToolName // empty' 2>/dev/null)"
file_path="$(printf '%s' "$input" | jq -r '.toolCall.args.Path // .toolCall.args.AbsolutePath // .toolCall.args.path // empty' 2>/dev/null)"

deny() {
  jq -n --arg reason "$1" '{decision: "deny", reason: $reason}'
  exit 0
}

# 1. Block reading simulator-based App Store screenshot pipeline or macOS-only asc skills.
case "$file_path" in
  */asc-shots-pipeline/SKILL.md | */asc-shots-pipeline/*)
    deny "asc-shots-pipeline is forbidden for App Store screenshots in Agello. Capture release screenshots on the physical iPhone with scripts/device-harness.sh screenshots."
    ;;
  */asc-notarization/SKILL.md | */asc-notarization/*)
    deny "asc-notarization is for macOS distribution; Agello is an iPhone-only app."
    ;;
esac

# 2. Keep Axiom xclog blocked for physical iPhone log capture (use device-run.sh logs for hardware).
case "$tool_name:$mcp_server:$mcp_tool" in
  call_mcp_tool:axiom:axiom_xclog_*)
    deny "Axiom xclog tools are simulator-only. Use scripts/device-run.sh logs for physical iPhone log capture or xcrun simctl spawn log stream for AgelloSim."
    ;;
esac

exit 0
