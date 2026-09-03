#!/usr/bin/env bash
# SessionEnd hook — back the agent's repository up to origin, best-effort.
#
# It lives in the image and is registered in managed settings, not in the
# repository it protects: a hook the agent could blank would stop backing up
# with no symptom at all, because ERROR_ON_PUSH only appears when the hook runs
# and fails. Push is a backup, never a task — local state is the truth and
# survives in the volume, so a failed push costs a retry, not the work.
#
# SessionEnd is fire-and-forget and its stderr reaches nobody, so the outcome is
# written to disk for the next session to read at start. Never exits non-zero: a
# failed backup must not look like a broken session.
# see docs/backup.md#why-the-hook-lives-in-the-image

set -uo pipefail   # deliberately not -e: every failure here is handled

# The agent's own namespace. The container's account is the agent, so `id -un`
# is the authority. Two `tr`s because mixing a character class with a literal in
# one set is not portable, and a shell name cannot hold a dash.
# shellcheck disable=SC2018,SC2019 # usernames are ASCII-only here
AGENT_PREFIX="$(id -un | tr 'a-z' 'A-Z' | tr '-' '_')"
agent_var() { local _n="${AGENT_PREFIX}_$1"; printf '%s' "${!_n-}"; }

# The repository is named, never derived from this script's location: the script
# lives in the image, at a path with no relation to the checkout.
# ${AGENT_PREFIX}_REPO_DIR is compose's answer to "which repository is the
# agent's", so a session that spent its time inside some cloned project still
# backs up the right one.
repo="$(agent_var REPO_DIR)"
repo="${repo:-${CLAUDE_PROJECT_DIR:-$HOME/$(id -un)}}"
cd "$repo" 2>/dev/null || exit 0
state="$repo/ERROR_ON_PUSH"

record_failure() {
    # Consecutive failures. One is a hiccup the next session repairs; three is
    # an expired credential or a dead remote, and the session that reads this
    # escalates to the operator rather than retrying forever.
    n=1
    if [ -f "$state" ]; then
        prev="$(sed -n 's/^consecutive: //p' "$state" | head -1)"
        case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
        n=$(( prev + 1 ))
    fi
    {
        printf 'when: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'head: %s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
        printf 'branch: %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        printf 'consecutive: %s\n' "$n"
        printf 'reason: %s\n' "$1"
        printf 'detail: |\n'
        printf '%s\n' "$2" | sed 's/^/  /'
    } > "$state"
    exit 0
}

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git rev-parse HEAD      >/dev/null 2>&1 || exit 0   # nothing committed yet

if ! git remote get-url origin >/dev/null 2>&1; then
    record_failure "no-remote" "no origin is configured; there is nothing to back up to"
fi

# ---------------------------------------------------------------------------
# Ask the guard first. This hook is the path by which everything in this
# repository actually reaches origin, and a PreToolUse guard reads argv — which
# a git call from inside a SessionEnd script never presents. It is the same
# guard asked the same way Claude Code asks it, rather than a second
# implementation of the check that would drift from the first; its span is
# precisely what the three calls below send.
#
# Fail closed, and the two failures are not symmetric: a backup that does not
# happen costs a retry and announces itself at the next session start, while a
# secret that reaches origin cannot be undone by anything the agent can do.
# `ask` counts as no — there is nobody here to ask.
# see docs/backup.md#fail-closed-and-why-the-two-sides-differ
guard=/usr/local/bin/bash-guard.py

if [ ! -x "$guard" ]; then
    record_failure "guard-unavailable" \
        "$guard is missing or not executable, so what this push would carry
could not be checked. Nothing was pushed. The commits are safe in the
volume; run just verify to find out what happened to the guard."
fi

# An outer bound as well as the guard's own: a guard that hangs would be killed
# by the hook's 60s timeout, and a killed hook writes no flag at all. The point
# of this one is to leave time to record why.
payload="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git push"}}' "$repo")"
if ! verdict="$(printf '%s' "$payload" | timeout 30 "$guard" 2>&1)"; then
    record_failure "guard-failed" \
        "the guard did not answer, so what this push would carry could not be
checked. Nothing was pushed.
$verdict"
fi

case "$verdict" in
    *'"permissionDecision": "deny"'* | *'"permissionDecision": "ask"'*)
        reason="$(printf '%s' "$verdict" | python3 -c \
            'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' \
            2>/dev/null || printf '%s' "$verdict")"
        record_failure "refused-by-guard" \
            "nothing was pushed. The guard refused what this push would carry:
$reason"
        ;;
esac

# Three calls, not one, and not one clever one. `git push origin HEAD` saves the
# current branch and nothing else; `--all --tags` together is refused by git;
# and HEAD stays beside --all because `push --all` on a detached HEAD exits 0
# without a word about the commit you are sitting on, trading a loud failure for
# a silent one. refs/notes/* is deliberately not sent — nothing here has ever
# written one, and it is one line to add on the day something does.
#
# All three are attempted even after one fails, so a single flag carries the
# whole picture rather than only the first thing to go wrong.
# see docs/backup.md#three-pushes-not-one-clever-one
failed=""
detail=""
attempt() {
    label="$1"
    shift
    if ! out="$(git push origin "$@" 2>&1)"; then
        failed="${failed:+$failed, }$label"
        detail="${detail}--- git push origin $label ---
$out
"
    fi
}

attempt HEAD HEAD
attempt --all --all
attempt --tags --tags

if [ -n "$failed" ]; then
    record_failure "push-failed: $failed" "$detail"
fi

rm -f "$state"
exit 0
