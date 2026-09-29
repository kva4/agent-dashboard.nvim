#!/usr/bin/env bash
# Claude Code hook reporter for agent-dashboard.nvim. No-op outside a dashboard terminal.
# Usage: agent-dashboard-report.sh <start|working|blocked|idle|end>
set -euo pipefail

action="${1:?usage: agent-dashboard-report.sh <start|working|blocked|idle|end>}"

[ -n "${NVIM_AGENT_DASHBOARD_DIR:-}" ] && [ -n "${NVIM_AGENT_SLOT:-}" ] || exit 0

state_file="$NVIM_AGENT_DASHBOARD_DIR/$NVIM_AGENT_SLOT.json"
turn_file="$NVIM_AGENT_DASHBOARD_DIR/$NVIM_AGENT_SLOT.turn"

if [ "$action" = "end" ]; then
    rm -f "$state_file" "$turn_file"
    exit 0
fi

input="$(cat 2>/dev/null || true)"
session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"

case "$action" in
    start)
        echo 0 > "$turn_file"
        turn=0
        state=idle
        ;;
    idle)
        turn=$(( $(cat "$turn_file" 2>/dev/null || echo 0) + 1 ))
        echo "$turn" > "$turn_file"
        state=idle
        ;;
    working|blocked)
        turn="$(cat "$turn_file" 2>/dev/null || echo 0)"
        state="$action"
        ;;
    *)
        exit 1
        ;;
esac

tmp="$(mktemp "$state_file.XXXXXX")"
jq -n \
    --argjson slot "$NVIM_AGENT_SLOT" \
    --arg agent claude \
    --arg session "$session" \
    --argjson turn "$turn" \
    --arg state "$state" \
    --argjson time "$(date +%s)" \
    '{slot: $slot, time: $time, session: $session, turn: $turn, state: $state, agent: $agent}' \
    > "$tmp"
mv "$tmp" "$state_file"
