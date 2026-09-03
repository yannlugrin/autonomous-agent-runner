# shellcheck shell=bash
# Which Claude Code answers inside the image, sourced by host/verify/verify.sh.
#
# On the real service and not the twin: the drift being looked for lives in
# the agent's home, and the twin has no volume — it would agree with the pin
# forever and pass in the same words. Nothing here writes.
# see docs/verify.md#claude-code

echo
echo "== claude code version =="


# --- claude code ---
# Asked as three values, because a version has two ways to be wrong, they have
# different fixes, and both read as "pinned" from anywhere else.
#
# The pin in the Dockerfile installs a version; nothing on its own keeps one.
# PATH puts ~/.npm-global/bin and ~/.local/bin — both inside the volume — ahead
# of /usr/local/bin, so a `claude` installed by hand or by the CLI's own updater
# wins the lookup and outlives every rebuild. DISABLE_AUTOUPDATER closes the
# automatic half; this notices the rest.
#
# ARG vs ENV is an image built before the line you are reading, fixed by a
# rebuild; ENV vs PATH is something in the volume shadowing it, which a rebuild
# does not touch. A single "does it match the pin" would name neither.

pin=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' image/Dockerfile | head -1)

# Through PATH — `claude`, never the pinned path, which would report the
# pin back to itself. `command -v` comes along so a mismatch names the
# file to look at rather than leaving someone to find it.

read -r baked running where <<<"$(docker compose run --rm -T --entrypoint sh agent -c '
    v=$(claude --version 2>/dev/null | cut -d" " -f1)
    printf "%s %s %s\n" "${AGENT_CLAUDE_VERSION:-unset}" "${v:-unreadable}" "$(command -v claude || echo none)"' 2>/dev/null | tail -1)"

printf '         %-22s %s\n' "pinned in Dockerfile:" "${pin:-UNREADABLE}"
printf '         %-22s %s\n' "built into the image:" "${baked:-UNREADABLE}"
printf '         %-22s %s\n' "answering on PATH:" "${running:-UNREADABLE}"

if [ -z "$pin" ]; then
    verdict FAIL "claude code" "UNREADABLE — image/Dockerfile has no ARG CLAUDE_CODE_VERSION line to compare against"
elif [ "$baked" = "unset" ] || [ -z "$baked" ]; then
    verdict FAIL "claude code" "IMAGE PREDATES THIS CHECK — it carries no AGENT_CLAUDE_VERSION. Rebuild it: 'just verify --build'. Until then nothing here can tell a shadowed binary from a correct one."
elif [ "$pin" != "$baked" ]; then
    verdict FAIL "claude code" "STALE IMAGE — built for $baked, the tree now pins $pin. The image predates the Dockerfile in front of you. 'just verify --build'."
elif [ "$running" = "unreadable" ] || [ -z "$running" ]; then
    verdict FAIL "claude code" "UNREADABLE — 'claude --version' printed nothing usable at $where. Every session start runs that binary, so this is not cosmetic."
elif [ "$baked" != "$running" ]; then
    verdict FAIL "claude code" "SHADOWED — the image installed $baked, but $running answers, from $where. PATH prefers the volume's own bin directories, so this survives a rebuild: remove that binary in the volume, or move the pin to match it deliberately."
elif [ "$where" != "/usr/local/bin/claude" ]; then
    # The numbers agreeing is not the question: what matters is whether the
    # image's own binary is the one answering, and the two come apart when the
    # version the updater installed happens to match — the comparison goes
    # quiet while a frozen copy in the volume defeats the next pin move.
    #
    # The path is written out rather than derived: if the image's npm prefix
    # ever moves, this says SHADOWED about a correct install, a false alarm
    # someone reads — the other direction passes without being read.
    verdict FAIL "claude code" "SHADOWED, SAME VERSION — $running answers, but from $where and not the image's /usr/local/bin/claude. The numbers agree today, so nothing else says so, but the lookup is being won by a copy in the volume that no rebuild replaces. Remove it; the image is meant to be the only source of this fact."
else
    verdict ok "claude code" "$running, from $where, is the version the image was built for"
fi

echo
