#!/usr/bin/env bash
# Put the credentials that live in the environment into it, from the vault,
# then exec what was asked for.
#
# Its own file rather than four lines at the end of entrypoint.sh: bootstrap
# has side effects and a credential does not, so the budget gate can exec
# through here without cloning a repository first. Both the session and
# anything started with --entrypoint come this way, so there is one place that
# knows where this container's Claude login comes from and a gate and a
# session cannot read different credentials.
# see docs/vault.md#where-the-containers-claude-login-comes-from
#
# The value never touches a file on the way in: `vault get --value` prints it
# and this captures it. The path form would read a file in the volume, which
# the agent can write, and this is baked into the image precisely so that what
# it reads is not something the agent chooses.
#
# It is not a secret from the session, and nothing here pretends otherwise:
# the container is unprivileged with no-new-privileges, so a variable in this
# process is readable by everything downstream of it. That is the same
# admission vault.sh makes about BWS_ACCESS_TOKEN.
# see docs/vault.md#what-the-wrapper-does-not-do

set -uo pipefail

# The name the long-lived Claude login is kept under in the vault. Hardcoded,
# for the reason the ssh key's name is: a name that can be changed in .env is
# a name that can silently come to point at nothing, and the symptom would be
# a container quietly running on the credential this exists to replace.
VAULT_CLAUDE_TOKEN=claude-oauth-token

# Already set wins, and nothing here overwrites it. That is what lets a probe
# pass a deliberate value — `just verify` does — and what keeps this from
# undoing an override someone chose on purpose.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${RUNNER_TEST:-}" ] \
   && [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
    # Silent on failure, deliberately. No such secret, an expired access
    # token, a network that is down — all of them mean "no token from the
    # vault", and the container falls back to the credentials file in its
    # volume. A vault that cannot be reached must not be a container that
    # cannot start; the budget gate is what says whether the credential that
    # remains is usable, and it says it loudly.
    value=$(vault get "$VAULT_CLAUDE_TOKEN" --value 2>/dev/null)
    if [ -n "$value" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$value"
    fi
    unset value
fi

# --- a verify probe carries no key to the vault ---
# A probe runs with a HOME of its own so it writes nothing in the agent's
# volume, and that home has no credentials file — so it would have to reach the
# vault for a login, and would then be a session holding the key to every
# secret the vault has. The guard denies `bws` on argv, which covers the
# spelling and not the value: anything that prints an environment puts the
# token where it was printed.
#
# So a probe is given the login the agent already has, read out of the volume
# it may read and never write, and the access token is dropped before the
# session starts. One secret it needs instead of the one that opens all of
# them.
#
# Handed over as CLAUDE_CODE_OAUTH_TOKEN and not as a copy of the file, because
# Claude Code does not behave the same way on the two paths: measured
# 2026-09-04 on 2.1.259, a session authenticated from a credentials file logs
# nothing about `localSettings` where one authenticated from the environment
# logs six lines, and the `project rules` probe reads exactly that to prove a
# rule in the checkout was not loaded. Authenticating the way a real session
# does is also the only way a probe measures what a real session would.
# see docs/verify.md#a-probe-carries-no-key-to-the-vault
#
# Here rather than in the caller because every session path arrives here,
# entrypoint.sh included — one place rather than one per probe — and because
# this is the file that decides what a container's login is.
if [ -n "${RUNNER_TEST:-}" ]; then
    _agent_login="/home/$(id -un)/.claude/.credentials.json"
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$_agent_login" ]; then
        value=$(jq -r '.claudeAiOauth.accessToken // empty' "$_agent_login" 2>/dev/null)
        if [ -n "$value" ]; then
            export CLAUDE_CODE_OAUTH_TOKEN="$value"
        fi
        unset value
    fi
    unset _agent_login
    unset BWS_ACCESS_TOKEN
fi

exec "$@"
