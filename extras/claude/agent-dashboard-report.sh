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
source="$(printf '%s' "$input" | jq -r '.source // "startup"' 2>/dev/null || echo startup)"

# Hook commands can be launched through one or more shell wrappers. Attribute
# the report to Claude itself so Neovim does not mistake the short-lived hook
# process for the owner of the slot.
claude_pid=0
pid="$PPID"
while [ "$pid" -gt 1 ] 2>/dev/null; do
    parent="$(ps -o ppid= -o comm= -p "$pid" 2>/dev/null || true)"
    [ -n "$parent" ] || break
    read -r parent_pid process_name <<< "$parent"
    process_name="${process_name##*/}"
    case "$process_name" in
        claude|claude-code) claude_pid="$pid"; break ;;
    esac
    [ -n "${parent_pid:-}" ] || break
    pid="$parent_pid"
done

case "$action" in
    start)
        previous_session="$(jq -r '.session // empty' "$state_file" 2>/dev/null || true)"
        if [ "$source" = "startup" ] || [ "$source" = "clear" ] || [ "$previous_session" != "$session" ]; then
            echo 0 > "$turn_file"
            turn=0
        else
            turn="$(cat "$turn_file" 2>/dev/null || echo 0)"
        fi
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
    --argjson pid "$claude_pid" \
    --arg state "$state" \
    --argjson time "$(date +%s)" \
    '{slot: $slot, time: $time, session: $session, turn: $turn, state: $state, agent: $agent} + (if $pid > 1 then {pid: $pid} else {} end)' \
    > "$tmp"
mv "$tmp" "$state_file"

topic="${NVIM_AGENT_TOPIC:-topic}"
topic_dir="${NVIM_AGENT_TOPIC_DIR:-}"
brief_limit=150
attachment="$NVIM_AGENT_DASHBOARD_DIR/$NVIM_AGENT_SLOT.topic"
if [ -f "$attachment" ]; then
    { IFS= read -r topic || true; IFS= read -r topic_dir || true; IFS= read -r brief_limit || true; } < "$attachment"
fi
case "$brief_limit" in ''|*[!0-9]*|0) brief_limit=150 ;; esac
if [ "$action" = "start" ] && [ -n "$topic_dir" ]; then
    brief="$topic_dir/brief.md"
    if [ -r "$brief" ]; then
        printf 'You are working on the topic "%s". Read its notes when useful: %s/notes\n' \
            "$topic" "$topic_dir"
        printf 'Topic brief (%s):\n---\n' "$brief"
        count=0
        while IFS= read -r line || [ -n "$line" ]; do
            [ "$count" -lt "$brief_limit" ] || break
            printf '%s\n' "$line"
            count=$((count + 1))
        done < "$brief"
        printf '\n---\n'
    fi
fi
