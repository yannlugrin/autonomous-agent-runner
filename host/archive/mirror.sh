#!/usr/bin/env bash
# How the mirror is doing — is it running, is it current, was anything rewound.
# Runs on the host, against the mirror's own clone.
#
#     mirror.sh                   the screen
#     mirror.sh --state [<epoch>] the same reading as `key: value` lines, for
#                                 `just status`; the epoch is when the last
#                                 session ended, which is what decides whether
#                                 a due run is late or merely waiting
#
# --state runs exactly the same code and prints instead of the screen, so the
# two cannot disagree; the exit status is the verdict either way.
#
# Everything here reads. The record has exactly one writer — the workflow in
# the mirror's own repository — and a second writer on a record whose whole
# value is that it has one would be the end of it.
#   see docs/monitor.md#the-mirror-is-not-in-the-archive
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/mirror.sh

need_mirror

# --state sends the screen to /dev/null and keeps descriptor 3 for the state
# block, rather than putting a condition around forty prints: one code path,
# and a fact that reaches the screen and not the block cannot exist.
as_state=no
session_ended_at=""
case "${1:-}" in
    --state) as_state=yes; session_ended_at="${2:-}" ;;
    "") ;;
    *) echo "Usage: mirror.sh [--state [<last session end, epoch>]]" >&2; exit 2 ;;
esac
if [ "$as_state" = yes ]; then exec 3>&1 1>/dev/null; else exec 3>/dev/null; fi

# The screen reads the last session end itself; --state is handed it by `just
# status`, which reads it once for everything it shows.
if [ "$as_state" = no ]; then
    # shellcheck source=SCRIPTDIR/../lib/session-lock.sh
    . host/lib/session-lock.sh
    session_ended_at=$(session_ended_epoch) || session_ended_at=""
fi

ref="refs/memory/mirror"
workflow="${AGENT_MIRROR_WORKFLOW:-mirror-$AGENT_USER.yml}"
# The job inside that workflow that IS the backup. Named rather than derived:
# the workflow examples/archive ships has this one job, and an archive is free
# to carry others beside it — a run's own conclusion covers all of them and so
# says nothing about whether the memory was mirrored.
#   see docs/archive.md#the-run-is-not-the-backup
backup_job=mirror

# What --state reports, declared here because `set -u` reaches them whatever
# path the reading took: a fact that could not be read must arrive empty rather
# than absent, so the block always has the same shape.
tip_written=""
tip_commits=""
workflow_state=""
last_run=""
last_conclusion=""

# What is wrong, collected as it is found and judged at the end. This recipe
# used to only describe; a backup that has stopped reads exactly like one that
# is idle, and describing both in the same words is how three days passed.
# see docs/archive.md#the-key-goes-on-before-the-secret-goes-in
problems=()
# What could not be READ, which is neither a working backup nor a stopped one.
# Kept apart from the problems above because the two want opposite answers from
# whoever reads the exit status: a stopped backup must stand a session down, and
# a reading that failed must not.  see docs/archive.md#a-reading-that-failed-is-not-a-judgement
unproven=()


# --- who is mirroring whom ---
# Slugs are derived, never written down twice: the archive's from the remote,
# the source's from the workflow, which is what decides what gets mirrored.
# Three substitutions rather than one capture, since ERE has no lazy quantifier
# and the tempting one leaves the `.git` on.  see docs/archive.md#against-the-source

archive=$(git -C "$MIRROR" remote get-url origin 2>/dev/null \
    | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^https?://[^/]+/##')
# Off origin/main and not the working tree: the operator edits in that folder, so
# its files are what is being changed, not what runs. The blob is fetched on
# demand, which is what a blobless clone is for.
wf="$workflow on $archive"
source=$(git -C "$MIRROR" show "origin/main:.github/workflows/$workflow" 2>/dev/null \
    | sed -n 's#^ *SOURCE_URL: *git@github.com:\(.*\)\.git *$#\1#p')


# --- the fetch ---
# A status read off stale refs is worse than none, so fetching is first and a
# failure says so rather than being swallowed. The namespace is named explicitly
# because a clone's default refspec does not carry it, and everything below
# would otherwise report "the mirror has never run" on a healthy one; `main`
# comes too, because the workflow file is read out of it — into origin/main, and
# never onto the local branch, which is checked out and belongs to the operator.
#   see docs/archive.md#a-ref-not-a-branch

printf 'fetching     : '
if git -C "$MIRROR" fetch --quiet --prune origin \
    '+refs/memory/*:refs/memory/*' '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then
    echo 'ok'
else
    echo 'FAILED — everything below is from local refs and may be stale'
    # The likeliest cause, and it is not in git's own error: the remote is HTTPS
    # so that one credential covers the fetch and `gh api`, and nothing hands git
    # that credential until `gh auth setup-git` has installed its helper.
    # shellcheck disable=SC2016  # backticks are prose here, not substitution
    if ! gh auth status >/dev/null 2>&1; then
        echo '               gh is not logged in here — `gh auth login`, then `gh auth setup-git`'
    elif ! git config --get-regexp 'credential.*helper' >/dev/null 2>&1; then
        echo '               git has no credential helper — `gh auth setup-git` installs one'
    fi
fi
echo


# --- the mirror ref ---
# A ref, and not a branch: only refs/heads/* and refs/tags/* start workflow runs,
# and this ref carries the agent's tree, workflow files included. The cost is
# that it is not browsable on github.com, and this recipe is how you read it.
#   see docs/archive.md#a-ref-not-a-branch

echo "== the mirror ref =="
if ! git -C "$MIRROR" rev-parse --verify --quiet "$ref" >/dev/null; then
    echo "  $ref does not exist. Either the mirror has"
    echo "  never completed a run, or this clone has never fetched the"
    echo "  namespace — the fetch above does ask for it."
    echo "  gh workflow run $workflow"
else
    tip=$(git -C "$MIRROR" rev-parse --short "$ref")
    # Local time, because a person reads it: this screen answers "when did that
    # happen, for me".
    when=$(git -C "$MIRROR" log -1 --format=%cd --date=iso-local "$ref")
    # The tip is the agent's activity, not the mirror's health — the ref only
    # moves when the agent pushed. The workflow section below reports health.
    printf '  tip        : %s  %s\n' "$tip" "$(git -C "$MIRROR" log -1 --format=%s "$ref")"
    # Whether silence here is a quiet agent or a dead mirror is not knowable
    # from this line — the workflow section decides it, and the verdict says so.
    printf '  written    : %s  (by %s)\n' "$when" "$AGENT_NAME"
    printf '  commits    : %s\n' "$(git -C "$MIRROR" rev-list --count "$ref")"
    tip_written=$(git -C "$MIRROR" log -1 --format=%ct "$ref")
    tip_commits=$(git -C "$MIRROR" rev-list --count "$ref")
fi
echo


# --- rewind marks ---
# The one thing this archive exists to catch: a mark means the upstream history
# was rewritten and the tip we held was preserved before the ref was reset onto
# the new one. Plain refs under refs/memory/rewound/ and not annotated tags,
# since refs/tags/ triggers workflows on push. Everything shown is derived from
# the refs, so nothing can fall out of step with them.
#   see docs/archive.md#rewind-marks

echo "== rewind marks =="
marks=$(git -C "$MIRROR" for-each-ref --sort=-refname --format='%(refname)' 'refs/memory/rewound/*')
if [ -z "$marks" ]; then
    # Deliberately not "upstream never rewrote anything". These record what a
    # run saw, and a rewrite between two runs leaves none — which is what the
    # source comparison below is for.
    echo "  none — no run has had to preserve a rewritten tip."
else
    echo "  $(printf '%s\n' "$marks" | wc -l) rewrite(s) preserved. Nothing was lost; read them with:"
    echo "    git log <mark>                          the history as it stood"
    echo "    git range-diff <mark>...$ref   what the rewrite changed"
    echo
    for m in $marks; do
        # `^{}` peels, and every read below needs it: a mark made by hand is an
        # annotated tag object, and unpeeled `held` would print the tag object's
        # sha — a real sha of the wrong object, in a field nobody would doubt.
        commit=$(git -C "$MIRROR" rev-parse --short "$m^{}")
        # `<ref>..<mark>` is exactly the commits the rewrite dropped:
        # reachable from the preserved tip, not from the ref now.
        dropped=$(git -C "$MIRROR" rev-list --count "$ref..$m^{}" 2>/dev/null || echo '?')
        printf '  %s\n' "$m"
        printf '    rewound  : %s  (from the ref name, which is UTC by construction)\n' "${m##*/}"
        printf '    held     : %s\n' "$commit"
        printf '    dropped  : %s commit(s) no longer on the mirror ref\n' "$dropped"
        # An annotation only a hand-made mark has; the workflow's marks have none.
        if [ "$(git -C "$MIRROR" cat-file -t "$(git -C "$MIRROR" rev-parse "$m")")" = tag ]; then
            printf '    note     : annotated, tagged %s\n' \
                "$(git -C "$MIRROR" for-each-ref --format='%(taggerdate:iso8601)' "$m")"
        fi
    done
fi
echo


# --- the workflow ---
# `state` is the field that matters most and the one nothing else reveals: a
# disabled workflow fails by never running, which looks exactly like an agent
# with nothing to say.  see docs/archive.md#health-and-the-state-field

echo "== the workflow =="
if ! command -v gh >/dev/null 2>&1; then
    echo "  gh is not installed — cannot read the run history."
    unproven+=("gh is not installed, so no run history could be read")
elif [ -z "$archive" ]; then
    echo "  could not derive the archive slug from origin — cannot read the run history."
    unproven+=("the archive slug could not be derived from origin, so no run history could be read")
else
    # gh writes an error body to stdout, so `2>/dev/null` hides only half of a
    # failure and the other half is captured as if it were the answer. The exit
    # status is the only thing worth testing.
    if state=$(gh api "repos/$archive/actions/workflows/$workflow" --jq .state 2>/dev/null); then
        workflow_state="$state"
        case "$state" in
            active) echo "  state      : active" ;;
            disabled_inactivity)
                echo "  state      : DISABLED by GitHub after 60 days of repository inactivity."
                echo "               Nothing has been mirrored since. Re-enable it:"
                echo "                 gh workflow enable $workflow" ;;
            *) echo "  state      : $state" ;;
        esac
    else
        echo "  state      : could not be read — not authenticated, no access, or the"
        echo "               workflow is not on the default branch."
    fi

    run=$(gh run list --repo "$archive" --workflow "$workflow" --limit 1 \
            --json databaseId,status,conclusion,createdAt,url 2>/dev/null)
    # `// empty` and not `.[0].createdAt`: this is what says whether gh
    # answered with a run list at all, and everything below turns on it.
    created=$(printf '%s' "$run" | jq -r '.[0].createdAt // empty' 2>/dev/null)
    if [ -z "$run" ] || [ "$run" = "[]" ]; then
        echo "  last run   : never"
    elif [ -z "$created" ]; then
        # gh answered with something that is not a run list — an error body on
        # stdout, a truncated read — and an age taken from a timestamp that is
        # not there is not an age.  see docs/archive.md#a-reading-that-failed-is-not-a-judgement
        echo "  last run   : COULD NOT BE READ — gh answered, but not with a run list."
        echo "               Lateness is not judged below. Read it by hand:"
        echo "                 gh run list --repo $archive --workflow $workflow"
        unproven+=("gh answered with something that is not a run list, so the last run was not read")
    else
        # GitHub answers in UTC and this is read by a person, so it is turned
        # round here — the age below stays arithmetic on the raw value.
        printf '  last run   : %s  %s\n' \
            "$(date -d "$created" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf '%s' "$created")" \
            "$(printf '%s' "$run" | jq -r '.[0] | "\(.status)/\(.conclusion // "-")"')"
        printf '               %s\n' "$(printf '%s' "$run" | jq -r '.[0].url')"
        last_conclusion=$(printf '%s' "$run" | jq -r '.[0].conclusion // .[0].status')
        # The parse is tested rather than assumed: a timestamp this host cannot
        # read leaves `last_run` empty, and lateness is then not judged.
        if when=$(date -u -d "$created" +%s 2>/dev/null); then
            last_run="$when"
        else
            printf '  age        : UNKNOWN — %s is not a timestamp this host can read.\n' "$created"
        fi

        # A failing run is the whole reason this recipe judges, and the run
        # is not the backup: a workflow may carry jobs beside the mirror, and
        # any one of them failing makes the whole run read failure. So the jobs
        # are read and the verdict is taken from the one that mirrors — asked
        # only when the last run failed, so a healthy mirror costs no second
        # call.  see docs/archive.md#the-run-is-not-the-backup
        if [ "$(printf '%s' "$run" | jq -r '.[0].conclusion // "-"')" = failure ]; then
            id=$(printf '%s' "$run" | jq -r '.[0].databaseId')
            log="gh run view --repo $archive --log-failed $id"
            jobs=$(gh run view "$id" --repo "$archive" --json jobs \
                     --jq '.jobs[] | "\(.name)\t\(.conclusion // "-")"' 2>/dev/null)
            state_of=$(printf '%s\n' "$jobs" | awk -F'\t' -v j="$backup_job" '$1 == j {print $2}')
            # Everything that is not the backup and did not come out of the run
            # clean. `skipped` is a job that was not asked to run and is not a
            # failure of anything.
            others=$(printf '%s\n' "$jobs" \
                       | awk -F'\t' -v j="$backup_job" \
                             'NF && $1 != j && $2 != "success" && $2 != "skipped" {print $1}' \
                       | paste -sd', ' -)
            if [ "$state_of" = success ]; then
                # Loud, and deliberately not a problem: the memory reached the
                # ref. Whatever else that workflow does is the archive's own
                # business and has its own alarm, and calling it a dead backup
                # is how a real one stops being believed.
                printf '  backup job : ok — %s succeeded, and the ref above is what it wrote.\n' "$backup_job"
                printf '  OTHER JOB  : %s failed, and that is why the run reads failure.\n' \
                    "${others:-a job this host could not name}"
                printf '               %s\n' "$log"
            else
                # How many runs in a row, because one is a hiccup and a streak
                # is a broken credential. Nought when a run has succeeded in
                # the seconds between the two calls, and a streak of no runs
                # is not something to print.
                streak=$(gh run list --repo "$archive" --workflow "$workflow" --limit 100 \
                           --json conclusion --jq '[.[].conclusion] | index("success") // length' 2>/dev/null)
                [ "${streak:-0}" -gt 0 ] 2>/dev/null || streak=1
                # A job that could not be read is not one that passed: an
                # archive whose workflow has no such job lands here as well,
                # and the log is the next step for either.
                if [ -n "$state_of" ]; then
                    why="the $backup_job job FAILED"
                else
                    why="the last run FAILED and no $backup_job job could be read in it"
                fi
                problems+=("$why; $streak run(s) have failed in a row — read the log: $log")
            fi
        fi
    fi
fi
echo


# --- late ---
# THE MIRROR IS NOT ON A CLOCK: the workflow has no schedule, and what runs it is
# a session ending more than AGENT_MIRROR_COOLDOWN minutes after the last run, or
# every session end when that is unset. Hours without a run are a machine with
# nothing to say. It is late only when a session HAS ended after the run was due
# and no run followed: a dispatch was owed and did not arrive — and that failure
# says so on stderr, where cron is the only reader.
#
# Before the source comparison, which counts commits behind as unmirrored only
# when something here is already wrong.
#
# The grace is for the seconds between a session ending and its run appearing
# in the list: without it every `just status` in the minute after a session
# would report a backup that is fine as late.
#   see docs/archive.md#late-and-merely-due
GRACE=300
cooldown="${AGENT_MIRROR_COOLDOWN:-}"
case "$cooldown" in ''|*[!0-9]*) cooldown="" ;; esac
due=""
[ -n "$last_run" ] && [ -n "$cooldown" ] && due=$(( last_run + cooldown * 60 ))
late=no
if [ -n "$last_run" ] && [ -n "$session_ended_at" ] \
   && [ "$session_ended_at" -gt "${due:-$last_run}" ] \
   && [ "$(( $(date +%s) - session_ended_at ))" -gt "$GRACE" ]; then
    late=yes
    ago=$(( ( $(date +%s) - session_ended_at ) / 60 ))
    printf '  LATE       : a session ended %sm ago and no run has followed it.\n\n' "$ago"
    problems+=("a session ended ${ago}m ago and no mirror run followed it — the dispatch did not arrive")
fi


# --- against the source ---
# The mirror can be healthy and still be behind: this asks the forge what
# upstream actually holds right now. `diverged` is the interesting answer — it
# means a rewrite has happened that no run has seen yet, and the next run is
# what preserves it.  see docs/archive.md#against-the-source

echo "== against the source =="
if [ -z "$source" ]; then
    echo "  could not read SOURCE_URL from $wf — skipped."
elif ! command -v gh >/dev/null 2>&1; then
    echo "  gh is not installed — skipped."
elif ! git -C "$MIRROR" rev-parse --verify --quiet "$ref" >/dev/null; then
    echo "  nothing mirrored yet — skipped."
else
    base=$(git -C "$MIRROR" rev-parse "$ref")
    # One call, both outcomes read from it. The failures are not noise here —
    # the two below are the loudest signals this recipe has.
    if raw=$(gh api "repos/$source/compare/$base...main" 2>&1); then
        # Three fields off one line, and `read` rather than `set --`: an answer
        # that is not a comparison leaves nothing to split, and the positionals
        # are then UNSET — read under `set -u`, that ends the recipe here, with
        # no verdict and nothing on the screen to say why.
        #   see docs/archive.md#a-reading-that-failed-is-not-a-judgement
        read -r how ahead behind <<<"$(printf '%s' "$raw" \
            | jq -r '"\(.status) \(.ahead_by) \(.behind_by)"' 2>/dev/null)"
        case "$how" in
            identical) echo "  current — $source@main is exactly what is mirrored." ;;
            ahead)     printf '  behind by %s commit(s).\n' "$ahead"
                       if [ ${#problems[@]} -eq 0 ]; then
                           echo "  The next run fast-forwards — a session ending asks for one."
                       else
                           problems+=("$ahead commit(s) of $AGENT_NAME's memory are NOT mirrored")
                       fi ;;
            diverged)  printf '  DIVERGED — %s ahead, %s behind. Upstream rewrote history and no run\n' "$ahead" "$behind"
                       echo "  has seen it yet. The next run marks the tip above before resetting." ;;
            '')        echo "  could not be read — $source answered, but not with a comparison." ;;
            *)         printf '  %s (ahead %s, behind %s)\n' "$how" "$ahead" "$behind" ;;
        esac
    else
        case "$raw" in
            # Not an error to report as one: the forge is saying the two
            # histories share no root at all — a replacement rather than a
            # rewrite. The mechanism handles it identically, and this is the
            # window in which nothing has recorded it yet.
            *"No common ancestor"*)
                echo "  UNRELATED — $source@main shares no ancestor with the mirrored tip."
                echo "  The history was replaced, not extended. Nothing is lost: the next run"
                echo "  marks $(git -C "$MIRROR" rev-parse --short "$ref") at refs/memory/rewound/<ts>, pushes it, then resets." ;;
            *"Not Found"*)
                echo "  the mirrored tip is no longer known to $source."
                echo "  A tip upstream cannot find is itself the signal: it was rewritten away"
                echo "  and garbage-collected. Only our copy holds it now." ;;
            *)  printf '  could not compare against %s:\n    %s\n' "$source" \
                    "$(printf '%s' "$raw" | head -1 | cut -c1-120)" ;;
        esac
    fi
fi


# --- what --state prints ---
# The lateness judgement is made above and not by the screen that shows it, for
# the reason the verdict below is: one place decides, everyone else reads.

emit_state() {
    local verdict="$1" p u
    {
        printf 'verdict: %s\n' "$verdict"
        printf 'workflow: %s\n' "${workflow_state:-unknown}"
        printf 'last_run: %s\n' "$last_run"
        printf 'conclusion: %s\n' "$last_conclusion"
        printf 'cooldown: %s\n' "$cooldown"
        printf 'due: %s\n' "$due"
        printf 'late: %s\n' "$late"
        printf 'tip_written: %s\n' "$tip_written"
        printf 'tip_commits: %s\n' "$tip_commits"
        for p in "${problems[@]}"; do printf 'problem: %s\n' "$p"; done
        for u in "${unproven[@]}"; do printf 'unproven: %s\n' "$u"; done
    } >&3
}


# --- the verdict ---
# Last, and it decides the exit status: `just status` and `just verify` read
# that rather than parsing this screen, so the judgement lives in one place.
# The mirror is the agent's memory outliving a repository the agent may rewrite
# — a backup that has stopped is a FAIL here, never a note.
#
# Three answers and not two: 0 ran, 1 stopped, 2 could not be read. Not proven
# is not proven, and an ok on a reading that failed is the same lie as a FAIL
# on one.  see docs/archive.md#a-reading-that-failed-is-not-a-judgement

echo
if [ ${#problems[@]} -eq 0 ] && [ ${#unproven[@]} -eq 0 ]; then
    emit_state running
    echo "== verdict =="
    echo "  ok — the backup is running."
    echo
    echo "Run it now:  gh workflow run $workflow --repo ${archive:-<the archive>}"
elif [ ${#problems[@]} -eq 0 ]; then
    emit_state unproven
    echo "== verdict =="
    echo "  UNPROVEN — nothing here says the backup stopped, and nothing says it ran."
    for u in "${unproven[@]}"; do printf '    - %s\n' "$u"; done
    echo
    echo "Run it now:  gh workflow run $workflow --repo ${archive:-<the archive>}"
    exit 2
else
    emit_state stopped
    echo "== verdict =="
    echo "  FAIL — THE BACKUP IS NOT RUNNING."
    for p in "${problems[@]}"; do printf '    - %s\n' "$p"; done
    echo
    echo "  Nothing is lost while $AGENT_NAME's own origin holds its memory; what is"
    echo "  missing is the copy that outlives a rewrite. 'just setup-mirror' is what"
    echo "  replaces the read key when the failure is Permission denied (publickey)."
    echo
    echo "Run it now:  gh workflow run $workflow --repo ${archive:-<the archive>}"
    exit 1
fi
