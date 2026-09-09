# shellcheck shell=bash
# The machine the agent runs on, when that is not this one.
#
# Sourced by host/release/deploy.sh and host/release/ship.sh. RUNNER_DEPLOY_HOST
# empty means the agent runs here, which is what a clone gets and what every
# recipe did before this file existed: nothing below is reached.
#
# The target and the path are two values because the deploy needs each alone —
# `git push` wants target:path, `docker save | ssh` wants only the target — and
# a single string would be split back apart at three call sites.
# see docs/release.md#build-here-run-there

# --- deploying_elsewhere ---

deploying_elsewhere() { [ -n "${RUNNER_DEPLOY_HOST:-}" ]; }


# --- the path, checked once ---
# Interpolated into a remote shell command, so it is refused rather than quoted:
# a path needing quotes on the far side is a path this does not want to carry.

deploy_dir_checked() {
    case "${RUNNER_DEPLOY_DIR:-}" in
        "")  echo "RUNNER_DEPLOY_DIR is empty; it names the checkout on $RUNNER_DEPLOY_HOST." >&2
             return 1 ;;
        *[!A-Za-z0-9._/-]*)
             echo "RUNNER_DEPLOY_DIR holds a character this will not send through a shell: ${RUNNER_DEPLOY_DIR}" >&2
             return 1 ;;
    esac
    printf '%s\n' "$RUNNER_DEPLOY_DIR"
}


# --- host_ssh ---
# A short connect timeout, because a host that is not answering has to fail as
# that rather than hang a deploy that has already been agreed to. BatchMode so a
# missing key is an error and not a password prompt nobody is watching.

host_ssh() {
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$RUNNER_DEPLOY_HOST" "$@"
}


# --- host_checkout_state ---
# One round trip, one word. `absent` there is nothing; `occupied` there is
# something that is not a git repository, which is the case this must never
# guess at; `ready` is what the deploy wants.

host_checkout_state() {
    local dir; dir=$(deploy_dir_checked) || return 1
    host_ssh "sh -c '
        case \"$dir\" in /*) d=\"$dir\" ;; *) d=\"\$HOME/$dir\" ;; esac
        [ -e \"\$d\" ] || { echo absent; exit 0; }
        [ -d \"\$d/.git\" ] && echo ready || echo occupied'" 2>/dev/null
}


# --- host_checkout_create ---
# A plain repository, and deliberately no `receive.denyCurrentBranch` setting of
# any kind. `deployed` is never the branch that checkout has current — `land`
# leaves its HEAD detached at the commit — so a push of that ref is accepted and
# moves nothing but the ref. The working tree moves later, inside the pause that
# `land` holds the schedule with, which is what separates a branch arriving from
# a version going live. `updateInstead` would join the two back together.
# see docs/release.md#the-tag-flip-is-the-deploy

host_checkout_create() {
    local dir; dir=$(deploy_dir_checked) || return 1
    host_ssh "sh -c '
        case \"$dir\" in /*) d=\"$dir\" ;; *) d=\"\$HOME/$dir\" ;; esac
        mkdir -p \"\$d\" && git -C \"\$d\" init -q'"
}


# --- host_checkout_path ---
# The checkout's absolute path over there, resolved by that account's own shell.
# It is what RUNNER_DEPLOYED has to hold in the `.env` that reaches it: the
# justfile decides RUNNER_IS_DEPLOYED by comparing its own directory to that
# value, and a relative one is resolved from the project root, so it can never
# equal it. `no` there means every live recipe forwards to a directory that does
# not exist. see docs/release.md#the-runtime-host-is-its-own-deployed-checkout

host_checkout_path() {
    local dir; dir=$(deploy_dir_checked) || return 1
    host_ssh "sh -c '
        case \"$dir\" in /*) echo \"$dir\" ;; *) echo \"\$HOME/$dir\" ;; esac'" 2>/dev/null | tr -d '\r'
}


# --- host_checkout_populate ---
# After the first push, and only then. The repository was made by `git init`, so
# its HEAD is unborn and it holds no working tree — no justfile, and therefore no
# way to run `land`, which is the thing that would check one out. Nothing is live
# there yet, so populating it costs nothing and protects nothing to skip. Every
# later deploy leaves the tree alone: `land` moves it inside the pause it holds
# the schedule with. see docs/release.md#the-first-deploy-has-no-working-tree

host_checkout_populate() {
    local dir; dir=$(deploy_dir_checked) || return 1
    host_ssh "sh -c '
        case \"$dir\" in /*) d=\"$dir\" ;; *) d=\"\$HOME/$dir\" ;; esac
        git -C \"\$d\" rev-parse --verify --quiet HEAD >/dev/null 2>&1 && exit 0
        git -C \"\$d\" checkout --detach --quiet refs/heads/deployed'"
}


# --- host_remote_url ---
# What the git remote named `host` must point at. Named `host` and not `deploy`:
# that is one letter from the `deployed` branch and the `deployed/` worktree,
# and all three appear in git commands in the same file.

# shellcheck disable=SC2034  # read by deploy.sh and ship.sh, which source this
HOST_REMOTE=host

host_remote_url() {
    local dir; dir=$(deploy_dir_checked) || return 1
    printf '%s:%s\n' "$RUNNER_DEPLOY_HOST" "$dir"
}


# --- host_quote ---
# argv, as one string a remote shell takes apart the way it was typed here.
# ssh concatenates what it is given and the far side re-splits it, so an
# unquoted `$*` turns `collect --approve <hash> <why with spaces>` into five
# arguments. Single quotes and the POSIX '\'' escape rather than bash's
# printf %q: what runs over there is the login shell, which is not always bash.

host_quote() {
    local a out=""
    for a in "$@"; do
        out="$out '${a//\'/\'\\\'\'}'"
    done
    printf '%s' "$out"
}


# --- host_just_read ---
# A recipe over there whose answer is read rather than watched: no tty, so the
# output is the output. `deploy --state` is the caller that matters, because
# `just status` asks it on every page it draws.
#
# RUNNER_DEPLOY_HOST is emptied for both calls: that host's own .env names itself,
# and without this the deploy would forward to the machine it is already on.
# Measured on just 1.58.0: an environment assignment beats `set dotenv-load`,
# and an empty one beats it too. see docs/release.md#the-environment-beats-dotenv

host_just_read() {
    local dir; dir=$(deploy_dir_checked) || return 1
    host_ssh "cd '$dir' && RUNNER_DEPLOY_HOST= just$(host_quote "$@")"
}


# --- host_just ---
# One of this repository's own recipes, over there, on a terminal. A tty because
# the recipe that runs this way is `deploy`, and its question — the one moment a
# change reaches the agent — belongs on the far side, where the deployed
# checkout and the live image are.

host_just() {
    local dir; dir=$(deploy_dir_checked) || return 1
    ssh -t -o ConnectTimeout=10 "$RUNNER_DEPLOY_HOST" \
        "cd '$dir' && RUNNER_DEPLOY_HOST= ${RUNNER_SHIPPED_ID:+RUNNER_SHIPPED_ID=$RUNNER_SHIPPED_ID }just$(host_quote "$@")"
}
