#!/bin/sh
# Antigravity PreToolUse hook: enforces Agello's physical-iPhone-only rule by
# blocking simulator MCP tools, simulator-only Axiom tools/agents, and
# simulator/macOS-only asc skills.
set -u

input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.toolCall.name // empty' 2>/dev/null)"
mcp_server="$(printf '%s' "$input" | jq -r '.toolCall.args.ServerName // empty' 2>/dev/null)"
mcp_tool="$(printf '%s' "$input" | jq -r '.toolCall.args.ToolName // empty' 2>/dev/null)"
mcp_agent="$(printf '%s' "$input" | jq -r '.toolCall.args.Arguments.name // .toolCall.args.Arguments.agent // empty' 2>/dev/null)"
file_path="$(printf '%s' "$input" | jq -r '.toolCall.args.Path // .toolCall.args.AbsolutePath // .toolCall.args.path // empty' 2>/dev/null)"

deny() {
  jq -n --arg reason "$1" '{decision: "deny", reason: $reason}'
  exit 0
}

# 1. Block simulator tools (lazy call_mcp_tool or eager mcp_* names).
case "$tool_name" in
  call_mcp_tool)
    case "$mcp_server:$mcp_tool" in
      mobilebuildmcp:list_sims | mobilebuildmcp:boot_sim | mobilebuildmcp:open_sim | mobilebuildmcp:*_sim | mobilebuildmcp:*_sim_*)
        deny "Agello runs on physical iPhone hardware only (our LiteRT-LM runtime has no simulator build). Simulator tools in mobilebuildmcp are blocked here; use scripts/device-harness.sh instead."
        ;;
      axiom:axiom_xclog_*)
        deny "Axiom xclog tools are simulator-only. Use scripts/device-run.sh logs for physical iPhone log capture."
        ;;
      axiom:axiom_get_agent)
        case "$mcp_agent" in
          *simulator-tester*)
            deny "Axiom's simulator-tester agent is blocked in Agello (physical iPhone hardware only)."
            ;;
        esac
        ;;
    esac
    ;;
  mcp_*sim* | mcp_*xclog*)
    deny "Simulator MCP tools are blocked in Agello (physical iPhone hardware only). Use scripts/device-harness.sh or scripts/device-run.sh instead."
    ;;
esac

# 2. Block reading simulator-based or macOS-only asc skills.
case "$file_path" in
  */asc-shots-pipeline/SKILL.md | */asc-shots-pipeline/*)
    deny "asc-shots-pipeline is simulator-based and forbidden in Agello. Capture screenshots on the physical iPhone with scripts/device-harness.sh screenshots."
    ;;
  */asc-notarization/SKILL.md | */asc-notarization/*)
    deny "asc-notarization is for macOS distribution; Agello is an iPhone-only app."
    ;;
esac

exit 0
