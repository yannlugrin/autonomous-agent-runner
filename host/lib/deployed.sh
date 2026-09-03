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

forward_to_deployed() {
    local verb="$1" heads_up what reply
    shift

    [ -e "$RUNNER_DEPLOYED/justfile" ] || {
        echo "Nothing is deployed yet: there is no checkout at $RUNNER_DEPLOYED, so there is no" >&2
        echo "agent to reach from here. 'just build', 'just verify', 'just deploy' makes one." >&2
        echo "To look inside a candidate instead, 'just shell --build'; 'just verify' proves it." >&2
        exit 1
    }

    # How loudly depends on what follows: the question is worth asking only
    # where answering `n` saves something. `listen` and `read` only look, so `n`
    # does nothing an interrupt would not; `status` reports the same fact three
    # lines later, in full. An unrecognised verb asks, because the recipe that
    # has not been thought about is the one to be careful with.
    # see docs/sessions.md#how-loudly-the-forwarder-speaks
    case "$verb" in
        listen|read) heads_up=tell ;;
        status)      heads_up=none ;;
        *)           heads_up=ask ;;
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

    printf 'in %s\n' "$RUNNER_DEPLOYED" >&2

    cd "$RUNNER_DEPLOYED" || exit 1
    exec just "$verb" "$@"
}
