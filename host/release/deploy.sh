#!/usr/bin/env bash
# Go live — set the deployed checkout to HEAD and build the image from it.
#
# Runs on the host. Two declared flags arrive as environment variables: diff,
# state.
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
# shellcheck source=SCRIPTDIR/../lib/config-files.sh
. host/lib/config-files.sh

here="$RUNNER_ROOT"
target="$RUNNER_DEPLOYED"
candidate="$RUNNER_IMAGE_CANDIDATE"
deployed="$RUNNER_IMAGE_DEPLOYED"

# The image id, short, or nothing when the tag does not exist. `images -q` and
# not `inspect --format`: a docker format string is a pair of braces and so is a
# just interpolation. see docs/release.md#docker-format-strings-collide-with-just
image_id() { docker images -q --no-trunc "$1" 2>/dev/null | head -1 | cut -c8-19; }


# --- what is live, as fields ---
# `status` and status-collect.py read these rather than asking git and docker
# themselves: the branch name, the tag names and the path are decided here, once.

if [ -e "$target/.git" ]; then wt=present; else wt=absent; fi
head_sha=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo "")
dep_sha=$(git -C "$here" rev-parse --short refs/heads/deployed 2>/dev/null || echo "")
ahead=""
dropped=""
[ -n "$dep_sha" ] && ahead=$(git -C "$here" rev-list --count refs/heads/deployed..HEAD 2>/dev/null || echo "")
[ -n "$dep_sha" ] && dropped=$(git -C "$here" rev-list --count HEAD..refs/heads/deployed 2>/dev/null || echo "")
cid=$(image_id "$candidate"); did=$(image_id "$deployed")

if [ "$state" = yes ]; then
    echo "worktree: $wt"
    echo "deployed: ${dep_sha:--}"
    echo "head: ${head_sha:--}"
    echo "ahead: ${ahead:--}"
    echo "dropped: ${dropped:--}"
    echo "image_candidate: ${cid:--}"
    echo "image_deployed: ${did:--}"
    # `commit:` repeated rather than a `git log` block pasted in: this output is
    # parsed twice, and a subject beginning `word: ` would enter either reader as
    # a field of its own. see docs/release.md#--state-is-parsed-twice
    [ "${ahead:-0}" -gt 0 ] \
        && git -C "$here" log --oneline refs/heads/deployed..HEAD | sed 's/^/commit: /'
    [ "${dropped:-0}" -gt 0 ] \
        && git -C "$here" log --oneline HEAD..refs/heads/deployed | sed 's/^/dropped_commit: /'
    exit 0
fi


# --- what `.env` would change ---
# `.env` is part of what goes live and git cannot see it. A function because
# `--diff` and the question below both show it, and one masking rule spelled
# twice is the one that drifts; masked because terminals get copied into issues.
# see docs/release.md#the-one-refusal-and-what-it-does-not-cover

env_diff() {
    if [ ! -e "$here/.env" ]; then
        echo "Note: no .env here; the deployed checkout keeps the one it has."
    elif [ ! -e "$target/.env" ] || [ -L "$target/.env" ]; then
        echo "Configuration: .env is copied into the deployed checkout."
    elif ! cmp -s "$here/.env" "$target/.env"; then
        echo "Configuration changes that become live (.env, live -> new):"
        diff "$target/.env" "$here/.env" | grep '^[<>]' \
            | sed -E 's/^([<>] *[A-Za-z_]*(TOKEN|SECRET|KEY|PASS)[A-Za-z_]*=).*/\1…/' | sed 's/^/  /'
    fi
}

# --- what this installation's own files would change ---
# The three under image/ are untracked and travel by copy, like `.env`, so git
# cannot show them either. Unmasked, unlike `.env`: what is in them is rules —
# a shape, a vault key that is not a credential, the community sentence — and
# reading the rule that is about to take effect is the whole point of showing
# it. see docs/configuration.md#the-three-files-that-are-yours

config_diff() {
    for name in "${CONFIG_FILES[@]}"; do
        if [ ! -e "$here/image/config/$name" ]; then
            echo "Note: no image/config/$name here; 'just setup' makes it, and the build refuses without it."
        elif [ ! -e "$target/image/config/$name" ]; then
            echo "Configuration: image/config/$name is copied into the deployed checkout."
        elif ! cmp -s "$here/image/config/$name" "$target/image/config/$name"; then
            echo "Configuration changes that become live (image/config/$name, live -> new):"
            diff "$target/image/config/$name" "$here/image/config/$name" | grep '^[<>]' | sed 's/^/  /'
        fi
    done
}


# The patch between what is live and what would go live, for the moment a
# subject line is not enough — which commits those are is `--state`'s answer.
# Gated on nothing: it reads, and the two refusals below belong to the act.
# `.env` first, because it is short and the half git will not show.
if [ "$diff" = yes ]; then
    env_diff
    config_diff
    # On stderr, so a piped patch stays a patch. This compares two commits, and
    # reading a patch without the edit you just made is a wrong conclusion
    # reached silently.
    [ -n "$(git -C "$here" status --porcelain)" ] \
        && echo "Note: this is deployed..HEAD; uncommitted edits here are in neither." >&2
    if [ -z "$dep_sha" ]; then
        echo "No deployed branch yet: every committed file here would be new."
    else
        git -C "$here" diff refs/heads/deployed HEAD
    fi
    exit 0
fi


# --- the one refusal ---
# A tree that is not clean: what goes live is HEAD, and the build below runs on
# the deployed checkout at HEAD, so an uncommitted edit here would ship as
# something other than what this tree shows. `.env` is not covered and cannot
# be — it is gitignored and copied live by this recipe, and env_diff is what
# shows it. Above the terminal check, because it is true whether or not anyone
# is there to be asked.
# see docs/release.md#the-one-refusal-and-what-it-does-not-cover

uncommitted=$(git -C "$here" status --porcelain)
if [ -n "$uncommitted" ]; then
    echo "The tree is not clean, and only what is committed can be deployed:" >&2
    printf '%s\n' "$uncommitted" | sed 's/^/  /' >&2
    echo "Commit them, or stash them, then deploy." >&2
    exit 1
fi

# Asks, always: this is the moment a change reaches the agent, and the list of
# what is about to is the thing worth reading one last time.
if [ ! -t 0 ]; then
    echo "deploy asks before it acts, and there is no terminal to ask on." >&2
    exit 1
fi


# --- what is about to go live ---
# The first deploy creates the checkout at HEAD — there is no other commit to
# create it at — so the question below shows everything. If HEAD is not what
# should be live, the answer is no.

if [ "$wt" = absent ]; then
    echo "First deploy: $target does not exist and will be created at $head_sha."
    echo "Everything committed up to there becomes what cron runs."
else
    echo "Commits that become live in $target:"
    if [ "${ahead:-0}" -eq 0 ]; then
        echo "  (none — deployed is already at $head_sha)"
    else
        git -C "$here" log --oneline refs/heads/deployed..HEAD | sed 's/^/  /'
    fi
    # An environment is set to a commit, never merged toward one, so a deployed
    # branch that has wandered is not a refusal: the question names it and the
    # reset discards it. see docs/release.md#reset-not-merge
    if [ "${dropped:-0}" -gt 0 ]; then
        echo "Currently live and NOT in HEAD — dropped by this deploy:"
        git -C "$here" log --oneline HEAD..refs/heads/deployed | sed 's/^/  /'
    fi
fi

# The image is built, not retagged: a retag ships a checkout at HEAD beside an
# image built days earlier from different files, and nothing can say so.
# see docs/release.md#deploy-builds-and-does-not-retag
echo "Image: rebuilt from $target at $head_sha, replacing ${did:-(no deployed tag yet)}."
env_diff
config_diff

# A deploy pauses the schedule, so a session already running is not stopped but
# is named here: pausing prevents only the next one.
# see docs/release.md#the-schedule-is-held-for-the-duration
sched=$(just schedule --state 2>/dev/null | sed -n 's/^state: //p')
source host/lib/session-lock.sh
running=$(session_container)
[ -n "$running" ] && echo "A session is running now ($running); it finishes on the old scripts, and the next one starts on the new."
[ "$sched" = enabled ] && echo "The schedule is enabled: it is paused for the deploy, and enabled again only if the deploy succeeds."

printf 'Deploy? [y/N] '
read -r reply
case "$reply" in [yY]*) ;; *) echo "Nothing deployed."; exit 75 ;; esac


# --- the schedule, held for the duration ---
# Paused after the yes, and enabled again only when everything below succeeded.
# A session started on a half-deployed pair is what this recipe exists to
# prevent, so a failure leaves the schedule paused and says so on every exit
# path. see docs/release.md#the-schedule-is-held-for-the-duration

resume=no
if [ "$sched" = enabled ]; then
    just schedule --pause >/dev/null || { echo "Could not pause the schedule; nothing deployed." >&2; exit 1; }
    resume=yes
fi

# shellcheck disable=SC2329  # invoked by the EXIT trap below
finish() {
    if [ $? -ne 0 ] && [ "$resume" = yes ]; then
        echo "SCHEDULE_LEFT_PAUSED — the schedule was paused for this deploy and is left paused: the line above says what the failed deploy left behind. Fix it and deploy again, or 'just schedule --enable' to run what is there." >&2
    fi
}
trap finish EXIT


# --- the checkout, then the image from it ---
# The checkout is the build context, so it has to be at HEAD before there is
# anything to build. `reset --hard` and not a merge: it is an environment and
# holds nothing to protect, and a merge is a step that can fail where a reset
# cannot. `clean -fd` takes any untracked file that appeared and leaves what is
# ignored, which is where `.env` lives. see docs/release.md#reset-not-merge

if [ "$wt" = absent ]; then
    # `-B` and not `-b`: a `deployed` branch left behind by a removed worktree
    # is reused and moved here, rather than refused.
    git -C "$here" worktree add -B deployed "$target" HEAD >/dev/null || {
        echo "Could not create the deployed checkout; no image was built." >&2; exit 1; }
else
    # A && B || C is what is meant here: either failing is the same refusal.
    # shellcheck disable=SC2015
    git -C "$target" reset --hard --quiet "$(git -C "$here" rev-parse HEAD)" \
        && git -C "$target" clean -fdq || {
        echo "The reset failed; no image was built." >&2; exit 1; }
fi

# `.env` is gitignored, so the reset above never touches it, and compose and
# `just` both read it from the directory they run in. --remove-destination,
# because `cp` onto a link writes through it, into this checkout's own file.
# see docs/release.md#the-one-refusal-and-what-it-does-not-cover
if [ -e "$here/.env" ]; then
    cp --remove-destination "$here/.env" "$target/.env" || { echo "Could not copy .env; the checkout moved and the image did not." >&2; exit 1; }
fi

# The same for this installation's own three, which are gitignored for the same
# reason and are inputs to the build below: two of them are baked into the image
# and the third renders the classifier's community slot.
for name in "${CONFIG_FILES[@]}"; do
    [ -e "$here/image/config/$name" ] || continue
    cp --remove-destination "$here/image/config/$name" "$target/image/config/$name" || {
        echo "Could not copy image/config/$name; the checkout moved and the image did not." >&2; exit 1; }
done

# After the reset and after the `.env` copy, because both are inputs: the
# context is $target/image, and AGENT_USER, AGENT_HOME and AGENT_REPO_DIR are
# derived from $target/.env and baked in. Through `just` in that checkout and
# not `docker compose` here, because compose cannot derive AGENT_USER from
# AGENT_NAME and a second derivation spelled here is the copy that drifts.
#
# A failure here leaves the checkout moved and the image old: the schedule stays
# paused, and nothing starts on the pair until someone has looked.
# see docs/release.md#deploy-builds-and-does-not-retag
( cd "$target" && just build --deployed ) || {
    echo "The build failed; the checkout moved to $head_sha and the image did not." >&2; exit 1; }

# The candidate follows the live image: `just verify` proves the candidate, and
# a verify reporting on an image older than the one running is a quiet wrong
# answer. Fact rather than approximation — the tree was refused unless clean,
# $target was reset to HEAD and `.env` was copied from here, so this image is
# byte-for-byte what `just build` in this tree would produce.
# see docs/release.md#the-candidate-follows-the-live-image
docker tag "$deployed" "$candidate" || {
    echo "The image is live but the candidate tag was not moved; 'just build' resets it." >&2; exit 1; }

echo "Deployed: $target at $(git -C "$target" rev-parse --short HEAD), image $(image_id "$deployed") — the candidate tag names it too."


# --- the crontab, and the schedule back as it stood ---
# The crontab names the directory cron runs from; if it still names another one,
# this is where it moves, and a paused schedule stays paused. The block below
# is what enables it again, and only when it was enabled to begin with.
# see docs/schedule.md

just schedule --relocate || { echo "SCHEDULE_NOT_RELOCATED — the crontab still names another directory; 'just schedule' shows it." >&2; exit 1; }

if [ "$resume" = yes ]; then
    just schedule --enable >/dev/null || { echo "Could not enable the schedule again." >&2; exit 1; }
    echo "The schedule is enabled again."
fi


# --- the configuration, backed up ---
# Here and nowhere else because this is the moment a configuration change takes
# effect: what the branch holds is then what is live, rather than what someone
# happened to have edited. The files are untracked, so nothing else keeps a copy
# of them, and `just setup --restore` is what reads that branch back.
#
# Not fatal: the deploy is done, the image is live, and a backup that did not
# reach origin is worth a line rather than an exit code someone reads as "the
# deploy failed". see docs/archive.md#the-config-branch

host/release/config-backup.sh \
    || echo "CONFIG_NOT_BACKED_UP — the deploy is live; the line above says what stopped the backup." >&2

exit 0
