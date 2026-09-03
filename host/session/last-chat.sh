#!/usr/bin/env bash
# Which session the last conversation was, read from the volume.
#
# Runs on the host, through a throwaway container, read-only — the same shape
# as host/archive/read-volume.sh and for the same reason.
#
# The fallback under ~/.cache/agent-last-chat, which is the exact answer but
# only knows the conversations started since it began being written: the cache
# is a shortcut, the volume is the truth.
#
# A conversation is told from a session by the bracket `just chat` puts in front
# of the operator's message — the line rule 1 rests on. The bracket is passed in
# rather than written here: one definition in the justfile, used by the recipe
# that writes it and by this, which reads it.
#
# The grep narrows and does not decide, so each candidate's first user message
# is parsed and checked, newest first. Ordered by mtime rather than by that
# message's timestamp: what is wanted is the conversation last spoken in, and a
# resumed old chat is the most recent one again.
# see docs/sessions.md#reading-the-volume-for-a-conversation
#
# Usage:  last-chat.sh <marker>   -> prints a session id, or nothing
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MARKER="${1:-}"
[ -n "$MARKER" ] || { echo "last-chat.sh needs the marker that identifies a conversation." >&2; exit 2; }

VOLUME="${AGENT_VOLUME:?not set — run this through 'just', which derives it from the agent name}"
IMAGE="${RUNNER_EXTRACT_IMAGE:-alpine:3}"

# One container, one pass. For each transcript holding the marker anywhere, its
# id and its first user line — which is one line of JSON, so it survives being
# carried out on a stream and parsed on this side. Root inside, because the
# transcripts are 0600 owned by uid 1001; nothing is written anywhere.
candidates=$(docker run --rm -v "$VOLUME":/vol:ro -e MARKER="$MARKER" "$IMAGE" sh -c '
    cd /vol/.claude/projects 2>/dev/null || exit 0
    grep -rlF -- "$MARKER" . 2>/dev/null | while read -r f; do
        printf "%s\t%s\n" "$(stat -c %Y "$f")" "$f"
    done | sort -rn | cut -f2- | while read -r f; do
        printf "=== %s\n" "$(basename "$f" .jsonl)"
        grep -m1 "\"type\":\"user\"" "$f" 2>/dev/null
    done' 2>/dev/null) || exit 1

[ -n "$candidates" ] || exit 1

printf '%s' "$candidates" | MARKER="$MARKER" python3 -c '
import json, os, sys

marker = os.environ["MARKER"]
session = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("=== "):
        session = line[4:]
        continue
    if session is None:
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        # A first user line that will not parse is not a conversation this can
        # vouch for. Skipping it costs one resume; guessing costs the wrong one.
        session = None
        continue
    content = entry.get("message", {}).get("content")
    if isinstance(content, list):
        content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    if (not entry.get("isSidechain")) and isinstance(content, str) and marker in content:
        print(session)
        break
    session = None
'
