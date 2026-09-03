#!/usr/bin/env bash
# Bring the agent's home into the state a session needs, then hand over.
#
# Everything here is idempotent and runs on every start. The home is a named
# volume, seeded from the image only when it is first created, so anything
# written under it at build time freezes there — configuration that must be able
# to change lives here rather than in the Dockerfile.
# see docs/image.md#the-volume-is-seeded-once
#
# When something is missing that only a human can supply, this reports and stops
# rather than dropping into a session that cannot commit or push. Exit 78 is
# sysexits' EX_CONFIG: an unattended run that did not happen must be
# distinguishable from one that did.

set -euo pipefail

# The agent's own namespace: the variable names are built here rather than
# written out, and the account IS the agent by construction, so `id -un` is the
# authority. Two `tr`s and not one — mixing a character class with a literal in
# one set is not portable, and a shell name cannot hold a dash.
# see docs/image.md#the-agents-own-namespace
# shellcheck disable=SC2018,SC2019 # usernames are ASCII-only here
AGENT_PREFIX="$(id -un | tr 'a-z' 'A-Z' | tr '-' '_')"

# The value of one of them, or empty. Indirect expansion, which is why every
# script here is bash and not sh.
agent_var() { local _n="${AGENT_PREFIX}_$1"; printf '%s' "${!_n-}"; }

REPO_DIR="$(agent_var REPO_DIR)"
REPO_DIR="${REPO_DIR:-$HOME/$(id -un)}"
GIT_NAME="$(agent_var GIT_NAME)"
GIT_EMAIL="$(agent_var GIT_EMAIL)"
REPO="$(agent_var REPO)"

KEY="$HOME/.ssh/id_ed25519"

# The name the ssh key is kept under in the vault. Hardcoded, not read from the
# environment: a name that can be changed in .env is a name that can silently
# come to point at nothing, and the failure would be a container that generated
# a fresh key and waited for a human. Absent from the vault is not an error.
# see docs/image.md#the-ssh-key-and-restoring-it-from-the-vault
VAULT_SSH_KEY=github-ssh-key

notes=()
note() { notes+=("$1"); }

# The Claude Code pin arrives as AGENT_CLAUDE_VERSION because a Dockerfile ENV
# name is literal and cannot be computed. Moved into the agent's namespace so a
# session sees one spelling rather than two. The verify probes read the baked
# name through `--entrypoint sh`, which does not run this file.
export "${AGENT_PREFIX}_CLAUDE_VERSION=${AGENT_CLAUDE_VERSION:-}"
unset AGENT_CLAUDE_VERSION

# The commit that built this image, by the same route. Empty stays empty —
# claude-session.py is where that becomes words.
# see docs/image.md#what-the-image-was-built-from
export "${AGENT_PREFIX}_RUNNER_COMMIT=${AGENT_RUNNER_COMMIT:-}"
export "${AGENT_PREFIX}_RUNNER_COMMITTED_AT=${AGENT_RUNNER_COMMITTED_AT:-}"
unset AGENT_RUNNER_COMMIT AGENT_RUNNER_COMMITTED_AT

# --- git ----------------------------------------------------------------

git config --global init.defaultBranch main
git config --global push.default simple

if [ -n "$GIT_NAME" ]; then
    git config --global user.name "$GIT_NAME"
else
    note "${AGENT_PREFIX}_GIT_NAME is unset. git refuses to commit without it."
fi

if [ -n "$GIT_EMAIL" ]; then
    git config --global user.email "$GIT_EMAIL"
else
    note "${AGENT_PREFIX}_GIT_EMAIL is unset. git refuses to commit without it. Use the agent's account users.noreply address, copied from its email settings (see README: it carries a numeric id and cannot be guessed)."
fi

# --- ssh ----------------------------------------------------------------

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# The vault first, generation only as the fallback: a generated key is one
# GitHub has never seen, so it cannot clone, and on the morning the volume is
# gone that is the whole of the outage.
#
# Only when there is no key: a restore on every start would replace a working
# identity with whatever the vault happens to hold, and the vault is the copy
# most likely to be out of date.
# see docs/image.md#the-ssh-key-and-restoring-it-from-the-vault
if [ ! -f "$KEY" ]; then
    restored=false
    if [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
        # Output held back unless something was restored: "no secret named
        # 'github-ssh-key'" is correct, and is also a scary line to print at a
        # first bootstrap where the vault has legitimately never held one.
        #
        # `&& rc=0 || rc=$?` and not a bare assignment: `set -e` is on, and a
        # bare `out=$(cmd)` whose command exits non-zero takes the whole
        # entrypoint down with it, silently, before the report that would have
        # said why. see docs/image.md#set--e-at-the-hand-over
        out=$(vault ssh-restore "$VAULT_SSH_KEY" 2>&1) && rc=0 || rc=$?
        case $rc in
            0)
                printf '%s\n' "$out"
                restored=true
                ;;
            # Restored, and GitHub answered that it does not know this key.
            # Kept, not replaced: generating over it would swap one identity the
            # account does not know for another and lose the fingerprint that
            # says which. Reported as a setup problem instead, with the public
            # half printed — which is the whole of the fix.
            3)
                printf '%s\n' "$out"
                restored=true
                note "The SSH key was restored from the vault as '$VAULT_SSH_KEY', and GitHub refused it: the public half printed above is not on the agent's account. Nothing was generated and the restored key is still in place, so adding that public half to the account is all this needs. If the account's key is the right one and the vault's copy is stale, the fix is the other direction — store the current private key under '$VAULT_SSH_KEY'."
                ;;
            # Anything else restored nothing: no such secret, an empty value,
            # or a value ssh-keygen cannot read — the key below is generated.
            *) ;;
        esac
    fi

    if [ "$restored" = false ]; then
        ssh-keygen -t ed25519 -N "" -C "${GIT_EMAIL:-${AGENT_NAME:-agent}}" -f "$KEY" >/dev/null
        note "A new SSH key was generated. Add its public half, printed above, to the agent's GitHub account before anything can be cloned or pushed. To make the next empty home recover on its own instead, store the PRIVATE half in the vault as '$VAULT_SSH_KEY' — the operator's to do, in the read-only project."
    fi
fi

# --- usage, for information only ----------------------------------------
#
# Whether the HOST would refuse a session that is over budget, settled to
# exactly `true` or `false` before anything reads it — the same one-line
# comparison host/lib/session-env.sh makes. `false` is the answer for unset,
# empty and anything unrecognised: a session must never be handed a value it has
# to interpret. It stays `true` in a shell where a session is then run by hand,
# which is correct rather than a leak — the guard is armed and this session went
# around it. see docs/budget.md
if [ "${ACCOUNT_BUDGET_GUARD:-}" = true ]; then
    export ACCOUNT_BUDGET_GUARD=true
else
    export ACCOUNT_BUDGET_GUARD=false
fi

# Not a gate, and the flag says so: --advisory exits 0 whatever it finds, and
# prints nothing rather than "unknown" when it cannot tell. Skipped when the
# host already answered, which it does whether its guard is armed or not — an
# absent ACCOUNT_USAGE_SESSION means the host could not read, and this is the
# second chance: a login of its own here is the case where the numbers are
# about the agent's account rather than somebody else's.
#
# Its stderr is let through, and the missing 2>/dev/null is the point: the line
# the tool writes when it cannot tell is the only account of WHY a session has
# no numbers. `|| true` stays because a missing or broken tool must not stop a
# session that was never being gated.
#
# A function, called before both hand-overs, because the bypass execs early and
# would otherwise skip it. see docs/budget.md
usage_into_env() {
    [ -z "${ACCOUNT_USAGE_SESSION:-}" ] || return 0
    while IFS= read -r usage_line; do
        case "$usage_line" in
            ACCOUNT_USAGE_*|ACCOUNT_BUDGET_*) export "${usage_line%%=*}=${usage_line#*=}" ;;
        esac
    done <<USAGE
$(/usr/local/bin/claude-usage --env --advisory || true)
USAGE
    unset usage_line
}

# --- report -------------------------------------------------------------

# Said on every start beside the gh account, because a container whose Claude
# login is gone looks exactly like a healthy one until the first unattended
# session stands down — and the budget gate, which is what stands it down, reads
# the same credential this reports.
#
# A function and not a substitution inside the heredoc: `claude auth status`
# exits non-zero when it is logged out, `set -o pipefail` fails the whole
# pipeline with it, and the `||` fallback then prints its answer on a line of
# its own under the correct one.
# see docs/image.md#the-claude-login-is-reported-on-every-start
# Reported before vault-env runs, so a token the vault will supply is not
# visible here yet: an empty volume is the normal state when the vault holds
# claude-oauth-token, and the line says which route is about to apply.
claude_login() {
    local said absent
    if [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
        absent="(none in the volume — vault-env fetches claude-oauth-token from the vault at start)"
    else
        absent="(not logged in — store a setup-token as claude-oauth-token in the vault, or run: claude auth login)"
    fi
    said=$(claude auth status 2>/dev/null) || true
    printf '%s' "$said" \
        | jq -r --arg absent "$absent" 'if .loggedIn then "\(.authMethod) (\(.subscriptionType // "?"))" else $absent end' 2>/dev/null \
        || printf '(could not ask)'
}

report() {
    cat <<REPORT

================================================================
  ${AGENT_NAME:-agent} — environment
================================================================

  git user.name    ${GIT_NAME:-(unset)}
  git user.email   ${GIT_EMAIL:-(unset)}
  repository       ${REPO:-(unset)}
  checkout         $REPO_DIR
  key fingerprint  $(ssh-keygen -lf "$KEY.pub" 2>/dev/null || echo "(none)")
  gh account       $(gh api user --jq .login 2>/dev/null || echo "(not authenticated — run: vault gh-login github-token-own-account)")
  claude login     $(claude_login)

  SSH public key — add this to ${AGENT_NAME:-agent}'s GitHub account:

$(cat "$KEY.pub" 2>/dev/null || echo "  (none)")

================================================================
REPORT
}

# The testing bypass sits ahead of the gate, not behind it: its whole purpose is
# exercising the image without a repository or a key GitHub knows about, and a
# gate that still stopped for the key it told you to generate would defeat that
# on the very first run. Nothing blocks under it — but it announces itself on
# every start, because a quiet bypass is one that gets left in .env.
# see docs/image.md#the-testing-bypass-announces-itself
if [ -n "${AGENT_SKIP_CLONE:-}" ]; then
    report
    cat <<'BANNER'
  ┌──────────────────────────────────────────────────────────────┐
  │  AGENT_SKIP_CLONE is set. Nothing is checked, nothing is     │
  │  cloned, and nothing blocks. This is a TESTING BYPASS —      │
  │  unset it in .env for a real session.                        │
  └──────────────────────────────────────────────────────────────┘

BANNER
    if [ ${#notes[@]} -gt 0 ]; then
        echo "  Reported but not enforced:"
        for n in "${notes[@]}"; do printf '    - %s\n' "$n"; done
        echo
    fi
    # The bypass ends here — exec replaces this process, so nothing below the
    # `fi` runs on this path. No `exit` follows it: execfail is off, so a failed
    # exec leaves the shell with 127 rather than falling through.
    # see docs/image.md#set--e-at-the-hand-over
    #
    # Through vault-env on this path too: the bypass skips the repository, not
    # the credentials, and one that quietly changed which credential is in force
    # would make every test under it a test of something else.
    usage_into_env
    exec /usr/local/bin/vault-env "$@"
fi

if [ ${#notes[@]} -gt 0 ]; then
    report
    echo
    echo "  Setup is not complete. Verify the values above, then:"
    echo
    for n in "${notes[@]}"; do
        printf '    - %s\n' "$n"
    done
    echo
    echo "  Nothing was started. Fix these and run again."
    echo
    exit 78
fi

# --- repository ---------------------------------------------------------

if [ ! -e "$REPO_DIR/.git" ]; then
    if [ -z "$REPO" ]; then
        report
        echo "  ${AGENT_PREFIX}_REPO is unset, so there is nothing to clone."
        echo "  Nothing was started."
        echo
        exit 78
    fi

    # A directory that exists, holds something, and is not a checkout is a state
    # a human must look at — git's own message for it says nothing about what to
    # do. `docker run -w` creates a missing working directory **as root** before
    # this script runs, and the clone then fails with a permission error that
    # the causes listed further down do not explain.
    # see docs/image.md#docker-run--w-creates-the-path-as-root
    if [ -d "$REPO_DIR" ] && [ ! -w "$REPO_DIR" ]; then
        report
        echo "  $REPO_DIR exists and is not writable by $(id -un)."
        echo "  A working directory passed with -w is created by Docker as"
        echo "  root before this script runs. Remove it from the volume and"
        echo "  let the clone create it:"
        echo
        echo "      docker run --rm -v <volume>:/vol alpine rm -rf /vol/$(basename "$REPO_DIR")"
        echo
        exit 78
    fi

    if [ -d "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
        report
        echo "  $REPO_DIR exists, is not empty, and is not a git checkout:"
        # shellcheck disable=SC2012 # human-readable listing, not parsed
        ls -A "$REPO_DIR" | sed 's/^/      /'
        echo
        echo "  Nothing was started. Inspect it, then empty or remove it —"
        echo "  the clone creates the directory itself."
        echo
        exit 78
    fi

    echo "No checkout at $REPO_DIR — cloning $REPO"
    if ! git clone "$REPO" "$REPO_DIR"; then
        report
        cat <<'MSG'
  The clone failed. The usual causes, in order of likelihood:

    - the public key above is not yet on the agent's GitHub account
    - the account is not a collaborator on that repository
    - ${AGENT_PREFIX}_REPO is wrong

  Nothing was started.

MSG
        exit 78
    fi
    echo "Cloned. This is a fresh checkout — there is no local state that"
    echo "the remote does not have."
fi

# --- claude --------------------------------------------------------------
#
# Pre-accept the workspace trust dialog for the checkout, so an interactive
# session starts in it rather than at a prompt. `just run` passes -p, where the
# dialog is skipped outright, so this is for `just chat`. Trust is not a
# permission: it gates that one dialog and nothing else, while the deny list and
# defaultMode come from /etc/claude-code/managed-settings.json.
#
# The care below is because this file also holds the Claude Code login: it is
# rewritten through a temporary file and moved into place, and a file that does
# not parse is left untouched rather than replaced — a clobbered .claude.json
# logs the agent out, and the next unattended session would fail with nothing
# pointing here. see docs/image.md#workspace-trust-is-pre-accepted-carefully
CLAUDE_JSON="$HOME/.claude.json"
[ -e "$CLAUDE_JSON" ] || { printf '{}\n' > "$CLAUDE_JSON"; chmod 600 "$CLAUDE_JSON"; }

if ! jq -e --arg d "$REPO_DIR" \
        '.projects[$d].hasTrustDialogAccepted == true' "$CLAUDE_JSON" >/dev/null 2>&1; then
    tmp="$(mktemp "$CLAUDE_JSON.XXXXXX")"
    if jq --arg d "$REPO_DIR" \
            '.projects[$d].hasTrustDialogAccepted = true' "$CLAUDE_JSON" > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp"
        mv "$tmp" "$CLAUDE_JSON"
        echo "claude: workspace trust pre-accepted for $REPO_DIR"
    else
        rm -f "$tmp"
        echo "claude: $CLAUDE_JSON is not readable JSON — trust left alone." >&2
    fi
fi

# --- the first-run wizard, marked done ---
# An interactive session on a fresh volume opens Claude Code's onboarding —
# theme, then a login step that asks even when the vault token is in the
# environment — and `just chat` is the first session a newcomer runs. -p
# sessions never see it, which is why no probe does. The theme is managed
# settings' to decide; marking onboarding complete skips the wizard whole.
# see docs/image.md#workspace-trust-is-pre-accepted-carefully

if ! jq -e '.hasCompletedOnboarding == true' "$CLAUDE_JSON" >/dev/null 2>&1; then
    tmp="$(mktemp "$CLAUDE_JSON.XXXXXX")"
    if jq '.hasCompletedOnboarding = true' "$CLAUDE_JSON" > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp"
        mv "$tmp" "$CLAUDE_JSON"
        echo "claude: first-run wizard marked complete"
    else
        rm -f "$tmp"
        echo "claude: $CLAUDE_JSON is not readable JSON — onboarding left alone." >&2
    fi
fi

# Through vault-env, which is where the Claude login is decided — the same
# script the budget gate is started with, so the two cannot end up on different
# credentials. Bootstrap is this file's job; the credential is not, and fusing
# them is what forced the gate to bypass the whole thing. see docs/vault.md
usage_into_env
exec /usr/local/bin/vault-env "$@"
