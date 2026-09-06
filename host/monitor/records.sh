#!/usr/bin/env bash
# Seal one durable record per archived session, and publish them.
#
# Runs on the host. Every declared argument arrives as an environment variable:
# the flags recheck, prove and publish, and the value rewrite.
#
# What a record holds and when it may be written is host/monitor/session-records.py;
# this is the half that has to be here. The two sources are fetched here — the
# agent's repository through sync_memory and the archive through git — and the
# `cache` branch is written the way host/archive/publish-status.sh writes
# `status`: one writer, a throwaway worktree, a lock across the read and the push.
#
# `run` and `chat` call this at the end of every session, after the collection
# and after `publish-status --now`, which is the moment all three sealing
# conditions hold. A session is recorded when it ends, and this is where that
# happens.
#
# THE NETWORK IS TOUCHED ONLY WHEN IT WOULD SEAL SOMETHING. Whether a session
# has a record is decided from the filenames alone, before anything is fetched
# and before a transcript is read, so a call with nothing to do costs 40
# milliseconds and no traffic. That is what makes it safe to call on every
# session end.
# see docs/monitor.md#one-record-per-session
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/archive.sh
. host/monitor/clone.sh

BRANCH=cache
LOCK="${RUNNER_RECORDS_LOCK:?not set — run this through 'just', which derives it from the agent name}"
STORE="${RUNNER_RECORDS_DIR:?not set — run this through 'just', which derives it from the cache directory}"

# The worktree the publish commits in, at script scope: the EXIT trap that
# removes it runs after the function has returned, and a `local` would be gone
# by then — which under `set -u` kills the trap and leaves the worktree behind,
# so every later publish fails on the path it cannot re-add.
wt=""

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

records() { host/monitor/session-records.py "$@"; }


# --- publish_needed ---
# Whether there is anything to carry, decided from local reads alone: the branch
# does not hold the same set of records the store does, or it holds a commit
# that never reached origin. Asked before the lock and the worktree, and before
# any fetch, so an ordinary `just records` with nothing to do touches neither.
#
# It is asked even when nothing sealed on this run. A push that failed once —
# offline, most likely — leaves a commit on the local branch and nothing on
# origin, and publishing only when a new record appeared would leave it there
# until the next session seals.

publish_needed() {
    local ref=""

    if git -C "$ARCHIVE" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
        ref="refs/heads/$BRANCH"
        git -C "$ARCHIVE" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null || return 0
        [ "$(git -C "$ARCHIVE" rev-list --count "refs/remotes/origin/$BRANCH..$ref")" -gt 0 ] && return 0
    elif git -C "$ARCHIVE" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
        ref="refs/remotes/origin/$BRANCH"
    else
        return 0
    fi

    # The names and not a count of them: a record removed and another added
    # leaves the count where it was, and the one on the branch would then never
    # be reconciled with the one in the store.
    ! diff -q \
        <(git -C "$ARCHIVE" ls-tree -r --name-only "$ref" -- records | sed 's|^records/||' | sort) \
        <(cd "$STORE" && find . -name '*.json' | sed 's|^\./||' | sort) >/dev/null
}


# --- publish_records ---
# Published, on a branch of its own. Not on `sessions`: that branch belongs to
# the credential gate — one writer, append-only, every file scanned before it
# lands. This carries nothing new past that gate. Every field derives from
# transcripts that already passed it, a held transcript has no record at all,
# and the only free text in a record is the title, Claude Code's own summary of
# an already-scanned transcript. THERE IS NO SCAN HERE AND NONE IS NEEDED.
#
# Published because it is the only way the archive's own dashboard can read it:
# render.py runs in CI inside the archive checkout and cannot see a host cache.
# Not for safety — every source is already on GitHub and current.
#
# publish_records [rewritten]

publish_records() {
    local why="${1:-sealed}" add added changed

    [ -d "$STORE" ] || return 0
    if [ "$publish" != yes ]; then
        say "Not published: --no-publish. 'just records' without it pushes them."
        return 0
    fi
    if [ "$why" != rewritten ] && ! publish_needed; then
        say "The '$BRANCH' branch already holds every sealed record. Nothing pushed."
        return 0
    fi

    # Never two at once, for the reason RUNNER_SNAPSHOT_LOCK exists: two writers
    # racing between reading the branch and pushing over it. Non-blocking — the
    # second has nothing to add that the first is not already carrying.
    exec 8>"$LOCK"
    if ! flock -n 8; then
        say "Another publish is running. Nothing pushed."
        return 0
    fi

    # The same three cases publish-status.sh handles, in the same order: the
    # branch is here, it is only on origin, or it does not exist yet.
    wt="$(mktemp -d)/$BRANCH"
    if git -C "$ARCHIVE" show-ref --quiet --verify "refs/heads/$BRANCH"; then
        add=(add --quiet "$wt" "$BRANCH")
    elif git -C "$ARCHIVE" show-ref --quiet --verify "refs/remotes/origin/$BRANCH"; then
        add=(add --quiet -b "$BRANCH" "$wt" "origin/$BRANCH")
    else
        add=(add --quiet --orphan -b "$BRANCH" "$wt")
    fi

    # A worktree left behind is not cosmetic: `worktree add` refuses the same
    # path next time, and every publish after this one fails.
    cleanup() {
        git -C "$ARCHIVE" worktree remove --force "$wt" 2>/dev/null || true
        git -C "$ARCHIVE" worktree prune 2>/dev/null || true
        rmdir "$(dirname "$wt")" 2>/dev/null || true
    }
    trap cleanup EXIT

    git -C "$ARCHIVE" worktree "${add[@]}" || die \
        "Could not check out '$BRANCH' — see the message above.
If it is checked out elsewhere, remove that worktree."

    # Behind origin is normal and not a conflict: this is the only writer, so a
    # fetch first makes the push a fast-forward rather than a rejection needing
    # a human. Offline is a fine state to publish from — the commit is made and
    # the next run pushes both.
    git -C "$wt" fetch --quiet origin "$BRANCH" 2>/dev/null \
        && git -C "$wt" merge --quiet --ff-only "origin/$BRANCH" 2>/dev/null

    mkdir -p "$wt/records"
    cp -r "$STORE/." "$wt/records/" || die "Could not copy the records into $wt."
    git -C "$wt" add -A -- records

    if git -C "$wt" diff --cached --quiet; then
        say "Every sealed record is already on '$BRANCH'. Nothing pushed."
        return 0
    fi

    # Nothing on this branch is ever rewritten: a record is written once, when
    # every field in it is final, and a file that would change here means one of
    # them was not. `--rewrite` is the one path allowed to change one.
    changed=$(git -C "$wt" diff --cached --name-status | grep -v '^A' || true)
    if [ -n "$changed" ] && [ "$why" != rewritten ]; then
        printf '%s\n' "REWRITE REFUSED — these are already on '$BRANCH' and would change:" >&2
        printf '%s\n' "$changed" | sed 's/^/    /' >&2
        printf '%s\n' "A record is written once. 'just records --rewrite <id>' is the one way." >&2
        return 1
    fi

    added=$(git -C "$wt" diff --cached --name-only | grep -c '\.json$')
    git -C "$wt" commit --quiet -m "cache: $added record(s) $why" \
        || die "The commit failed — see above."

    if git -C "$wt" push --quiet origin "$BRANCH" 2>/dev/null; then
        say "Published $added record(s) to '$BRANCH'."
    else
        # The commit stands and the next run carries it. On stderr so cron mails
        # it: a branch that stopped reaching origin is a dashboard going quietly
        # stale while the host is perfectly well.
        echo "PUBLISH_FAILED — committed to $BRANCH in $ARCHIVE but the push did not go through." >&2
        return 1
    fi
}


# --- the proof ---
# Its own script, and the one obligation of the store until the commands are
# normalised onto it.  see docs/monitor.md#the-sufficiency-proof

if [ "$prove" = yes ]; then
    exec host/monitor/prove-records.sh
fi


# --- what has to be there ---
# origin/sessions and not the local branch: a record is sealed against what has
# been pushed, so a redact ruling or a held transcript cannot land after the
# record that describes it.

need_archive
git -C "$ARCHIVE" rev-parse --verify --quiet refs/remotes/origin/sessions >/dev/null || die \
"No 'sessions' branch on origin in $ARCHIVE. Nothing has been pushed yet.
A record is sealed against what is on origin, so there is nothing to seal.
    just collect --push      collects and pushes"


# --- audit, rather than write ---

if [ "$recheck" = yes ]; then
    say "Re-deriving every stored record against the sources as they stand."
    records --recheck
    exit $?
fi


# --- one record replaced ---
# For the case a redact ruling changed a transcript after its record sealed.
# Never on its own: the operator asks for it by id.

if [ -n "$rewrite" ]; then
    sync_memory || exit 1
    git -C "$ARCHIVE" fetch --quiet origin sessions status 2>/dev/null || true
    records --rewrite "$rewrite" || exit $?
    publish_records rewritten
    exit $?
fi


# --- the ordinary run ---

pending=$(records --pending) || exit $?
case "$pending" in ''|*[!0-9]*) die "Could not read the archive — see the message above." ;; esac

if [ "$pending" = 0 ]; then
    say "Every session on origin/sessions has a record. Nothing fetched, nothing written."
else
    say "$pending session(s) without a record. Reading the two joined sources."
    sync_memory || exit 1
    git -C "$ARCHIVE" fetch --quiet origin sessions status 2>/dev/null \
        || say "note: could not fetch $ARCHIVE — sealing against the refs as they stand."
    records --seal || exit $?
fi

publish_records
