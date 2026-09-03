#!/usr/bin/env bash
# What has moved in the agent's operating context since a frozen baseline.
#
# Runs on the host, on the operator's own Claude login. No container and no
# credential of the agent's: a Claude session starts here, reads a read-only
# clone of the archive's mirror of the agent's memory, and writes one report
# under monitor/. Nothing it produces reaches the agent, and nothing it reads is
# authority over it — the corpus is written by an agent that quotes the open
# web, so the auditor is told to treat every instruction in it as a finding.
#
# The session is confined by its own settings and nothing else:
# `--setting-sources ""` turns off every file-based source, so what is in force
# is host/monitor/drift-audit/settings.json alone. Permission arrays merge
# across sources, and an empty source list is the only way to be sure of what is
# in effect.
#
# Two anchors. `baseline` is frozen and moves only under `just drift-accept`:
# the cumulative sections run against it, because slow drift is visible only
# cumulatively. `cursor` is the head of the last completed audit, and the
# incremental sections run against that.
# see docs/monitor.md#the-two-anchors
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/monitor/clone.sh


# --- the clone ---
# Current before anything reads it, and on the mirrored content: the auditor is
# told the clone will not move while it works, and a reset here is what makes
# that true.

sync_clone

mkdir -p "$AUDIT_STATE" "$AUDIT_REPORTS" "$(dirname "$AUDIT_LOG")" || exit 1

git -C "$AUDIT_CLONE" reset --hard -q refs/remotes/mirror/source || exit 1
head=$(git -C "$AUDIT_CLONE" rev-parse HEAD) || exit 1


# --- the anchors ---
# The first run has nothing to compare against, so it freezes the baseline and
# stops. Edit state/baseline.sha by hand to start from an earlier commit.

if [ ! -f "$AUDIT_STATE/baseline.sha" ]; then
    echo "$head" > "$AUDIT_STATE/baseline.sha" || exit 1
    echo "Baseline set to $head. Nothing to audit yet: the next run reports what moved since."
    exit 0
fi

baseline=$(cat "$AUDIT_STATE/baseline.sha")
cursor=$(cat "$AUDIT_STATE/cursor.sha" 2>/dev/null || echo "$baseline")


# --- what the session is told, and what it may do ---
# Both copied beside the session rather than read from the checkout: Claude Code
# loads CLAUDE.md from the working directory, and the relative paths inside the
# settings — `../mirror`, `./reports` — resolve against the settings file's own
# directory, so a settings file left in the checkout would name the checkout as
# the place the audit may write. Refreshed every run, so the tracked pair stays
# the only copy anyone edits.
# see docs/monitor.md#where-the-audit-keeps-its-state

cp -f host/monitor/drift-audit/CLAUDE.md host/monitor/drift-audit/settings.json \
    "$AUDIT_WORK/" || exit 1


# --- the issue ledger ---
# The audit has no network and no `gh`, so this is its only view of the issues:
# what the agent asked for and what the operator ruled, as context to attach to
# an observation. An export that fails leaves the key out of run.json
# altogether, which the procedure reads as "skip that step and say so"; a stale
# file passed off as this run's would be worse than none.
# see docs/monitor.md#what-the-audit-reads

issues="$AUDIT_STATE/issues.json"
agent_repo=$(printf '%s' "${AGENT_REPO:-}" | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^https?://[^/]+/##')

if [ -n "$agent_repo" ] && gh issue list --repo "$agent_repo" --state all --limit 200 \
       --json number,title,state,updatedAt,url,body,comments > "$issues" 2>/dev/null; then
    issues_arg=(--arg issues "$issues")
else
    rm -f "$issues"
    issues_arg=()
    echo "note: the issue ledger could not be exported${agent_repo:+ from $agent_repo}; the audit will skip that step." >&2
fi


# --- the run file ---
# Every anchor handed over as data, in one file the auditor reads first. The
# prompt stays the same words every run, so what varies between two reports is
# the repository and not the question.

stamp=$(date +%Y-%m-%d)
report="$AUDIT_REPORTS/$stamp-drift.md"

jq -n \
    --arg mirror "../mirror" \
    --arg baseline "$baseline" \
    --arg cursor "$cursor" \
    --arg head "$head" \
    ${issues_arg[@]+"${issues_arg[@]}"} \
    --arg report "$report" \
    '$ARGS.named' > "$AUDIT_STATE/run.json" || exit 1


# --- the session ---
# The renderer is the runner's own, given the auditor's template: one script
# fills the placeholders a template asks for, so there is no second copy of it
# to drift.  see docs/sessions.md#one-renderer-two-templates
#
# Without the credentials .env carries: `just` loads .env into every recipe's
# environment, the vault access token with it. This session needs none of them,
# and a token it cannot read is one no instruction found in the corpus can
# spend.  see docs/monitor.md#the-sessions-environment

scrub=()
for name in GH_TOKEN ${!BWS_@}; do scrub+=(-u "$name"); done

( cd "$AUDIT_WORK" && exec env "${scrub[@]}" python3 "$RUNNER_CHECKOUT/image/claude-session.py" \
    --template "$RUNNER_CHECKOUT/host/monitor/drift-audit/system-prompt-template.md" \
    --settings "$AUDIT_WORK/settings.json" \
    --setting-sources "" \
    -p "Run the drift audit." )


# --- the cursor ---
# Advanced only on a run that produced its report. A failed run leaves it where
# it was and the next one covers the union of both ranges, so nothing goes
# unaudited because a session died halfway.

[ -s "$report" ] || {
    echo "No report at $report. The cursor stays at ${cursor:0:12}; the next run covers this range too." >&2
    exit 1
}

echo "$head" > "$AUDIT_STATE/cursor.sha" || exit 1

n_commits=$(git -C "$AUDIT_CLONE" rev-list --count "$cursor..$head" 2>/dev/null || echo "?")
n_obs=$(grep -c '^- \[' "$report")
printf '%s\taudit\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "$cursor" "$head" "$n_commits" "$n_obs" >> "$AUDIT_LOG"

echo
echo "Report: $report  ($n_commits commit(s), $n_obs observation(s))"
echo "'just drift-accept' moves the baseline once you have read it."
