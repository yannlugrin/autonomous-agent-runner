#!/usr/bin/env bash
# Whether a session is running, what it has spent, whether scheduling is on,
# what the review gate is holding, and what is live.
#
# Runs on the host. No arguments.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    forward_to_deployed status
fi

host/lib/docker-up.sh || exit $?
source host/lib/session-lock.sh
source host/lib/run-record.sh


# --- is a session running ---
# The container is the evidence, and the lock deliberately is not: there is no
# way to test a flock without taking it, and a `just run` starting in that
# instant would find it held and stand down.
# see docs/sessions.md#where-just-status-gets-its-answers

c=$(session_container)
if [ -n "$c" ]; then
    # Whether a session will start on its own, on the same line as what is
    # running now; `session_absent_line` below carries the same clause.
    scheduling=$(scheduling_phrase)
    since=$(session_started || echo "")
    if [ -n "$since" ]; then
        printf 'A session is running: %s, started %s, up %s. %s\n' \
            "$(session_kind)" "$(date -d "@$since" +%H:%M)" \
            "$(elapsed $(( $(date +%s) - since )))" "$scheduling"
    else
        # Running but unreadable: docker answered `ps` and not `inspect`. Say
        # the half that is known rather than nothing.
        printf 'A session is running: %s. %s\n' "$(session_kind)" "$scheduling"
    fi
    printf '  %s\n' "$(printf '%s' "$c" | tr '\t' ' ')"
    echo
    # --since, so a session that has not written its first line yet says so
    # rather than reporting the previous session's numbers as this one's.
    host/session/session-stats.py --since "${since:-0}" || true
else
    # The same sentence `just listen` ends on, from the same implementation: two
    # recipes answering "is anything running?" differently is a bug you only
    # find by holding them side by side.
    session_absent_line
    # A stop nobody has been told about yet, which is the state worth seeing
    # here: it may sit for hours while wake-ups stand down on the same limit
    # that caused it. Said only when there is one — a clean end is every other
    # day and a line saying so would be a line nobody reads.
    # see docs/sessions.md#recovering-a-session-that-was-stopped
    last_run=$(run_record_verdict no)
    case "$last_run" in
    stopped*) printf '  The last run was stopped (%s). The next session opens with what it was doing.\n' \
                  "${last_run#stopped }" ;;
    esac
    # A shell or a probe is not a session and holds no lock, but "nothing is
    # running" while you are sitting in a container is a misleading answer.
    other=$(service_container)
    [ -n "$other" ] && printf '  A container is up that is not a session: %s\n' "$other"
    echo
    host/session/session-stats.py || true
fi


# --- what the budget gate sees ---
# Asked of the gate itself rather than recomputed here: it is the only place the
# arithmetic lives. It also renews the container's access token, which is why
# looking at status once a week keeps the unattended path alive on a schedule
# that has been paused.  see docs/budget.md
#
# 2>&1 because the two halves go to different places on purpose: the numbers to
# stdout, the one line it writes when it cannot tell to stderr. An empty answer
# is not "no limits" — no docker, no credential, a gate that could not start.

echo
echo "Budget:"
# Read in both guard states, as session-env.sh does: off, the read is advisory
# and the session is still told these numbers. Exactly `true` arms it, the one
# comparison session-env.sh makes.
if [ "${ACCOUNT_BUDGET_GUARD:-}" = true ]; then
    budget=$(python3 ./image/claude-usage.py 2>&1)
    guard_line="ACCOUNT_BUDGET_GUARD is on: a session over the line is refused."
else
    budget=$(python3 ./image/claude-usage.py --advisory 2>&1)
    guard_line="ACCOUNT_BUDGET_GUARD is off: nothing on this host refuses a session on budget; a session is told these numbers for information only."
fi
if [ -n "$budget" ]; then
    printf '%s\n' "$budget" | sed 's/^/  /'
else
    echo "  the reading did not answer — run 'just verify' to see why."
fi
echo "  $guard_line"


# --- what the review gate is holding back ---
# Asked of the collection script rather than scanned again here: one rule, one
# implementation. It costs a couple of seconds, because answering means
# extracting the transcripts and scanning them; it stops before staging
# anything, so it is safe beside a running session.  see docs/archive.md
#
# A missing line is not a zero. No archive to read the ledger from, no docker, a
# scan that could not run: reporting "none waiting" for any of those is the gate
# failing silently.

echo
pending=$(host/archive/collect.sh --held 2>&1 \
    | sed -n 's/^waiting-on-review: //p')
if [ -z "$pending" ]; then
    echo "Transcripts: the review gate did not answer — run 'just collect' to see why."
elif [ "$pending" -eq 0 ]; then
    echo "Transcripts: none waiting on review."
else
    printf "Transcripts: %s waiting on review, held out of the archive — 'just collect' prints what and why.\n" "$pending"
fi


# --- whether the agent has granted itself anything ---
# Here rather than in `verify` because it is a fact about the volume and not
# about the image: verify proves the candidate on a twin with no volume, and
# would answer this about a world nobody lives in. It spends no budget — no
# session, one `--entrypoint python3` container.
#
# It reports and never refuses: a settings edit that stood a session down would
# let the agent lock itself out of its own container.

host/release/check-agent-settings.sh || true
echo


# --- what is live ---
# What cron runs, and how far it is behind what is here — from the one recipe
# that decides the branch, the tags and the path.

ds=$(just deploy --state 2>/dev/null)
field() { printf '%s\n' "$ds" | sed -n "s/^$1: //p"; }

if [ -z "$ds" ]; then
    echo "Deployed: unknown — 'just deploy --state' did not answer."
elif [ "$(field worktree)" = absent ]; then
    echo "Deployed: nothing yet — 'just deploy' creates $RUNNER_DEPLOYED on its first run."
else
    d=$(field deployed); a=$(field ahead); di=$(field image_deployed)
    case "$a" in
        0) behind="up to date with main" ;;
        -|'') behind="no deployed branch" ;;
        *) behind="$a commit(s) behind main" ;;
    esac
    # The image is named and nothing is claimed about it: `deploy` builds from
    # the deployed checkout, so the two cannot differ and there is no comparison
    # left to report; the candidate belongs to `verify`.  see docs/release.md
    if [ "$di" = "-" ]; then img="no image tagged deployed"
    else img="image $di"
    fi
    echo "Deployed: $d, $behind; $img."
    # The subjects, and not only the count: this is where a person decides
    # whether a deploy is worth doing, and the commit messages are what say so.
    # Uncapped on purpose — a backlog long enough to scroll is the thing worth
    # seeing, not noise to fold behind its own count.
    field commit | sed 's/^/  /'
    dc=$(field dropped_commit)
    if [ -n "$dc" ]; then
        echo "  Live and NOT in main — a deploy would drop:"
        printf '%s\n' "$dc" | sed 's/^/    /'
    fi
fi
