#!/usr/bin/env bash
# The only route to the agent's vault, and the reason rule 10 covers it.
#
# Baked into the image like push-on-exit.sh and bash-guard.py beside it: it is
# the mechanism, and a mechanism the agent can edit is a mechanism it does not
# have. `bws` itself is denied, by the guard and by the managed deny list.
#
# Why a wrapper at all: bash-guard.py stops a secret entering history by
# comparing what a commit would carry against the live contents of credential
# files, and a secret fetched into a variable is in no file. So every fetch and
# every store lands in $CACHE first, where the guard reads it alongside the ssh
# key and the Claude login. A secret in history is the one mistake that cannot
# be cleaned up here: the cleanup is a rewrite, and a rewrite does not reach
# the forge's own copies.
#
# It is not a wall, and nobody should be told it is one. BWS_ACCESS_TOKEN is in
# this process's environment, and a session that hand-rolls the Bitwarden API
# with curl bypasses this file and everything above it; the deny turns that
# from the obvious thing to type into a deliberate detour.
# see docs/vault.md#what-the-wrapper-does-not-do
#
# `get` prints the path and never the value, and `put` reads the value from
# stdin and refuses it as an argument: the transcript is archived, and a
# command line is recorded in it exactly as typed.
# see docs/vault.md#get-prints-the-path-and-was-read-as-printing-the-secret

set -uo pipefail

# Not configurable: bash-guard.py and collect.sh each hardcode this path — the
# guard to learn what a secret looks like for rule 10, collect to know what to
# redact. A variable that moved only this one would disarm both, in silence.
CACHE="$HOME/.cache/vault"
BWS="${BWS_PATH:-/usr/local/bin/bws}"
# The real writable project, a constant, and not the same thing as "the
# project this invocation writes to" — --test moves the latter. `clear` builds
# its keep-set from this one and READABLE_PROJECT, so what it spares cannot
# depend on which mode it ran in.
ACQUIRED_PROJECT="${BWS_VAULT_PROJECT:-$(id -un)-acquired}"
WRITABLE_PROJECT="$ACQUIRED_PROJECT"

# The other project holding real secrets. Named rather than inferred, because
# `clear` decides what to delete from the cache by asking whether a key is in
# one of these two, and an inferred list that came back short would take the
# guard's rule 10 coverage with it.
READABLE_PROJECT="${BWS_VAULT_READABLE_PROJECT:-$(id -un)-provisioned}"

# The scratch project. Its secrets are invisible unless --test is given, and
# then they are the only ones visible: a test run must not read a real
# credential by accident, and a real run must not pick up a fixture someone
# left behind. One flag does both because they are the same rule.
TEST_PROJECT="${BWS_VAULT_TEST_PROJECT:-$(id -un)-test}"

# Stripped from anywhere in the arguments before the subcommands see them.
# Every branch counts its arguments exactly — `[ $# -eq 2 ] || usage` — so a
# flag left in place would have to be spelled into each, and the one that got
# forgotten would be the one that silently read the real vault.
TEST_MODE=false
_args=()
for _a in "$@"; do
    case "$_a" in
        --test) TEST_MODE=true ;;
        *)      _args+=("$_a") ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}

# In test mode the scratch project is also the only place `put` may write.
# Otherwise `vault put x --test` would store into the acquired project, which
# is the opposite of what the flag is for.
if [ "$TEST_MODE" = true ]; then
    WRITABLE_PROJECT="$TEST_PROJECT"
fi

# Where a fetched or stored value is written. The cache is keyed by name, so
# fixtures need a directory of their own or a fixture and a real secret of the
# same name share a file — the mix-up --test exists to prevent, arriving by the
# back door. The subdirectory also keeps fixtures out of rule 10: the guard
# reads the cache root and skips anything that is not a file.
# see docs/vault.md#fixtures-have-their-own-cache-directory
CACHE_DIR="$CACHE"
[ "$TEST_MODE" = false ] || CACHE_DIR="$CACHE/test"

die() { printf 'vault: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
Usage:
  vault list                 every secret you can read, one per line:
                             name, rw|ro, note. `ro` is the operator's to change —
                             ask them rather than working around it.
  vault get <key>            fetch it, cache it, print the PATH to it
  vault get <key> --value    fetch it and print the VALUE — this reaches the
                             transcript, which is archived; prefer the path
  vault put <key> --note "what it is for"
                             store or replace a secret, VALUE READ FROM STDIN.
                             Replacing works only in the writable project, and
                             is final: this plan keeps no history.
                             The note is required: a key alone is a guess,
                             and the guess is made months later by someone
                             who no longer remembers.
                             What you store is cached locally too, so `path`
                             never names a stale value.
  vault gh-login <key>       authenticate the gh CLI with that secret. The
                             value goes from the vault into gh and touches
                             neither a command line nor this transcript.
  vault gh-secret <key> <NAME> [<owner/repo>]
                             copy that secret into a GitHub Actions
                             repository secret called NAME, so a workflow can
                             use it. The value goes from the vault into
                             GitHub and touches neither a command line nor
                             this transcript. Without owner/repo it goes to
                             the repository of the current directory.
                             --test fetches the fixture and sets NOTHING.
  vault ssh-restore <key>    install that secret as ~/.ssh/id_ed25519 and
                             prove it against GitHub. The public half is
                             derived, never stored. This is what the
                             entrypoint calls before it would generate a
                             key nobody has ever seen.
                             Exit 0 restored it, 3 restored it and GitHub
                             refused it, 1 restored nothing.
  vault path <key>           where a fetched secret is cached, without fetching
  vault clear [--dry-run]    remove cached files for keys that are no longer in
                             the vault, or never were. Touches ~/.cache only —
                             nothing in the vault is deleted, and everything it
                             removes can be fetched again. --dry-run lists them
                             and changes nothing.

Add --test to any command above to work in the scratch project instead: its
secrets become the only ones visible, and the real ones cannot be read or
listed at all. Without it they are invisible, so a fixture cannot be picked up
by mistake. `clear` has no --test; it already removes fixtures, because they
are in neither real project.

Reading covers every project the machine account is assigned. Writing reaches
only the writable one, so a secret the operator provisioned cannot be overwritten from
in here — that is deliberate, and asking them is the way to change one.
USAGE
    exit 2
}

[ -x "$BWS" ] || die "no bws at $BWS. The image did not build what it claims to."
[ -n "${BWS_ACCESS_TOKEN:-}" ] || die \
    "BWS_ACCESS_TOKEN is unset. The vault is not configured for this container;
this is the operator's to set in .env, and it reaches here through compose."

# Every secret the token can read, in every project, unfiltered — values
# included, which is why nothing prints this raw. Only the scope resolver and
# `clear` use it; everything else goes through secrets_json, the filtered view.
secrets_raw() {
    "$BWS" secret list --output json 2>/dev/null \
        || die "bws could not list secrets. The access token may be revoked or expired."
}

# The project ids a command may see, as a JSON array: everything except the
# scratch project, or the scratch project alone under --test. Resolved by name
# and never by id, so a project recreated under the same name keeps working and
# a renamed one stops rather than quietly widening.
#
# An empty answer in test mode means the scratch project does not exist, and
# saying so beats `vault list --test` printing nothing and reading as "no
# secrets in there yet".
scope_ids() {
    ids=$(projects_json | jq -c --arg t "$TEST_PROJECT" --argjson test "$TEST_MODE" '
        [ .[] | select(if $test then .name == $t else .name != $t end) | .id ]') || exit $?
    if [ "$TEST_MODE" = true ] && [ "$ids" = "[]" ]; then
        die "there is no project called '$TEST_PROJECT', so --test can see nothing.
It is the operator's to create; ask them rather than storing fixtures beside the real
secrets."
    fi
    printf '%s' "$ids"
}

# The filter lives here, at the single point every command reads secrets
# through, and not in the branches: a branch that forgot it would read the real
# vault while saying --test, and it would look exactly like working.
#
# A secret with no projectId falls out rather than in — `index` on a null
# yields null — which is the safe direction in both modes.
secrets_json() {
    secrets_raw | jq -c --argjson ids "$SCOPE_IDS" \
        '[ .[] | select(.projectId as $p | $ids | index($p) != null) ]'
}

# id -> name for every project the machine account can see. `list` shows the
# name rather than the UUID: the name says whether a secret is one the operator
# provisioned or one the agent stored, and therefore whether it can be written.
projects_json() {
    "$BWS" project list --output json 2>/dev/null \
        || die "bws could not list projects. The access token may be revoked or expired."
}

# Run bws, keep what it said, and take the value back out of it. What bws
# objected to is the only reliable diagnosis, but passing it through verbatim
# is not safe: a clap parse error quotes the argument it rejected, so a failed
# store would print the private key into the transcript in the act of reporting
# itself. Redacting by name is possible only because the value is in a variable
# here.
# see docs/vault.md#a-guess-printed-as-a-diagnosis
#
# `2>&1 >/dev/null` in that order is what captures stderr: it points stderr at
# the current stdout — the capture — and only then sends stdout away.
BWS_SAID=""
bws_said() {
    BWS_SAID=$("$@" 2>&1 >/dev/null)
    status=$?
    BWS_SAID=${BWS_SAID//"$value"/[the value, redacted]}
    # Bounded, because bws can be voluble and the point is the first thing it
    # objected to. An empty answer says so rather than printing nothing.
    BWS_SAID=$(printf '%s\n' "$BWS_SAID" | head -5)
    [ -n "$BWS_SAID" ] || BWS_SAID="(bws said nothing)"
    return $status
}

sanitise() {
    # A key is a file name here. A key containing a slash or a leading dot
    # would write outside the cache or hide there; refuse rather than mangle,
    # because a silently renamed key is one that is never found again.
    case "$1" in
        ''|.*|*/*|*..*) die "refusing '$1' as a key: no slashes, no leading dot, no '..'" ;;
    esac
}

# The one place a value is written to disk, so `put` and `fetch` cannot cache
# it two different ways: a route that skipped it would be a secret rule 10 does
# not cover, which is the entire reason this wrapper exists.
#
# 0700 on the directory and 0600 on the file, set before the value is written —
# a chmod that follows the write leaves a window. Written to a temporary name
# in the same directory and renamed, so a reader never sees half a value.
cache_write() {
    mkdir -p "$CACHE_DIR" || die "could not create $CACHE_DIR"
    chmod 700 "$CACHE" 2>/dev/null
    chmod 700 "$CACHE_DIR" 2>/dev/null
    tmp="$CACHE_DIR/.$1.$$"
    ( umask 077; printf '%s' "$2" > "$tmp" ) || die "could not write the cache file."
    mv -f "$tmp" "$CACHE_DIR/$1" || die "could not place the cache file."
}

fetch() {
    # Counted before it is read, because a key is not unique: Bitwarden lets
    # two secrets share a name, and `first` over an unordered list then picks
    # one silently — it works until the day it returns the other, and nothing
    # in between says which it gave you.
    # see docs/vault.md#a-key-is-not-unique
    matches=$(secrets_json | jq --arg k "$1" '[.[] | select(.key == $k)] | length') || exit $?
    [ "$matches" -le 1 ] || die "there are $matches secrets called '$1' where this command can see
them, and no way to tell which one you meant. Nothing was read. 'vault list'
shows them with their notes; one of them has to go, and that is the operator's to do."

    VALUE=$(secrets_json | jq -r --arg k "$1" '[.[] | select(.key == $k)] | first | .value // empty') || exit $?
    [ -n "$VALUE" ] || die "no secret named '$1'. 'vault list' shows what there is."

    cache_write "$1" "$VALUE"
}

# Resolved once, in the parent shell, and only for the subcommands that reach
# the vault: `path` answers from the filesystem and must not cost a network
# round trip, which matters because it is on the entrypoint's path.
SCOPE_IDS='[]'
case "${1:-}" in
    list|get|gh-login|gh-secret|ssh-restore|put) SCOPE_IDS=$(scope_ids) || exit $? ;;
esac

case "${1:-}" in
list)
    [ $# -eq 1 ] || usage
    # Names, projects and notes — never values: a `vault list` that printed
    # values would put the entire vault into one archived transcript entry.
    #
    # The note is flattened to one line and never cut. This list is the only
    # place a note is ever read, so what a cut dropped would have no other
    # route, and the note is the last column, so a long one makes a long line.
    # see docs/vault.md#a-truncated-note-read-like-a-complete-one
    #
    # rw / ro is stated rather than left to the project-naming convention: the
    # guess is "may I write this", and its wrong answer is a refusal at the
    # worst moment or an attempt to overwrite something of the operator's. The
    # same WRITABLE_PROJECT drives this column and the `put` below, so they
    # cannot disagree.
    #
    # Captured before jq sees them, and the status checked, because `die`
    # inside a command substitution exits the subshell only — the caller
    # carries on and prints a later, wrong message in front of the true one.
    # see docs/vault.md#a-guess-printed-as-a-diagnosis
    _secrets=$(secrets_json) || exit $?
    _projects=$(projects_json) || exit $?
    jq -rn --argjson s "$_secrets" --argjson p "$_projects" \
           --arg writable "$WRITABLE_PROJECT" '
        ($p | map({key: .id, value: .name}) | from_entries) as $names
        # How many rows share each name. A name is not unique in Bitwarden,
        # and a duplicate is refused by get and by put rather than guessed at
        # — so this list is where you find out one exists, and it has to say
        # so out loud. Two identical names in a column of names is exactly the
        # thing an eye slides over.
        | ($s | group_by(.key) | map({key: .[0].key, value: length}) | from_entries) as $seen
        | $s
        | sort_by(.key)[]
        | ($names[.projectId] // "-") as $project
        # The project name itself is not shown. It is bookkeeping that belongs
        # to the operator, and the only thing it answers from in here is whether this
        # secret can be written — which the next line says outright. The name
        # would be a second way of asking one question, and the worse way.
        #
        # No apostrophes in this comment, deliberately: the jq program is a
        # single-quoted shell string, and one apostrophe ends it four lines
        # before the parser notices.
        | [ .key,
            (if $project == $writable then "rw" else "ro" end),
            ((if $seen[.key] > 1
              then "*** DUPLICATE NAME: \($seen[.key]) rows share it, and reads and writes refuse until one goes *** "
              else "" end)
             + ((.note // "") | gsub("\\s+"; " ")))
          ] | @tsv' \
        || die "could not read the secret list."
    ;;

path)
    [ $# -eq 2 ] || usage
    sanitise "$2"
    printf '%s/%s\n' "$CACHE_DIR" "$2"
    ;;

get)
    [ $# -ge 2 ] && [ $# -le 3 ] || usage
    key="$2"
    sanitise "$key"
    case "${3:-}" in
        --value) fetch "$key"; printf '%s' "$VALUE" ;;
        '')
            fetch "$key"
            # The path on stdout, and on stderr the sentence that stops it
            # being misread — a reader who assumes "get" means the value pipes
            # a filename somewhere as a credential. stderr and not stdout, so
            # `"$(vault get k)"` keeps capturing the path alone.
            # see docs/vault.md#get-prints-the-path-and-was-read-as-printing-the-secret
            printf '%s\n' "$CACHE_DIR/$key"
            # shellcheck disable=SC2016 # literal backticks intended
            printf 'vault: that is the PATH to the secret, not the secret. The value is in
that file, never printed. Read it with `cat`, or hand the path to whatever
wants a file. `vault get %s --value` prints the value itself, into this
transcript, which is archived.\n' "$key" >&2
            ;;
        *) usage ;;
    esac
    ;;

gh-login)
    [ $# -eq 2 ] || usage
    key="$2"
    sanitise "$key"
    fetch "$key"

    # The value reaches gh on a pipe and nowhere else, which is why the
    # subcommand exists: the spelled-out form is a compound with a substitution
    # in it, matches no single permission pattern, and the classifier refuses
    # it. So `gh auth` stays denied in every spelling, login included — the
    # capability is here, and the credential crosses neither a command line, a
    # stdout nor a transcript.
    # see docs/vault.md#gh-login-and-gh-secret-exist-because-the-spelled-out-form-is-refused
    printf '%s' "$VALUE" | gh auth login --with-token 2>/dev/null \
        || die "gh refused the token in '$key'. It may be expired, revoked, or not a
GitHub token at all — 'vault list' shows the note that says what it is."

    who=$(gh api user --jq .login 2>/dev/null) \
        || die "gh accepted the token and then could not use it. Check the network."
    printf 'gh authenticated as %s, from %s\n' "$who" "$key"
    ;;

gh-secret)
    # `gh-login`'s reason with one word changed: a workflow needs its
    # credential in GitHub's own Actions store, which this vault is not and a
    # runner cannot reach. Both obvious spellings fail — one writes the
    # credential onto a command line the transcript records verbatim, the other
    # is a substitution the classifier refuses — and `Bash(vault:*)` already
    # allows this, so it needs no new rule anywhere.
    #
    # What it grants, said plainly: any vault secret this session can read can
    # be copied into an Actions secret, so a credential can leave this
    # container's blast radius for GitHub's runners. Ruled acceptable — a
    # session that can read a secret can already send it anywhere, in a
    # container with open egress and a Python interpreter, so this is the same
    # value in a place the operator owns and can rotate or delete.
    # see docs/vault.md#gh-login-and-gh-secret-exist-because-the-spelled-out-form-is-refused
    [ $# -eq 3 ] || [ $# -eq 4 ] || usage
    key="$2"
    name="$3"
    sanitise "$key"

    # GitHub's own rule for a secret name, checked before the fetch rather
    # than left to the API: a name that was never going to be accepted costs a
    # refusal instead of a credential read out of the vault and cached on the
    # way to nowhere. The reserved `GITHUB_` prefix is the one people reach for.
    case "$name" in
        ''|[0-9]*|*[!A-Za-z0-9_]*)
            die "'$name' is not a usable Actions secret name: letters, digits and
underscores only, and not starting with a digit." ;;
        GITHUB_*)
            die "GitHub reserves names beginning with GITHUB_. Nothing was read." ;;
    esac

    # Resolved before the fetch, for that same reason and one more: a wrong
    # answer here is a credential written into a repository nobody meant, and
    # `gh` resolving it silently from the current directory is how that
    # happens. Named on stdout at the end either way, so the transcript records
    # which repository received it rather than which one the command implied.
    repo="${4:-}"
    if [ -z "$repo" ]; then
        repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
            || die "no <owner/repo> given and this directory is not a GitHub
repository gh can resolve. Name the repository, or run this from a checkout."
    fi

    fetch "$key"

    # --test fetches the fixture and stops: a scratch value written into a
    # real repository's Actions store is a real write, and a rehearsal that can
    # do that is one nobody dares run — the same reason `just test-container`
    # has no volume. It still proves the name, the repository, and that the
    # fixture is readable.
    if [ "$TEST_MODE" = true ]; then
        printf 'would set %s in %s, from the test fixture %s. Nothing was written.\n' \
            "$name" "$repo" "$key"
        exit 0
    fi

    # The value reaches gh on a pipe and nowhere else. `gh secret set` with no
    # --body reads it from stdin, which is what makes that possible.
    printf '%s' "$VALUE" | gh secret set "$name" --repo "$repo" 2>/dev/null \
        || die "gh could not set $name in $repo. The login may lack the
'secrets' permission on that repository, or the repository may not exist —
'gh secret list --repo $repo' says which."

    printf 'set %s in %s, from %s\n' "$name" "$repo" "$key"
    ;;

ssh-restore)
    [ $# -eq 2 ] || usage
    key="$2"
    sanitise "$key"
    fetch "$key"

    # Without this, the entrypoint's answer to a home with no key is to
    # generate one — and a key GitHub has never seen cannot clone, so recovery
    # stops dead waiting for a human to paste a public key into a browser. The
    # private half is the only part worth keeping: `ssh-keygen -y` derives the
    # public one, and known_hosts refills itself under the accept-new policy.
    #
    # The trailing newline is not cosmetic. `fetch` writes with `printf '%s'`
    # and a command substitution strips trailing newlines, so the cached copy
    # of a private key is one byte short of what OpenSSH accepts, and the
    # rejection reads as a corrupt key rather than a missing byte. Normalised
    # here, once, where the file is written.
    # see docs/vault.md#the-restored-private-key-was-one-byte-short
    mkdir -p "$HOME/.ssh" || die "could not create $HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    dest="$HOME/.ssh/id_ed25519"

    # Written and proved beside the real one, then moved into place. A restore
    # that overwrote a working key with something the vault could not parse
    # would turn a container that merely had no login into one that cannot
    # reach its own repository, and the entrypoint calls this before it knows
    # whether the value is a key at all.
    tmp="$dest.restore-$$"
    ( umask 077; printf '%s\n' "${VALUE%$'\n'}" > "$tmp" ) \
        || die "could not write $tmp"

    if ! ssh-keygen -y -f "$tmp" > "$tmp.pub" 2>/dev/null; then
        rm -f "$tmp" "$tmp.pub"
        die "'$key' is not an OpenSSH private key that ssh-keygen can read. Nothing
was changed. 'vault list' shows the note that says what the secret is."
    fi

    chmod 600 "$tmp"
    chmod 644 "$tmp.pub"
    # shellcheck disable=SC2015 # either mv failing must die
    mv -f "$tmp" "$dest" && mv -f "$tmp.pub" "$dest.pub" \
        || die "could not place the key at $dest."

    printf 'restored %s to %s\n' "$key" "$dest"
    printf '  %s\n' "$(ssh-keygen -lf "$dest.pub")"

    # `ssh -T git@github.com` exits 1 on success — GitHub answers and then
    # refuses the shell — so the status says nothing and the greeting says
    # everything. Not fatal either way: a key that is on the account and a
    # network that is down look the same from here, and the clone that follows
    # says so itself.
    #
    # The greeting is selected out of the output, not taken as its first line:
    # on a fresh home known_hosts is empty, so the accept-new warning is line 1
    # and the greeting is line 2.
    # see docs/vault.md#the-ssh-greeting-is-the-second-line
    said=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1)
    greeting=$(printf '%s\n' "$said" | grep -m1 '^Hi ')
    if [ -n "$greeting" ]; then
        printf '  github says: %s\n' "$greeting"
        exit 0
    fi

    complaint=$(printf '%s\n' "$said" | grep -v '^Warning: Permanently added' | head -1)
    printf '  github did NOT recognise it: %s\n' "$complaint" >&2

    # Exit 3 is "restored, and GitHub refused it", so the entrypoint can tell
    # it from "nothing was restored" (1) without grepping this output. The two
    # want opposite things: nothing restored means generate a key, and a
    # restored key GitHub refuses must be kept — generating over it trades one
    # identity the account does not know for another, and loses the fingerprint
    # that says the vault copy is stale.
    #
    # Only when GitHub answered and said no. `ssh -T` cannot distinguish a
    # refused key from an unreachable host by exit status, so a network blip
    # treated as a refusal would stop a container whose key is perfectly good.
    case "$complaint" in
        *'Permission denied'*) exit 3 ;;
        *)                     exit 0 ;;
    esac
    ;;

put)
    [ $# -eq 4 ] || usage
    key="$2"
    sanitise "$key"
    # Required, in the spelling collect.sh uses for --approve and for the
    # reason written there: a secret whose only description is its key is a
    # record nobody can account for later.
    [ "${3:-}" = "--note" ] || usage
    note="$4"
    [ -n "$note" ] || die "the note cannot be empty. Say what the secret is for."
    [ -t 0 ] && die "the value is read from stdin:
    vault put $key --note '...' < file
Passing it as an argument would archive it in the transcript."

    value=$(cat)
    [ -n "$value" ] || die "nothing on stdin. Refusing to store an empty secret."

    project=$(projects_json \
        | jq -r --arg n "$WRITABLE_PROJECT" '[.[] | select(.name == $n)] | first | .id // empty') \
        || exit $?
    [ -n "$project" ] || die \
        "no writable project called '$WRITABLE_PROJECT'. Reading works and writing
does not, which is a scope question for the operator rather than something to route around."

    # Replacing an existing key is allowed, and only inside the writable
    # project: the read-only project is already what protects a secret from
    # being rewritten. There is no version history on this plan, so a
    # replacement is final — the line below says "replaced" and not "stored",
    # so a transcript records which of the two occurred.
    # see docs/vault.md#replacing-a-secret-and-where-that-was-ruled
    #
    # Every row with this name, not the first one: a name can exist in more
    # than one place, so `first` would refuse or quietly edit a read-only
    # secret with a writable namesake depending on which row came back first.
    # What matters is whether any match is somewhere this command may not
    # write, and that is asked directly.
    matching=$(secrets_json | jq -c --arg k "$key" '[.[] | select(.key == $k)]') || exit $?
    readonly_hits=$(printf '%s' "$matching" \
        | jq --arg p "$project" '[.[] | select(.projectId != $p)] | length')
    writable_hits=$(printf '%s' "$matching" | jq --arg p "$project" '[.[] | select(.projectId == $p)] | length')

    if [ "$readonly_hits" -gt 0 ]; then
        die "'$key' lives in a project you can only read. Its value is the operator's to
change — ask them, in an issue with them assigned, rather than storing a second
copy under another name. Storing one anyway would not replace theirs: both would
exist under one name, and which one a later read returns is not defined."
    fi
    [ "$writable_hits" -le 1 ] || die "there are $writable_hits secrets already called '$key'. Nothing was
written — replacing one of several would leave the others behind holding
different values, under the same name. 'vault list' shows them."

    existing_id=$(printf '%s' "$matching" | jq -r 'first | .id // empty')

    if [ -n "$existing_id" ]; then
        # `--value=` and `--note=` with the equals sign, and `--` before the
        # positionals below. Not style: bws is clap, and a value that begins
        # with a hyphen is read as a flag — every PEM begins `-----BEGIN`, so
        # without this the wrapper cannot store a private key in its standard
        # form at all. Both spellings make the parser take the rest literally.
        # see docs/vault.md#a-leading-hyphen-defeated-bws
        bws_said "$BWS" secret edit --value="$value" --note="$note" \
            --output json -- "$existing_id" \
            || die "bws refused to replace '$key'. Its own words, with the value
taken out of them:

$BWS_SAID

That is bws speaking and not a diagnosis from here. If it says nothing
useful, look first at the machine account's write scope on
'$WRITABLE_PROJECT'."
        printf 'replaced %s in %s — the previous value is gone, this plan keeps no history\n' \
            "$key" "$WRITABLE_PROJECT"
    else
        bws_said "$BWS" secret create --note="$note" --output json \
            -- "$key" "$value" "$project" \
            || die "bws refused to create '$key'. Its own words, with the value
taken out of them:

$BWS_SAID

That is bws speaking and not a diagnosis from here. If it says nothing
useful, the usual causes are the machine account's write scope on
'$WRITABLE_PROJECT' and a project id that no longer exists.

This sentence used to assert the scope problem outright. It was wrong the
one time it mattered: the cause was the leading hyphen above, write access
worked, and a guess printed as a diagnosis sent a session to the operator with a
scope question they would have had to investigate."
        printf 'stored %s in %s\n' "$key" "$WRITABLE_PROJECT"
    fi

    # The cache follows the vault, so `vault path k` never names a superseded
    # value and rule 10's coverage of a stored secret is true of `put` and not
    # only of `get`. After the report rather than before it: the store has
    # already happened and is worth reporting even if this then fails.
    # see docs/vault.md#put-did-not-follow-the-cache
    cache_write "$key" "$value"
    ;;

clear)
    # Cache hygiene, and nothing in the vault. Said twice because the word
    # "clear" beside a secret store reads as deletion: this removes files under
    # ~/.cache only, and every key it removes can be fetched again.
    [ $# -eq 1 ] || [ $# -eq 2 ] || usage
    dry=false
    case "${2:-}" in
        --dry-run) dry=true ;;
        '')        ;;
        *)         usage ;;
    esac

    # --test is refused rather than accepted and reinterpreted. Under the rule
    # the flag follows everywhere else — the scratch project instead of the
    # others — `clear --test` would mean "delete every cached key that is not a
    # fixture", which is every real credential in the cache, and the guard
    # reads this directory. The plain command already removes fixtures, because
    # a fixture is by definition not in either real project.
    # see docs/vault.md#fixtures-have-their-own-cache-directory
    [ "$TEST_MODE" = false ] || die \
        "clear has no --test. It keeps what is in '$READABLE_PROJECT' and
'$ACQUIRED_PROJECT' and removes the rest, so it already takes '$TEST_PROJECT'
fixtures out of the cache. Inverting it would delete the real credentials
instead, and the guard reads this directory."

    [ -d "$CACHE" ] || { echo "nothing cached: $CACHE does not exist"; exit 0; }

    # Both names must resolve, and the failure is fatal: a renamed or missing
    # project comes back as an empty keep-set, and an empty keep-set says "none
    # of this is real, delete all of it".
    keep_ids=$(projects_json | jq -c --arg r "$READABLE_PROJECT" --arg a "$ACQUIRED_PROJECT" \
        '[ .[] | select(.name == $r or .name == $a) | .id ]') || exit $?
    [ "$(printf '%s' "$keep_ids" | jq 'length')" -eq 2 ] || die \
        "expected to find both '$READABLE_PROJECT' and '$ACQUIRED_PROJECT' and did not.
Nothing was removed. Check the project names before running this again — an
unresolved name here reads as 'nothing is real' and would empty the cache."

    keep=$(secrets_raw | jq -r --argjson ids "$keep_ids" \
        '[ .[] | select(.projectId as $p | $ids | index($p) != null) | .key ] | .[]') || exit $?

    # Dotfiles are skipped: `fetch` writes through `.<key>.<pid>` and renames,
    # and a key may not begin with a dot — `sanitise` refuses that — so
    # anything starting with one is a half-written file belonging to a fetch
    # that may still be running, not a cached key.
    removed=0 kept=0
    for entry in "$CACHE"/*; do
        [ -f "$entry" ] || continue
        name=$(basename "$entry")
        if printf '%s\n' "$keep" | grep -qxF -- "$name"; then
            kept=$((kept + 1))
            continue
        fi
        removed=$((removed + 1))
        if [ "$dry" = true ]; then
            printf 'would remove %s\n' "$name"
        else
            rm -f -- "$entry" || die "could not remove $entry"
            printf 'removed %s\n' "$name"
        fi
    done

    # The scratch cache, swept whole. Everything in it is a fixture by
    # construction — it is only written under --test — so there is no keep-set
    # to consult and nothing here needs the vault's opinion.
    if [ -d "$CACHE/test" ]; then
        for entry in "$CACHE"/test/*; do
            [ -f "$entry" ] || continue
            removed=$((removed + 1))
            name="test/$(basename "$entry")"
            if [ "$dry" = true ]; then
                printf 'would remove %s\n' "$name"
            else
                rm -f -- "$entry" || die "could not remove $entry"
                printf 'removed %s\n' "$name"
            fi
        done
    fi

    if [ "$removed" -eq 0 ]; then
        printf 'nothing to remove: all %d cached key(s) are in the vault\n' "$kept"
    elif [ "$dry" = true ]; then
        printf '\n%d would be removed, %d kept. Nothing was changed, in the cache or the vault.\n' \
            "$removed" "$kept"
    else
        printf '\n%d removed from the cache, %d kept. The vault is untouched — every\nkey above can be fetched again.\n' \
            "$removed" "$kept"
    fi
    ;;

*) usage ;;
esac
