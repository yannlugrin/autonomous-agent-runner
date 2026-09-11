#!/usr/bin/env bash
# Go live — set the deployed checkout to HEAD, and put the image beside it.
#
# Runs on the host. Three declared flags arrive as environment variables: diff,
# state, skip_verify.
#
# Both paths build the image from the deployed checkout and prove it with `just
# verify` before anything goes live; `--skip-verify` is the one way past that.
# RUNNER_DEPLOY_HOST decides the rest. Empty: the agent runs here, and the tag
# flips here. Set: this half ships and pushes, and `just land` on that host
# flips its tag. see docs/release.md#build-here-run-there
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
# shellcheck source=SCRIPTDIR/../lib/config-files.sh
. host/lib/config-files.sh
# shellcheck source=SCRIPTDIR/../lib/deploy-host.sh
. host/lib/deploy-host.sh

here="$RUNNER_ROOT"
target="$RUNNER_DEPLOYED"

# The branch the deployed checkout holds.
#
# On the machine that deploys it is named after the directory rather than fixed:
# a second deployed checkout for testing — RUNNER_DEPLOYED pointed elsewhere —
# must be a second branch, because git refuses to check one branch out in two
# worktrees.
#
# On the machine that runs the agent it is always `deployed`, because that is
# the name it is sent under: the push spells `+"$ref":refs/heads/deployed` and
# `land` reads that name. Deriving it there would give the checkout's own
# basename, and `deploy --state` — which `just status` asks for over ssh — would
# look for a ref that does not exist and report nothing as live.
# see docs/release.md#the-branch-follows-the-directory

if [ "${RUNNER_RUNTIME_ONLY:-}" = true ]; then
    branch=deployed
else
    branch=$(basename "$target")
fi
ref="refs/heads/$branch"
candidate="$RUNNER_IMAGE_CANDIDATE"
deployed="$RUNNER_IMAGE_DEPLOYED"

# The image id, short, or nothing when the tag does not exist. `images -q` and
# not `inspect --format`: a docker format string is a pair of braces and so is a
# just interpolation. see docs/release.md#docker-format-strings-collide-with-just
image_id() { docker images -q --no-trunc "$1" 2>/dev/null | head -1 | cut -c8-19; }

# One value out of an image's baked environment, or nothing. Read from the image
# config and not from a container, so asking cannot disturb a running session.
baked() {
    docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
        | sed -n "s/^$2=//p" | head -1
}


# --- the reads belong to whoever is live ---
# `--state` and `--diff` describe what is running, and when that is another
# machine every field below would be this one's answer to a question about it —
# a wrong answer in the shape of a right one, and `just status` draws a page
# from it. Before the state is computed, so none of it can be printed by
# accident. see docs/release.md#build-here-run-there

if deploying_elsewhere && { [ "$state" = yes ] || [ "$diff" = yes ]; }; then
    # A host with no checkout yet cannot answer, and forwarding into one would
    # answer with a shell's `cd` error — which `just status` would draw as the
    # deployment's state. Said in the state vocabulary instead, so a reader gets
    # a field and not a stack of somebody else's stderr.
    if [ "$(host_checkout_state)" != ready ]; then
        if [ "$state" = yes ]; then
            echo "worktree: absent"
            for f in deployed head ahead dropped image_candidate image_deployed deployed_at; do
                echo "$f: -"
            done
        else
            echo "Nothing is deployed on $RUNNER_DEPLOY_HOST yet: 'just deploy' creates it."
        fi
        exit 0
    fi
    [ "$state" = yes ] && exec_flag=--state || exec_flag=--diff
    host_just_read deploy "$exec_flag"
    exit $?
fi


# --- what is live, as fields ---
# `status` and status-collect.py read these rather than asking git and docker
# themselves: the branch name, the tag names and the path are decided here, once.

if [ -e "$target/.git" ]; then wt=present; else wt=absent; fi
head_sha=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo "")
dep_sha=$(git -C "$here" rev-parse --short "$ref" 2>/dev/null || echo "")
ahead=""
dropped=""
[ -n "$dep_sha" ] && ahead=$(git -C "$here" rev-list --count "$ref"..HEAD 2>/dev/null || echo "")
[ -n "$dep_sha" ] && dropped=$(git -C "$here" rev-list --count HEAD.."$ref" 2>/dev/null || echo "")
cid=$(image_id "$candidate"); did=$(image_id "$deployed")

# On the machine that runs the agent the checkout IS the live commit, so a count
# against its own HEAD is zero whatever origin holds; there, origin is asked. A
# 404 on a repository gh has just read is a commit origin does not have.
# see docs/release.md#behind-origin-is-asked-of-origin
against=""
behind=""
compare_error=""
live_missing=""
origin_compare() {
    local branch out
    against=origin
    ahead=""
    dropped=""
    [ -n "${RUNNER_REPO:-}" ] \
        || { compare_error="RUNNER_REPO is not set here, and the next 'just deploy' writes it"; return; }
    command -v gh >/dev/null || { compare_error="gh is not installed here"; return; }
    branch=$(timeout 20 gh api "repos/$RUNNER_REPO" --jq .default_branch 2>/dev/null)
    [ -n "$branch" ] \
        || { compare_error="gh here cannot read $RUNNER_REPO; its token needs Contents: Read-only on it"; return; }
    against="origin/$branch"
    if ! out=$(timeout 20 gh api "repos/$RUNNER_REPO/compare/$(git -C "$here" rev-parse "$ref")...$branch" \
            --jq '"\(.ahead_by) \(.behind_by)",
                  (.commits | reverse | .[] | .sha[0:7] + " " + (.commit.message | split("\n")[0]))' 2>&1); then
        case "$out" in
            *"HTTP 404"*) live_missing=yes ;;
            *) compare_error="origin did not answer the comparison" ;;
        esac
        return
    fi
    read -r ahead dropped <<<"${out%%$'\n'*}"
    behind=$(printf '%s\n' "$out" | tail -n +2)
}
[ "${RUNNER_RUNTIME_ONLY:-}" = true ] && [ "$state" = yes ] && [ -n "$dep_sha" ] && origin_compare

if [ "$state" = yes ]; then
    echo "worktree: $wt"
    echo "deployed: ${dep_sha:--}"
    echo "head: ${head_sha:--}"
    echo "ahead: ${ahead:--}"
    echo "dropped: ${dropped:--}"
    echo "image_candidate: ${cid:--}"
    echo "image_deployed: ${did:--}"
    # When the commit this image was built from reached origin, out of the image
    # rather than out of a reflog: the record store reads it through the status
    # snapshot, and once the build and the run are on different machines only the
    # image carries it. Empty when the image predates the field, does not exist,
    # or was built where nothing pushes. see docs/image.md#what-the-image-was-built-from
    echo "pushed_at: $(baked "$deployed" AGENT_RUNNER_PUSHED_AT | grep . || echo -)"
    # When this build went live, from the reflog of the branch this recipe
    # resets: a deploy IS that reset, so the log of it is already kept and
    # needs no stamp of its own. The image's own `Created` is not this — a
    # build whose layers all cache keeps the date of the one it reused, which
    # read 23 hours old for a deploy 35 minutes old.
    echo "deployed_at: $(git -C "$here" reflog show --date=unix --format='%gd' "$ref" 2>/dev/null \
        | head -1 | sed -E 's/^.*\{([0-9]+)\}$/\1/')"
    # `commit:` repeated rather than a `git log` block pasted in: this output is
    # parsed twice, and a subject beginning `word: ` would enter either reader as
    # a field of its own. see docs/release.md#--state-is-parsed-twice
    if [ -n "$against" ]; then
        echo "against: $against"
        [ -n "$compare_error" ] && echo "compare_error: $compare_error"
        [ -n "$live_missing" ] && echo "live_missing: $live_missing"
        [ -n "$behind" ] && printf '%s\n' "$behind" | sed 's/^/commit: /'
    else
        [ "${ahead:-0}" -gt 0 ] \
            && git -C "$here" log --oneline "$ref"..HEAD | sed 's/^/commit: /'
        [ "${dropped:-0}" -gt 0 ] \
            && git -C "$here" log --oneline HEAD.."$ref" | sed 's/^/dropped_commit: /'
    fi
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
        git -C "$here" diff "$ref" HEAD
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

# --- and the machine that only runs ---
# A deploy the runtime host originates would build its own image from its own
# checkout, and the pair that goes live would be one nobody proved. Invoked BY
# the deploying machine it carries RUNNER_SHIPPED_ID, which is what tells the
# two apart. A guard against a hand on the wrong terminal, not a boundary: the
# file it reads is editable by anyone who can type there at all.
# see docs/release.md#the-runtime-host-originates-nothing

if [ "${RUNNER_RUNTIME_ONLY:-}" = true ] && [ -z "${RUNNER_SHIPPED_ID:-}" ]; then
    echo "This machine runs the agent; it is not where a release starts." >&2
    echo "Deploy from the machine the code is edited on — it builds, proves, ships" >&2
    echo "and then runs this recipe here with the image it sent." >&2
    exit 1
fi

# The far side's path is checked here, before anything is done, rather than
# half-way through: a character it will not send through a shell is a refusal
# and not a surprise.
dir=""
if deploying_elsewhere; then
    dir=$(deploy_dir_checked) || exit 1
fi

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
        git -C "$here" log --oneline "$ref"..HEAD | sed 's/^/  /'
    fi
    # An environment is set to a commit, never merged toward one, so a deployed
    # branch that has wandered is not a refusal: the question names it and the
    # reset discards it. see docs/release.md#reset-not-merge
    if [ "${dropped:-0}" -gt 0 ]; then
        echo "Currently live and NOT in HEAD — dropped by this deploy:"
        git -C "$here" log --oneline HEAD.."$ref" | sed 's/^/  /'
    fi
fi

if [ "$skip_verify" = yes ]; then proof="and NOT verified"; else proof="and proved by 'just verify'"; fi
if deploying_elsewhere; then
    # What changes here, and what changes there. The image live on THIS machine
    # is not touched: the build tags the candidate, and only the far side's tag
    # is flipped. What does move here is $target and the `deployed` branch,
    # because they are the build context and the ref that is pushed.
    echo "Here: $target and $ref move to $head_sha, and the image is"
    echo "built there as the candidate $proof. The deployed image here is left alone."
    echo "On $RUNNER_DEPLOY_HOST:$dir: the branch and the proved image cross, that"
    echo "host's schedule is held, its tree moves and its tag flips."
else
    # The image is built, not an old candidate retagged: that ships a checkout at
    # HEAD beside an image built days earlier from different files, and nothing
    # can say so. see docs/release.md#deploy-builds-and-does-not-retag
    echo "Image: rebuilt from $target at $head_sha $proof, replacing ${did:-(no deployed tag yet)}."
fi
env_diff
config_diff

# A deploy pauses the schedule, so a session already running is not stopped but
# is named here: pausing prevents only the next one.
#
# Every `schedule` below runs here rather than forwarding: the crontab is this
# user's whichever checkout asks, and a first deploy has no deployed/ for the
# forward to reach.  see docs/release.md#the-schedule-is-held-for-the-duration
sched=$(just RUNNER_IS_DEPLOYED=yes schedule --state 2>/dev/null | sed -n 's/^state: //p')
if ! deploying_elsewhere; then
    source host/lib/session-lock.sh
    running=$(session_container)
    [ -n "$running" ] && echo "A session is running now ($running); it finishes on the old scripts, and the next one starts on the new."
    [ "$sched" = enabled ] && echo "The schedule is enabled: it is paused for the deploy, and enabled again only if the deploy succeeds."
fi

# Last before the question, where it cannot scroll past.
[ "$skip_verify" = yes ] \
    && echo "WARNING: --skip-verify — this image goes live without 'just verify' proving it."
printf 'Deploy? [y/N] '
read -r reply
case "$reply" in [yY]*) ;; *) echo "Nothing deployed."; exit 75 ;; esac

# --- the schedule, held for the duration ---
# The schedule of the machine being deployed TO, and only that one: paused after
# the yes, enabled again only when everything below succeeded. A session started
# on a half-deployed pair is what this recipe exists to prevent, so a failure
# leaves it paused and says so on every exit path.
#
# When the agent runs elsewhere this machine is not the one being deployed to —
# nothing live here is touched — and `land` holds the far side's for its own
# work. Pausing here would stop the agent for a build, a verify and a 1.2 GB
# upload, and buy nothing. see docs/release.md#the-schedule-is-held-for-the-duration

resume=no
if [ "$sched" = enabled ] && ! deploying_elsewhere; then
    just RUNNER_IS_DEPLOYED=yes schedule --pause >/dev/null || { echo "Could not pause the schedule; nothing deployed." >&2; exit 1; }
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
    # A checkout deleted by hand leaves its registration behind, and git then
    # refuses `-B` with "already used by worktree at" the path that is gone —
    # nothing here is lost, so a missing directory repairs rather than fails.
    # see docs/release.md#a-deleted-checkout-repairs-itself
    git -C "$here" worktree prune
    # `-B` and not `-b`: a branch of that name left behind by a removed
    # worktree is reused and moved here, rather than refused.
    git -C "$here" worktree add -B "$branch" "$target" HEAD >/dev/null || {
        echo "Could not create the deployed checkout; no image was built." >&2; exit 1; }
else
    # A && B || C is what is meant here: either failing is the same refusal.
    # shellcheck disable=SC2015
    git -C "$target" reset --hard --quiet "$(git -C "$here" rev-parse HEAD)" \
        && git -C "$target" clean -fdq || {
        echo "The reset failed; no image was built." >&2; exit 1; }
fi

# --- the branch, published ---
# `deployed` moved a line above, and until now it lived on this machine and on
# the host that runs the agent — neither of which is a place the record can be
# read back from. Here rather than at the end, so the commit reaches origin
# BEFORE anything starts running it, on both paths: the local one goes live at
# the tag flip below, the remote one at `land`. Origin then says what
# this branch says at every instant, including while a deploy is failing.
#
# Under its own name, and not renamed to `deployed` the way the host push is:
# that push delivers a branch into a repository whose only job is to hold one,
# this one publishes what this machine actually has. A second deployed checkout
# for testing then publishes its own branch instead of overwriting the record of
# what is live. `+` because a deploy that drops commits moves the branch
# backwards, and nothing else writes this ref.
#
# Not fatal, like the config backup at the end: a deploy that is built, proved
# and shipped does not stop because a network did.
# see docs/release.md#the-deployed-branch-is-published

git -C "$here" push --quiet origin +"$ref":"$ref" \
    || echo "BRANCH_NOT_PUBLISHED — $branch did not reach origin; the deploy goes on. Retry with 'git push origin +$branch:$branch'." >&2

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

# The image. Built here from the checkout that just moved, unless one was
# shipped from the machine that builds — in which case it is checked instead,
# and the check is what replaces the guarantee building gave.
#
# Building from $target is what made the live code and the live image one thing
# rather than two that have to agree: the context is $target/image, and
# AGENT_USER, AGENT_HOME and AGENT_REPO_DIR are derived from $target/.env and
# baked in. Through `just` in that checkout and not `docker compose` here,
# because compose cannot derive AGENT_USER from AGENT_NAME and a second
# derivation spelled here is the copy that drifts.
#
# A failure here leaves the checkout moved and the image old: the schedule stays
# paused, and nothing starts on the pair until someone has looked.
# see docs/release.md#deploy-builds-and-does-not-retag

# Onto the candidate, which is what this is: built from $target and about to be
# proved. The live tag moves only once it has been, and only on the machine the
# agent runs on. see docs/release.md#the-tag-flip-is-the-deploy
if deploying_elsewhere; then untouched="nothing was sent"; else untouched="the live image did not move"; fi
( cd "$target" && just build ) || {
    echo "The build failed; the checkout moved to $head_sha and $untouched." >&2; exit 1; }

# The build's id, pinned: what goes live is what was proved, even if a `just
# build` typed while this runs moves the candidate tag.
built=$(docker images -q --no-trunc "$candidate" | head -1)
[ -n "$built" ] || { echo "The build left no $candidate; $untouched." >&2; exit 1; }


# --- proved ---
# Verify runs on the image just built from $target, which is the image that goes
# live — not on a candidate built from the working tree at some earlier moment,
# so there is no window in which the tree moves between what was proved and what
# ships. --skip-verify is the one way past it, and the question said so.
# see docs/release.md#build-here-run-there

if [ "$skip_verify" = yes ]; then
    echo "VERIFY_SKIPPED — the image built from $target goes live without 'just verify'." >&2
else
    just verify || {
        echo "Verify failed on the image built from $target; the checkout moved to $head_sha and $untouched." >&2
        exit 1; }
    [ "$(docker images -q --no-trunc "$candidate" | head -1)" = "$built" ] || {
        echo "The candidate tag moved while it was being verified; $untouched." >&2; exit 1; }
fi

if deploying_elsewhere; then
    # Renamed for the journey. The tag travels with the image, so sending it
    # under its live name would make it live on arrival, ahead of every check.
    # see docs/release.md#the-tag-flip-is-the-deploy
    docker tag "$built" "$RUNNER_IMAGE_INCOMING" || {
        echo "Could not tag the image for shipping; nothing was sent." >&2; exit 1; }

    # The checkout over there: made when it is absent, and never guessed at.
    case "$(host_checkout_state)" in
        ready) ;;
        absent)
            echo "Creating the checkout at $RUNNER_DEPLOY_HOST:$dir."
            host_checkout_create || { echo "Could not create it; nothing was sent." >&2; exit 1; } ;;
        occupied)
            echo "$RUNNER_DEPLOY_HOST:$dir exists and is not a git repository." >&2
            echo "Nothing here guesses at a directory it did not make: move it, or point" >&2
            echo "RUNNER_DEPLOY_DIR at another one." >&2
            exit 1 ;;
        "")
            echo "$RUNNER_DEPLOY_HOST answered nothing when asked about $dir." >&2
            echo "Nothing was sent." >&2
            exit 1 ;;
        *)
            echo "Asked about $dir on $RUNNER_DEPLOY_HOST and got: $(host_checkout_state)" >&2
            echo "That is not a state this knows. Nothing was sent." >&2
            exit 1 ;;
    esac

    # The remote: added when it is absent, and never repointed. Silently moving
    # a remote somebody set by hand is not something this repository does.
    want_url=$(host_remote_url) || exit 1
    have_url=$(git -C "$here" remote get-url "$HOST_REMOTE" 2>/dev/null || true)
    if [ -z "$have_url" ]; then
        git -C "$here" remote add "$HOST_REMOTE" "$want_url" || exit 1
        echo "Added the git remote '$HOST_REMOTE' -> $want_url."
    elif [ "$have_url" != "$want_url" ]; then
        echo "The git remote '$HOST_REMOTE' points somewhere else:" >&2
        echo "  it names:  $have_url" >&2
        echo "  .env says: $want_url" >&2
        exit 1
    fi

    # `+` because a deploy that drops commits moves the branch backwards, which
    # `--state` already counts as `dropped`. Nothing over there commits, so
    # there is no work on that ref to lose.
    git -C "$here" push --quiet "$HOST_REMOTE" +"$ref":refs/heads/deployed || {
        echo "The branch did not reach $RUNNER_DEPLOY_HOST; nothing else was sent." >&2; exit 1; }
    echo "Pushed $branch as refs/heads/deployed at $head_sha to $RUNNER_DEPLOY_HOST:$dir."

    # A first push lands in a repository with no working tree, so `just land`
    # has no justfile to be run from. Nothing is live there to protect yet.
    host_checkout_populate || {
        echo "Could not check the first tree out at $RUNNER_DEPLOY_HOST:$dir." >&2; exit 1; }

    # `.env` and the three untracked files, the copy made into $target just
    # above, one machine further. RUNNER_DEPLOY_* are dropped and
    # RUNNER_RUNTIME_ONLY added: they say where the agent runs and where a
    # release starts, and both answers are different over there. RUNNER_REPO is
    # added too, because that checkout has no origin of its own to name.
    remote_path=$(host_checkout_path)
    [ -n "$remote_path" ] || {
        echo "Could not resolve $RUNNER_DEPLOY_DIR on $RUNNER_DEPLOY_HOST." >&2; exit 1; }

    { grep -v '^[[:space:]]*RUNNER_\(DEPLOYED\|DEPLOY_HOST\|DEPLOY_DIR\|RUNTIME_ONLY\|REPO\)=' "$target/.env"
      # It runs the agent and is not where a release starts. Rewritten every
      # deploy, so it cannot be lost by editing the file it lives in.
      echo 'RUNNER_RUNTIME_ONLY=true'
      # The slug `deploy --state` over there compares the live commit against.
      echo "RUNNER_REPO=$(git -C "$here" remote get-url origin 2>/dev/null \
          | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^https?://[^/]+/##')"
      # There, the checkout IS the deployed checkout. Absolute, because the
      # justfile decides RUNNER_IS_DEPLOYED by comparing its own directory to
      # this value, and a relative one is resolved from the project root and can
      # never equal it — leaving every live recipe forwarding into a directory
      # that does not exist. This machine's own value is filtered out above: it
      # names a worktree that exists only here.
      # see docs/release.md#the-runtime-host-is-its-own-deployed-checkout
      echo "RUNNER_DEPLOYED=$remote_path"
    } | host_ssh "cat > '$dir/.env'" \
        || { echo "Could not copy .env; nothing else was sent." >&2; exit 1; }

    # `mkdir -p` because the directory is not there yet: the push moved a ref
    # into a repository whose HEAD is unborn on a first deploy, so no working
    # tree exists until `land` checks one out. These three are gitignored, so
    # `land`'s `clean -fd` leaves them where this puts them.
    for name in "${CONFIG_FILES[@]}"; do
        [ -e "$target/image/config/$name" ] || continue
        host_ssh "mkdir -p '$dir/image/config' && cat > '$dir/image/config/$name'" \
            < "$target/image/config/$name" \
            || { echo "Could not copy image/config/$name." >&2; exit 1; }
    done

    host/release/ship.sh "$RUNNER_IMAGE_INCOMING" || exit 1

    # Nothing above has changed what runs over there: a ref arrived that no
    # working tree follows, and an image arrived under a name nothing starts.
    # `land` is what pauses that host's schedule, moves its tree, checks the
    # pair and flips the tag. see docs/release.md#the-tag-flip-is-the-deploy
    export RUNNER_SHIPPED_ID
    RUNNER_SHIPPED_ID=$(docker images -q --no-trunc "$RUNNER_IMAGE_INCOMING" | head -1)
    host_just land || {
        echo "The image and the branch are on $RUNNER_DEPLOY_HOST and nothing went live there." >&2
        echo "Its schedule is left as 'just land' left it — the lines above say what happened." >&2
        exit 1; }
    exit 0
fi

# --- the tag flip ---
# What was built and proved above becomes the live tag, so the candidate and the
# live image are one image, which is what a `just verify` typed afterwards has to
# be proving. see docs/release.md#the-candidate-follows-the-live-image
docker tag "$built" "$deployed" || {
    echo "The checkout moved to $head_sha and the live tag did not." >&2; exit 1; }

echo "Deployed: $target at $(git -C "$target" rev-parse --short HEAD), image $(image_id "$deployed") — the candidate tag names it too."


# --- the crontab, and the schedule back as it stood ---
# The crontab names the directory cron runs from; if it still names another one,
# this is where it moves, and a paused schedule stays paused. The block below
# is what enables it again, and only when it was enabled to begin with.
# see docs/schedule.md

just RUNNER_IS_DEPLOYED=yes schedule --relocate || { echo "SCHEDULE_NOT_RELOCATED — the crontab still names another directory; 'just schedule' shows it." >&2; exit 1; }

if [ "$resume" = yes ]; then
    just RUNNER_IS_DEPLOYED=yes schedule --enable >/dev/null || { echo "Could not enable the schedule again." >&2; exit 1; }
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
