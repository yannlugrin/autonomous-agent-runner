#!/usr/bin/env bash
# When the credentials the agent runs on expire.
#
# Runs on the host. `just credentials`, and once at the end of every session
# from run.sh and chat.sh — where a container start costs nothing anybody is
# waiting for, and where the reading is fresh for the next `just status`.
#
# Both dates are in the container and neither is on this host, so one
# `docker compose run` is the whole of it. The GitHub one is a response header
# on a call only that token can make. The Claude one is not readable from the
# token at all — a setup-token is opaque, `claude auth status` reports the login
# method and nothing more, and the usage endpoint answers it 403 — so its only
# source is the date somebody wrote in the vault row's note, which is why that
# note has a shape.  see docs/vault.md#when-a-credential-expires
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh

quiet="${quiet:-no}"

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    typed=()
    typed_flag --quiet "$quiet"
    forward_to_deployed credentials ${typed[@]+"${typed[@]}"}
fi

STORE="${RUNNER_CREDENTIALS:?not set — run this through 'just', which derives it from the cache directory}"

host/lib/docker-up.sh --image "${RUNNER_IMAGE:-$RUNNER_IMAGE_DEPLOYED}" || exit $?


# --- a reader that must reach the vault carries a home of its own ---
# RUNNER_TEST_ENV in host/verify/session.sh is the other array of this kind,
# and it cannot be reused here: RUNNER_TEST is what makes vault-env drop
# BWS_ACCESS_TOKEN, so anything carrying it can read no secret at all. What
# this shares with it is the half that matters — a HOME of its own, so nothing
# lands in the agent's volume — and it goes further by replacing the entrypoint
# outright, so no bootstrap runs and there is nothing to write there.
#
# BWS_ACCESS_TOKEN reaches this container from compose's own environment and
# not from vault-env, which is why the entrypoint can be skipped: vault-env
# decides the Claude login, and a reader does not need one.
# see docs/vault.md#a-reader-that-must-reach-the-vault

READER_HOME=/tmp/runner-credentials


# --- what the container is asked ---
# `key: value` lines, the same grammar host/session/status.py reads everything
# in. It reports and does not judge: no date is compared here, because the
# screen that shows this is where the thresholds live and a second copy of them
# would be the one that drifts.
#
# `vault gh-login` rather than `vault get --value` and a curl: the value then
# crosses neither a command line nor a stream, which is the reason that
# subcommand exists.  see docs/vault.md#gh-login-and-gh-secret-exist-because-the-spelled-out-form-is-refused

read_credentials() {
    docker compose run --rm -T \
        -e "HOME=$READER_HOME" \
        --entrypoint /bin/bash agent -c '
set -u
mkdir -p "$HOME" 2>/dev/null

rows=$(vault list 2>/dev/null)
if [ -z "$rows" ]; then
    printf "problem: %s\n" "the vault could not be read, so neither expiry is known — check BWS_ACCESS_TOKEN and BWS_SERVER_URL"
elif printf "%s\n" "$rows" | cut -f1 | grep -qx claude-oauth-token; then
    printf "claude_note: %s\n" "$(printf "%s\n" "$rows" | sed -n "s/^claude-oauth-token\t[a-z]*\t//p")"
else
    printf "problem: %s\n" "the vault has no row called claude-oauth-token — no session has a Claude login to run on"
fi

if vault gh-login github-token-own-account >/dev/null 2>&1; then
    answer=$(gh api -i user 2>/dev/null | tr -d "\r")
    if [ -n "$answer" ]; then
        printf "%s\n" "$answer" | sed -n "s/^[Gg]ithub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: /github_expiry: /p"
        printf "github_login: %s\n" "$(printf "%s\n" "$answer" | sed -n "/^{/,\$p" | jq -r ".login // empty" 2>/dev/null)"
    else
        printf "problem: %s\n" "GitHub took the token in github-token-own-account and then did not answer — check the network"
    fi
else
    printf "problem: %s\n" "gh refused the token in github-token-own-account, or there is no such row — the agent can neither read nor open an issue"
fi
' 2>/dev/null
}

reading=$(read_credentials)


# --- a reading that did not happen does not replace one that did ---
# Nothing came back means docker or compose failed, not that a credential
# changed. Overwriting the last good dates with an empty file would turn a
# five-second outage into a screen that has forgotten when anything expires;
# `status` prints how old a reading is, so the stale one still says so itself.

if [ -z "$reading" ]; then
    echo "The credentials could not be read: the container printed nothing. The last" >&2
    echo "reading is left as it was, and 'just status' says how old it is." >&2
    exit 1
fi

# Written beside and renamed over, so `status` never reads half a reading.
mkdir -p "$(dirname -- "$STORE")" || exit 1
if ! { printf 'read_at: %s\n' "$(date +%s)"; printf '%s\n' "$reading"; } > "$STORE.$$" \
   || ! mv -- "$STORE.$$" "$STORE"; then
    rm -f -- "$STORE.$$"
    echo "Could not write $STORE." >&2
    exit 1
fi

[ "$quiet" = yes ] && exit 0

printf '%s\n' "$reading"
echo
echo "Written to $STORE — 'just status' reads it and says when each one expires."
