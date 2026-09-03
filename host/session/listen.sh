#!/usr/bin/env bash
# A running session from its first line, live — or the last one's tail, or all
# of it.
#
# Runs on the host. Every declared argument arrives as an environment
# variable: the flags all, wait, live and summary, and the message count n.
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
#
# shellcheck disable=SC2016  # the single-quoted lines below are a program for
# a shell inside the container: `$f` and `$HOME` are its variables, and
# expanding them out here would name a path on the host.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    typed=()
    typed_flag --all "$all"
    # --live is the stronger of the pair: it implies the wait, so only one of
    # the two is ever rebuilt.
    if [ "$live" = yes ]; then typed+=(--live); else typed_flag --wait "$wait"; fi
    [ "$summary" = yes ] || typed+=(--no-summary)
    [ "$all" = yes ] || typed+=("$n")
    forward_to_deployed listen ${typed[@]+"${typed[@]}"}
fi

host/lib/docker-up.sh --image "${RUNNER_IMAGE:-$RUNNER_IMAGE_DEPLOYED}" || exit $?


# --- which session, and whether this follows ---
# Whether this follows is not a flag: a running session is one you want whole
# and live, a finished one is a file that will never grow again, and `docker ps`
# tells them apart. So a running session comes first whatever was asked for, and
# the flags only say what happens when there is none — `--wait` waits and gives
# the prompt back at the end, `--live` waits again, the plain form reads the
# last session's tail.
#
# `seen` and `began` are settled here rather than in the watch loop below: the
# loop only asks docker every five seconds, so a session that ends inside those
# first seconds would never be seen at all, and a follow that never saw one
# never closes itself.
# see docs/sessions.md#watching-a-session-live

source host/lib/session-lock.sh
follow=false
seen=false
began=0
since=0

if [ -n "$(session_container)" ]; then
    follow=true
    seen=true
    # The running session's own transcript and not the one before it: the
    # container is up for a few seconds before Claude Code writes a first line,
    # and the container's start is the floor that tells them apart.
    began=$(session_started || echo 0)
    since=$began
elif [ "$wait" = yes ] || [ "$live" = yes ]; then
    follow=true
    # The +1 second is the whole guard against following the previous session's
    # transcript: one that ended inside the current second would otherwise pass
    # "newer than now" and be tailed forever.
    since=$(( $(date +%s) + 1 ))
fi


# --- what is read out of the volume ---
# Rendered from the transcript in the volume, the same file `just collect`
# archives afterwards. Nothing is added to the session to make this work.
#
# Read as the agent rather than root: the transcripts are 0600 owned by that
# uid, and a root container is the one that leaves root-owned files behind.
# --entrypoint overrides the bootstrap, so no session starts.
#
# `cond` is one definition of what counts as a message, because two things have
# to agree about it: the count `just listen N` takes, and what is rendered.

cond='(.type == "assistant" or .type == "user") and .isSidechain != true'

# Not reading: the newest transcript there is, and nothing to read is an error.
# Following: wait for one at least as new as $since, because the newest file
# right now may be the previous session's. The wait is in the container because
# that is where the volume is; $since is decided out here, where docker can be
# asked, and rebuilt per session because --live follows more than once.
follow_cmd() {
    printf '%s\n' \
        'while :; do' \
        "  f=\$(ls -t \"\$HOME\"/.claude/projects/$AGENT_PROJECT_DIR/*.jsonl 2>/dev/null | head -1)" \
        "  [ -n \"\$f\" ] && [ \"\$(stat -c %Y \"\$f\")\" -ge $since ] && break" \
        '  sleep 1' \
        'done' \
        'echo "reading ${f##*/}" >&2' \
        'exec tail -n +1 -F "$f"'   # the session from its first line
}

if [ "$follow" = false ]; then
    locate=$(printf '%s\n' \
        "f=\$(ls -t \"\$HOME\"/.claude/projects/$AGENT_PROJECT_DIR/*.jsonl 2>/dev/null | head -1)" \
        '[ -n "$f" ] || { echo "No transcript in the volume yet." >&2; exit 1; }')
    # A ceiling on the file, not on the count asked for: it guards the default
    # path against reading a session-long file to print twenty messages, and
    # says so when it bites, because a silent clip looks exactly like a complete
    # transcript. `--all` removes it, and the message count with it.
    # see docs/sessions.md#the-4000-line-ceiling
    if [ "$all" = yes ]; then
        reader='exec cat "$f"'
    else
        reader=$(printf '%s\n' \
            't=$(wc -l < "$f")' \
            '[ "$t" -gt 4000 ] && echo "note: the last 4000 of $t transcript lines; --all reads the whole file." >&2' \
            'exec tail -n 4000 "$f"')
    fi
    cmd=$(printf '%s\n' \
        "$locate" \
        'echo "reading ${f##*/}" >&2' \
        "$reader")
fi


# --- how a message is drawn ---
# The escapes arrive as jq arguments rather than as literals in the program: a
# control character in a source file is invisible to whoever edits it next.
#
# The formatting lives in host/session/transcript.jq, which `just read` also
# includes. What stays here is $cond: which entries to show is this script's own
# question, and its one answer is used twice — by this select and by the count
# the reading path takes below.

dim=$(printf '\033[2m'); bold=$(printf '\033[1m'); off=$(printf '\033[0m')

render='include "transcript"; select('"$cond"') | render'

colours=(-L host/session --arg dim "$dim" --arg bold "$bold" --arg off "$off"
         --arg runner "$RUNNER_SAYS"
         --arg agent "${AGENT_NAME,,}"
         --arg operator "${OPERATOR_NAME,,}"
         --argjson full false)

# Ctrl-C is how this is meant to end, so it must not come back as a failure: a
# non-interactive bash dies with 130 on SIGINT's default action, and the status
# check that would normalise it never runs. Ahead of both branches on purpose —
# interrupting a long render is the same act as interrupting a follow.
trap 'echo; exit 0' INT


# --- following ---
# One pass per session: the wait, the container and what has been seen are all
# set up inside this loop and torn down before the next turn of it, because
# --live takes another. Without --live the pass ends at the exit below.

if [ "$follow" = true ]; then
    while :; do
        # Rebuilt per pass and not per run: $since is baked into the wait this
        # returns, and it moves with every session.
        cmd=$(follow_cmd)
        # What was found and not what was asked for: `--wait` on a running
        # session follows it, and announcing a wait there would describe a
        # different recipe than the one running.
        if [ "$seen" = true ]; then
            echo "A session is running. Following it from the top; press q to stop."
        else
            echo "Waiting for a session to start."
        fi

        # `set -m` puts the pipeline in a process group of its own, which makes
        # one kill end both halves and keeps `just` out of the blast radius. The
        # same isolation means Ctrl-C no longer reaches the pipeline, so the
        # trap below ends it explicitly. </dev/null is what makes `q` reachable:
        # `compose run` attaches stdin even with -T, and would swallow the
        # keypress the read loop below is waiting for.
        #
        # --name, because ending the client does not end the container, and a
        # name is the only handle stop() can use. $$ keeps two follows apart.
        # see docs/sessions.md#stopping-a-follow-without-leaving-anything-behind
        name="$AGENT_USER-listen-$$"
        set -m
        docker compose run --rm -T --name "$name" --entrypoint sh agent -c "$cmd" </dev/null \
            | jq -r --unbuffered "${colours[@]}" "$render" &
        pgid=$(jobs -p %%)
        set +m

        # `stopped` is the difference between "the user asked" and "it fell
        # over": without it a compose that cannot start looks like a clean quit.
        #
        # stop() waits for the group to actually go, because `compose run --rm`
        # removes the container while it shuts down. Polling rather than `wait`,
        # since in the piped path the trap interrupts a `wait` already running
        # and a second one returns immediately.
        #
        # INT and not TERM: on TERM compose abandons the removal `--rm`
        # promised, on INT it stops the container and removes it.
        stopped=false
        stop() {
            stopped=true
            # The container first: removing it is what actually ends the
            # follow, and it makes the client exit and jq read EOF on its own.
            # The signal after is not a second cure for the same ailment — it
            # ends a client whose container never started.
            docker rm -f "$name" >/dev/null 2>&1
            kill -INT -"$pgid" 2>/dev/null
            for _ in $(seq 50); do kill -0 -"$pgid" 2>/dev/null || break; sleep 0.1; done
            # Again, and not out of superstition: a stop landing while compose
            # is still creating the container finds nothing, and the container
            # turns up a moment later outliving the client that asked for it.
            docker rm -f "$name" >/dev/null 2>&1
        }
        trap 'stop; echo; exit 0' INT

        # A follow does not end when the session does: `tail -F` holds a file
        # that has stopped growing, and nothing in the transcript marks the end.
        # The container going away is the end — and only after one has been
        # seen, which is the whole guard for --wait: a viewer that closed on "no
        # container" would close the instant it opened.
        # see docs/sessions.md#when-a-follow-ends
        ended=false
        key=""
        while kill -0 -"$pgid" 2>/dev/null; do
            # No keyboard when stdin is not a terminal, but the wait still has
            # to happen or the poll below spins. -t so the loop keeps its own
            # time rather than blocking on a key that may never come; -s so the
            # keypress is not echoed into the transcript being rendered.
            if [ -t 0 ]; then
                IFS= read -rsn1 -t 0.5 key
                [ "$key" = q ] && { stop; break; }
                key=""
            else
                sleep 0.5
            fi

            # docker every tenth pass only — five seconds — as `lock_wait` does
            # it: the arithmetic is free and `docker ps` is a process each time.
            # That interval is also how late the close can be.
            ticks=$(( ${ticks:-0} + 1 ))
            [ $((ticks % 10)) -eq 0 ] || continue

            if [ -n "$(session_container)" ]; then
                if [ "$seen" = false ]; then
                    seen=true
                    began=$(session_started || echo 0)
                fi
            elif [ "$seen" = true ]; then
                # The same two seconds `run --listen` waits before it stops its
                # own viewer, and for the same reason: the closing message is
                # written immediately before the session exits, so stopping as
                # the container goes loses the end of what you asked to watch.
                sleep 2
                ended=true
                stop
                break
            fi
        done

        wait "$pgid" 2>/dev/null; status=$?
        $stopped && status=0

        if [ "$ended" = true ]; then
            echo
            echo "The session ended."
            if [ "$summary" = yes ]; then
                echo
                # --since the container started, so a session that wrote no
                # transcript says so rather than summarising the one before.
                host/session/session-stats.py --since "$began" || true
            fi
        fi

        # Where --live parts from --wait: the end of a session is a shell prompt
        # for one and the beginning of the next wait for the other. Anything but
        # a session that ended leaves — a compose that would not start, or a
        # `q`, is not a thing to sit through twice.
        if [ "$live" != yes ] || [ "$ended" != true ]; then exit $status; fi

        # What is still not live, in the gap where a person decides whether to
        # go and deploy it. The tree that would be deployed is not the one this
        # script is running in — `just listen` forwarded here — so it is asked
        # about by path.
        echo
        echo
        pending=$(host/release/undeployed.sh "$RUNNER_ROOT" || true)
        if [ -n "$pending" ]; then
            printf 'The runner tree has %s.\n' "$pending"
        else
            echo "The runner tree is clean and fully deployed."
        fi
        echo

        # The next session and never the one just watched, whose transcript is
        # newer than the floor this pass used: a loop that kept $since would
        # follow that same file again and wait for an end that has already
        # happened.
        seen=false
        began=0
        ticks=0
        since=$(( $(date +%s) + 1 ))
    done
fi


# --- reading ---
# The count is in messages, not lines, so the selection happens before the
# rendering — a rendered message is many lines. The quiet progress set in the
# justfile keeps compose from narrating the container it made over the first
# message. `cat` and not a very large N: a number here is the same lie the 4000
# was, one layer up.

if [ "$all" = yes ]; then take=(cat); else take=(tail -n "$n"); fi

docker compose run --rm -T --entrypoint sh agent -c "$cmd" \
    | jq -c "select($cond)" \
    | "${take[@]}" \
    | jq -r "${colours[@]}" "$render"
status=$?

# Where this transcript stands. Read on its own, the tail of a session says
# nothing about whether another is coming — the difference between waiting and
# going to look. `just status` answers at length; this is its first line, from
# its own implementation.
#
# Asked again rather than assumed from the branch above: a session can start
# between choosing to read and finishing the read, and "No session is running"
# under a session that just began is the kind of sentence nobody re-checks.
echo
if [ -n "$(session_container)" ]; then
    echo "A session has started since. Run 'just listen' again to follow it."
else
    session_absent_line
fi
exit $status
