#!/usr/bin/env bash
# How the mirror is doing — is it running, is it current, was anything rewound.
# Runs on the host, against the archive checkout. No arguments.
#
# Everything here reads. Each of the archive's two records has exactly one
# writer, and a second writer on a record whose whole value is that it has one
# would be the end of it; both are read through `git show` and `git for-each-ref`
# so the archive clone stays on whatever branch it is on, however dirty.
#   see docs/archive.md#the-mirror
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/archive.sh

need_archive

ref="refs/archive/$AGENT_USER"
workflow="${AGENT_ARCHIVE_WORKFLOW:-mirror-$AGENT_USER.yml}"

# What is wrong, collected as it is found and judged at the end. This recipe
# used to only describe; a backup that has stopped reads exactly like one that
# is idle, and describing both in the same words is how three days passed.
# see docs/archive.md#the-key-goes-on-before-the-secret-goes-in
problems=()


# --- who is mirroring whom ---
# Slugs are derived, never written down twice: the archive's from the remote,
# the source's from the workflow, which is what decides what gets mirrored.
# Three substitutions rather than one capture, since ERE has no lazy quantifier
# and the tempting one leaves the `.git` on.  see docs/archive.md#against-the-source

archive=$(git -C "$ARCHIVE" remote get-url origin 2>/dev/null \
    | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^https?://[^/]+/##')
wf="$ARCHIVE/.github/workflows/$workflow"
source=$(sed -n 's#^ *SOURCE_URL: *git@github.com:\(.*\)\.git *$#\1#p' "$wf" 2>/dev/null)


# --- the fetch ---
# A status read off stale refs is worse than none, so fetching is first and a
# failure says so rather than being swallowed. The archive namespace is named
# explicitly because a clone's default refspec does not carry it, and everything
# below would otherwise report "the mirror has never run" on a healthy one.
#   see docs/archive.md#a-ref-not-a-branch

printf 'fetching     : '
if git -C "$ARCHIVE" fetch --quiet --prune origin \
    '+refs/archive/*:refs/archive/*' 2>/dev/null; then
    echo 'ok'
else
    echo 'FAILED — everything below is from local refs and may be stale'
fi
echo


# --- the mirror ref ---
# A ref, and not a branch: only refs/heads/* and refs/tags/* start workflow runs,
# and this ref carries the agent's tree, workflow files included. The cost is
# that it is not browsable on github.com, and this recipe is how you read it.
#   see docs/archive.md#a-ref-not-a-branch

echo "== the mirror ref =="
if ! git -C "$ARCHIVE" rev-parse --verify --quiet "$ref" >/dev/null; then
    echo "  $ref does not exist. Either the mirror has"
    echo "  never completed a run, or this clone has never fetched the"
    echo "  namespace — the fetch above does ask for it."
    echo "  gh workflow run $workflow"
else
    tip=$(git -C "$ARCHIVE" rev-parse --short "$ref")
    # Local time, because a person reads it: this screen answers "when did that
    # happen, for me".
    when=$(git -C "$ARCHIVE" log -1 --format=%cd --date=iso-local "$ref")
    # The tip is the agent's activity, not the mirror's health — the ref only
    # moves when the agent pushed. The workflow section below reports health.
    printf '  tip        : %s  %s\n' "$tip" "$(git -C "$ARCHIVE" log -1 --format=%s "$ref")"
    # Whether silence here is a quiet agent or a dead mirror is not knowable
    # from this line — the workflow section decides it, and the verdict says so.
    printf '  written    : %s  (by %s)\n' "$when" "$AGENT_NAME"
    printf '  commits    : %s\n' "$(git -C "$ARCHIVE" rev-list --count "$ref")"
fi
echo


# --- rewind marks ---
# The one thing this archive exists to catch: a mark means the upstream history
# was rewritten and the tip we held was preserved before the ref was reset onto
# the new one. Plain refs under refs/archive/rewound/ and not annotated tags,
# since refs/tags/ triggers workflows on push. Everything shown is derived from
# the refs, so nothing can fall out of step with them.
#   see docs/archive.md#rewind-marks

echo "== rewind marks =="
marks=$(git -C "$ARCHIVE" for-each-ref --sort=-refname --format='%(refname)' 'refs/archive/rewound/*')
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
        commit=$(git -C "$ARCHIVE" rev-parse --short "$m^{}")
        # `<ref>..<mark>` is exactly the commits the rewrite dropped:
        # reachable from the preserved tip, not from the ref now.
        dropped=$(git -C "$ARCHIVE" rev-list --count "$ref..$m^{}" 2>/dev/null || echo '?')
        printf '  %s\n' "$m"
        printf '    rewound  : %s  (from the ref name, which is UTC by construction)\n' "${m##*/}"
        printf '    held     : %s\n' "$commit"
        printf '    dropped  : %s commit(s) no longer on the mirror ref\n' "$dropped"
        # An annotation only a hand-made mark has; the workflow's marks have none.
        if [ "$(git -C "$ARCHIVE" cat-file -t "$(git -C "$ARCHIVE" rev-parse "$m")")" = tag ]; then
            printf '    note     : annotated, tagged %s\n' \
                "$(git -C "$ARCHIVE" for-each-ref --format='%(taggerdate:iso8601)' "$m")"
        fi
    done
fi
echo


# --- the workflow ---
# `state` is the field that matters most and the one nothing else reveals:
# GitHub disables a schedule after 60 days of repository inactivity, and a
# disabled workflow fails by never running, which looks exactly like an agent
# with nothing to say.  see docs/archive.md#health-and-the-state-field

echo "== the workflow =="
if ! command -v gh >/dev/null 2>&1; then
    echo "  gh is not installed — cannot read the run history."
elif [ -z "$archive" ]; then
    echo "  could not derive the archive slug from origin — cannot read the run history."
else
    # gh writes an error body to stdout, so `2>/dev/null` hides only half of a
    # failure and the other half is captured as if it were the answer. The exit
    # status is the only thing worth testing.
    if state=$(gh api "repos/$archive/actions/workflows/$workflow" --jq .state 2>/dev/null); then
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
            --json status,conclusion,createdAt,url 2>/dev/null)
    if [ -z "$run" ] || [ "$run" = "[]" ]; then
        echo "  last run   : never"
    else
        # GitHub answers in UTC and this is read by a person, so it is turned
        # round here — the age below stays arithmetic on the raw value.
        created=$(printf '%s' "$run" | jq -r '.[0].createdAt')
        printf '  last run   : %s  %s\n' \
            "$(date -d "$created" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf '%s' "$created")" \
            "$(printf '%s' "$run" | jq -r '.[0] | "\(.status)/\(.conclusion // "-")"')"
        printf '               %s\n' "$(printf '%s' "$run" | jq -r '.[0].url')"
        # Hourly, and GitHub drops scheduled runs under load, so a missed hour
        # is normal and six in a row is not: past that runs are being skipped
        # or failing, whatever the last conclusion was.
        age=$(( ( $(date -u +%s) - $(date -u -d "$created" +%s) ) / 3600 ))
        [ "$age" -ge 6 ] && {
            printf '  STALE      : %s hours since the last run; it is scheduled hourly.\n' "$age"
            problems+=("no run for $age hours, on an hourly schedule")
        }

        # A failing run is the whole reason this recipe judges. How many in a
        # row, because one is a hiccup and a streak is a broken credential —
        # asked only when the last one failed, so a healthy mirror costs no
        # second call.
        if [ "$(printf '%s' "$run" | jq -r '.[0].conclusion // "-"')" = failure ]; then
            streak=$(gh run list --repo "$archive" --workflow "$workflow" --limit 100 \
                       --json conclusion --jq '[.[].conclusion] | index("success") // length' 2>/dev/null)
            problems+=("the last ${streak:-1} run(s) FAILED — read the log: gh run view --repo $archive --log-failed \$(gh run list --repo $archive --workflow $workflow --limit 1 --json databaseId --jq '.[0].databaseId')")
        fi
    fi
fi
echo


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
elif ! git -C "$ARCHIVE" rev-parse --verify --quiet "$ref" >/dev/null; then
    echo "  nothing mirrored yet — skipped."
else
    base=$(git -C "$ARCHIVE" rev-parse "$ref")
    # One call, both outcomes read from it. The failures are not noise here —
    # the two below are the loudest signals this recipe has.
    if raw=$(gh api "repos/$source/compare/$base...main" 2>&1); then
        # Split on purpose: three fields off one line, into $1 $2 $3.
        # shellcheck disable=SC2046
        set -- $(printf '%s' "$raw" | jq -r '"\(.status) \(.ahead_by) \(.behind_by)"')
        case "$1" in
            identical) echo "  current — $source@main is exactly what is mirrored." ;;
            ahead)     printf '  behind by %s commit(s).\n' "$2"
                       if [ ${#problems[@]} -eq 0 ]; then
                           echo "  The next hourly run fast-forwards."
                       else
                           problems+=("$2 commit(s) of $AGENT_NAME's memory are NOT mirrored")
                       fi ;;
            diverged)  printf '  DIVERGED — %s ahead, %s behind. Upstream rewrote history and no run\n' "$2" "$3"
                       echo "  has seen it yet. The next run marks the tip above before resetting." ;;
            *)         printf '  %s (ahead %s, behind %s)\n' "$1" "$2" "$3" ;;
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
                echo "  marks $(git -C "$ARCHIVE" rev-parse --short "$ref") at refs/archive/rewound/<ts>, pushes it, then resets." ;;
            *"Not Found"*)
                echo "  the mirrored tip is no longer known to $source."
                echo "  A tip upstream cannot find is itself the signal: it was rewritten away"
                echo "  and garbage-collected. Only our copy holds it now." ;;
            *)  printf '  could not compare against %s:\n    %s\n' "$source" \
                    "$(printf '%s' "$raw" | head -1 | cut -c1-120)" ;;
        esac
    fi
fi


# --- the verdict ---
# Last, and it decides the exit status: `just status` and `just verify` read
# that rather than parsing this screen, so the judgement lives in one place.
# The mirror is the agent's memory outliving a repository the agent may rewrite
# — a backup that has stopped is a FAIL here, never a note.

echo
if [ ${#problems[@]} -eq 0 ]; then
    echo "== verdict =="
    echo "  ok — the backup is running."
    echo
    echo "Run it now:  gh workflow run $workflow --repo ${archive:-<the archive>}"
else
    echo "== verdict =="
    echo "  FAIL — THE BACKUP IS NOT RUNNING."
    for p in "${problems[@]}"; do printf '    - %s\n' "$p"; done
    echo
    echo "  Nothing is lost while $AGENT_NAME's own origin holds its memory; what is"
    echo "  missing is the copy that outlives a rewrite. 'just setup-archive' is what"
    echo "  replaces the read key when the failure is Permission denied (publickey)."
    echo
    echo "Run it now:  gh workflow run $workflow --repo ${archive:-<the archive>}"
    exit 1
fi
