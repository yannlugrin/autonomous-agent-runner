# shellcheck shell=bash
# Run one of this repository's own recipes in the deployed checkout — the one
# cron runs from — rather than in the working tree you are standing in.
#
# Sourced by the scripts that are the live runner: run, chat, shell, listen,
# read, status, collect, publish-status. They act on the deployed environment
# by default — its recipes, its scripts, its `.env`, its image — because a live
# command that ran the working tree would make every edit live before any
# deploy, which is the hole `just deploy` closes. Testing is what runs here:
# `verify`, `test-env`, and `just shell --build`.
#
# What was typed cannot be forwarded: `just` parses the declared flags itself
# and hands the script their values, so the argv is gone by the time anything
# here runs. Each caller rebuilds the flags it is on, in the spelling the
# deployed recipe parses, into the array `typed`.
# see docs/sessions.md#always-the-deployed-checkout

RUNNER_DEPLOYED="${RUNNER_DEPLOYED:?not set — run this through 'just', which computes it}"

# Where the agent runs, when that is not this machine. Sourced here rather than
# by each caller: every script that forwards has the same two destinations, and
# a live command reaching the wrong one is the failure this file exists against.
# shellcheck source=SCRIPTDIR/deploy-host.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/deploy-host.sh"


# --- typed_flag ---
# One flag onto `typed`, when it is on. `yes`/`no` is what every declared flag
# in the justfile carries, so this is the whole of the rebuild for a flag.

typed_flag() {
    [ "$2" = yes ] && typed+=("$1")
    return 0
}


# --- forward_to_deployed ---
# forward_to_deployed <recipe> [rebuilt flags...]. Never returns: it either
# execs `just` over there or exits.
#
# "Over there" is a directory on this machine, or a machine of its own when
# RUNNER_DEPLOY_HOST names one — the same recipe, on whichever host the volume
# and the live image are. Without this, every live verb typed here would act on
# the copy of the volume this machine still has, and the two would each push a
# memory to origin. see docs/sessions.md#always-the-deployed-checkout

forward_to_deployed() {
    local verb="$1" heads_up what reply dir rc
    shift

    if ! deploying_elsewhere && [ ! -e "$RUNNER_DEPLOYED/justfile" ]; then
        echo "Nothing is deployed yet: there is no checkout at $RUNNER_DEPLOYED, so there is no" >&2
        echo "agent to reach from here. 'just build', 'just verify', 'just deploy' makes one." >&2
        echo "To look inside a candidate instead, 'just shell --build'; 'just verify' proves it." >&2
        exit 1
    fi

    # How loudly depends on what follows: the question is worth asking only
    # where answering `n` saves something. `listen` and `read` only look, so `n`
    # does nothing an interrupt would not; `status` reports the same fact three
    # lines later, in full. An unrecognised verb asks, because the recipe that
    # has not been thought about is the one to be careful with.
    # see docs/sessions.md#how-loudly-the-forwarder-speaks
    case "$verb" in
        listen|read)        heads_up=tell ;;
        status|credentials) heads_up=none ;;
        *)                  heads_up=ask ;;
    esac

    # A heads-up when this tree is not what is deployed: a person typing `just
    # chat` here while sitting on undeployed commits may have forgotten to
    # deploy, or may mean exactly this — so it asks, and Enter means go on. Not
    # a gate: with no terminal to ask on it says so and continues, because a
    # scripted `just listen` must not hang on a question. The deployed checkout
    # itself never gets here, so cron is never asked.
    #
    # The phrase comes from undeployed.sh, which `just listen --live` also
    # prints between sessions: one spelling of what is not live.
    if [ "$heads_up" != none ]; then
        what=$(host/release/undeployed.sh . || true)
        if [ -n "$what" ]; then
            if [ "$heads_up" = ask ] && [ -t 0 ]; then
                printf "The runner here has %s — 'just deploy --state' names them. Run on the deployed environment anyway? [Y/n] " "$what" >&2
                read -r reply
                case "$reply" in [nN]*) echo "Nothing run." >&2; exit 75 ;; esac
            else
                printf 'note: the runner here has %s; running the deployed environment.\n' "$what" >&2
            fi
        fi
    fi

    if deploying_elsewhere; then
        dir=$(deploy_dir_checked) || exit 1
        printf 'on %s:%s\n' "$RUNNER_DEPLOY_HOST" "$dir" >&2

        # A terminal decides, not the verb: `chat` and `shell` need one over
        # there, `status` read into a pipe must not have one, and `listen` is
        # both depending on who typed it. `ssh -t` without a local tty warns and
        # runs anyway, which is the shape of an answer nobody can parse.
        if [ -t 0 ]; then
            host_just "$verb" "$@"
        else
            host_just_read "$verb" "$@"
        fi
        rc=$?

        # Asked only when something failed, so the common path stays one round
        # trip: a host with no checkout yet answers every verb with a shell's
        # `cd` error, and that is not a sentence anybody acts on.
        if [ "$rc" -ne 0 ] && [ "$(host_checkout_state)" != ready ]; then
            echo "Nothing is deployed on $RUNNER_DEPLOY_HOST yet: 'just deploy' creates the checkout there." >&2
        fi
        exit "$rc"
    fi

    printf 'in %s\n' "$RUNNER_DEPLOYED" >&2

    cd "$RUNNER_DEPLOYED" || exit 1
    exec just "$verb" "$@"
}
