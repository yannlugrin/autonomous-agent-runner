#!/usr/bin/env bash
# Put this installation's own configuration where it can be got back.
#
# Runs on the host, no arguments. `host/release/deploy.sh` calls it once a
# deploy has succeeded — the moment those files take effect, and the only moment
# at which the branch and what is live are the same thing.
#
# The three files under image/ are untracked by design: what they hold is this
# installation's and not the repository's. Nothing else keeps a copy, so a lost
# machine loses them, and `just setup --restore` reads them back from here.
#
# `.env` is deliberately never carried. It holds the vault's access token, and
# the archive is a repository like any other; the files here hold rules and no
# values. see docs/archive.md#the-config-branch
set -uo pipefail

# Computed and exported by the justfile, as in publish-status.sh.
ARCHIVE="${AGENT_ARCHIVE:?not set — run this through 'just', which computes it}"
BRANCH=config
LOCK="${RUNNER_CONFIG_LOCK:?not set — run this through 'just', which derives it from the agent name}"

# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
# shellcheck source=SCRIPTDIR/../lib/config-files.sh
. host/lib/config-files.sh

die() { printf '%s\n' "$*" >&2; exit 1; }

if [ ! -d "$ARCHIVE/.git" ]; then
    die "No archive at $ARCHIVE, so the configuration was not backed up. Set AGENT_ARCHIVE, or clone it there."
fi


# --- never two at once ---
# The same race the status snapshot has: two writers between reading the branch
# and pushing over it. Non-blocking, because the other one is carrying the same
# files. see docs/archive.md#the-status-snapshot

exec 8>"$LOCK"
if ! flock -n 8; then
    echo "Another configuration backup is running. Nothing to do."
    exit 0
fi


# --- the branch, in a throwaway worktree ---
# `config` is created here on first run: absent locally, or present only on
# origin because this clone has never checked it out, or already an orphan
# branch. The same three cases publish-status.sh handles, in the same order.

wt="$(mktemp -d)/$BRANCH"   # must not exist yet: `worktree add` creates it
if git -C "$ARCHIVE" show-ref --quiet --verify "refs/heads/$BRANCH"; then
    add=(add --quiet "$wt" "$BRANCH")
elif git -C "$ARCHIVE" show-ref --quiet --verify "refs/remotes/origin/$BRANCH"; then
    add=(add --quiet -b "$BRANCH" "$wt" "origin/$BRANCH")
else
    add=(add --quiet --orphan -b "$BRANCH" "$wt")
fi

# A worktree left behind is not cosmetic: the branch stays checked out somewhere,
# and every backup after this one fails on "already used by worktree at". Both
# halves are needed — `remove` takes the checkout, `prune` takes the record — and
# `--force` because a temporary directory nobody is editing is never dirty on
# purpose.
cleanup() {
    git -C "$ARCHIVE" worktree remove --force "$wt" 2>/dev/null || true
    git -C "$ARCHIVE" worktree prune 2>/dev/null || true
    rm -rf "$(dirname "$wt")" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$ARCHIVE" worktree "${add[@]}" || die \
    "Could not check out '$BRANCH' — see the message above.
If it is checked out elsewhere, remove that worktree."

# Behind origin is normal and not a conflict: this is the only writer, so a
# fetch first makes the push a fast-forward rather than a rejection needing a
# human.
git -C "$wt" fetch --quiet origin "$BRANCH" 2>/dev/null \
    && git -C "$wt" merge --quiet --ff-only "origin/$BRANCH" 2>/dev/null


# --- what is carried, and what it says ---
# Named from the one list, so a fourth file added there is carried here without
# an edit. A file that is absent is left as it stands on the branch rather than
# deleted from it: the build refuses without all three, so absent here means
# something is half-done, and a backup is not where that gets decided.

for name in "${CONFIG_FILES[@]}"; do
    [ -e "image/config/$name" ] || continue
    cp --remove-destination "image/config/$name" "$wt/$name" || die "Could not copy image/config/$name into the worktree."
    git -C "$wt" add -- "$name" || die "Could not stage $name."
done

# Nothing changed is the ordinary case — a deploy that moved code and not
# configuration — and it says nothing at all.
if git -C "$wt" diff --cached --quiet; then
    exit 0
fi

# Local time, because this line is read by a person deciding which backup to
# restore, and the deploy it records happened on their clock.
git -C "$wt" commit --quiet -m "config: $(date '+%Y-%m-%d %H:%M') local" \
    || die "The configuration commit failed — see above."

if git -C "$wt" push --quiet origin "$BRANCH" 2>/dev/null; then
    echo "Configuration backed up to '$BRANCH' in the archive."
else
    # The commit stands and the next deploy pushes it, but a branch that stopped
    # reaching origin is a backup that exists only on this machine — which is
    # the one machine the backup is against losing.
    die "CONFIG_PUSH_FAILED — committed to $BRANCH in $ARCHIVE but the push did not go through."
fi
