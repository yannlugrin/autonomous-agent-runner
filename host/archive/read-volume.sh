# shellcheck shell=bash
# shellcheck disable=SC2154  # the lowercase names here are collect.sh's, which
# sources this file; shellcheck reads a sourced fragment on its own and cannot
# see the caller that assigns them.
#
# The first stage of `just collect`: what is in the volume.
#
# Sourced by host/archive/collect.sh. It fills `$staging` with the checkout's
# transcripts, sets `found` and `outside`, writes the layout map to `$layout`,
# and puts the volume's own secrets in `volume_secrets` — the stream every
# later stage compares a transcript against.
# see docs/archive.md#what-reaches-the-archive-at-all


# --- the transcripts, out of the volume ---
# Read-only mount, throwaway container, root inside it so nothing in the
# volume is unreadable. Only the transcripts: shell snapshots and file history
# are noise, and file history alone is tens of megabytes.

echo "Extracting transcripts from $VOLUME ..."

# Root inside the container has to do the reading — the transcripts are 0600
# owned by uid 1001 — but everything it writes to the bind mount comes out
# root-owned, so it hands ownership back before exiting.
#
# Only the checkout's own sessions, filed under the mangled cwd. `just shell`
# lands in /home/agent and is neither archived nor scanned, and `just verify`'s
# probes run with a HOME of their own so their transcripts never reach the
# volume at all.
# A session started without `-w` would file itself outside and never be
# archived, with nothing to notice, so the count left behind is printed.
# see docs/archive.md#only-the-checkouts-own-sessions
# see docs/verify.md#a-probe-does-not-file-in-the-agents-directory

SESSIONS_DIR="${AGENT_PROJECT_DIR:?not set — run this through 'just', which derives it from the checkout}"
outside=$(docker run --rm \
    -v "$VOLUME":/vol:ro \
    -v "$staging":/out \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e DIR="$SESSIONS_DIR" \
    "$IMAGE" \
    sh -c 'cd /vol/.claude/projects 2>/dev/null || exit 0
           find . -name "*.jsonl" -not -path "./$DIR/*" | wc -l
           find "./$DIR" -name "*.jsonl" -exec cp --parents {} /out/ \; 2>/dev/null
           chown -R "$HOST_UID:$HOST_GID" /out' 2>/dev/null | tr -dc '0-9')

found=$(find "$staging" -name '*.jsonl' | wc -l)
if [ "$found" -eq 0 ]; then
    # Nothing to collect is a failure for a collection and an answer for a
    # count: a caller reading a non-zero exit as "could not tell" would report
    # a fresh volume as a broken gate.
    [ "$HELD" = true ] && { echo 'waiting-on-review: 0'; exit 0; }
    die "No transcripts found in the volume. Nothing to do."
fi

echo "Found $found transcript(s)."
if [ "${outside:-0}" -gt 0 ]; then
    printf '%s more are outside the checkout — probes and shells, not archived.\n' "$outside"
fi


# --- where each one belongs ---
# Decided once and read by both the pruner and the copy. Two spellings of a
# directory name drift silently: a pruner looking in the wrong place finds
# nothing already archived and re-reads all of it, for ever.
# see docs/archive.md#the-layout-on-disk

layout=$(mktemp)
python3 host/archive/archive-layout.py "$staging" > "$layout" \
    || die "could not work out where the transcripts belong. Nothing was committed."


# --- the volume's own secrets ---
# A gate, not a report: it runs first, over every transcript, and a hit holds
# the file. Run only over what the shape layers had already flagged it could
# never find what they missed, which is the only thing it is for.
# see docs/archive.md#it-is-a-gate-not-a-report
#
# No false positives by construction — not "this looks like a credential" but
# "this is a byte string the volume is holding" — and the only layer covering a
# shape nobody has written down. The cost: anything the operator puts in the
# vault counts, so an identifier stored there holds transcripts until ruled on.
#
# The secrets are read out of the volume once, kept in this process, and handed
# to grep on standard input: never written to disk, never passed as arguments
# where `ps` would show them, never printed. The transcript is the untrusted
# side and is the only side ever quoted.
#
# The trailing `echo` on each section is not tidiness: a file ending without a
# newline glues the next marker onto its last line, and the failure reads as
# "nothing in the volume to compare against" — which is why a section is
# reported missing rather than empty.
# see docs/archive.md#a-missing-section-is-not-an-empty-one

volume_secrets=$(docker run --rm -v "$VOLUME":/vol:ro "$IMAGE" sh -c '
    # Every private key in .ssh, discovered rather than listed, like the vault
    # block below: a hand-written list goes stale, silently, the next time a
    # key is minted.
    # see docs/archive.md#every-private-key-discovered-rather-than-listed
    #
    # `ssh-keys` is emitted whatever happens, so an .ssh with no key in it is
    # told apart from a section that never arrived.
    echo "=== ssh-keys"
    for f in /vol/.ssh/id_*; do
        case "$f" in *.pub) continue ;; esac
        [ -f "$f" ] || continue
        echo "=== ssh:$(basename "$f")"; cat "$f" 2>/dev/null; echo
    done
    # The halves made to be handed out, and the only section here that is not a
    # secret. An OpenSSH private key file contains its own public key, so a
    # window of its body can land inside the public blob a transcript prints
    # perfectly properly; needles.py winnows those out. Read rather than
    # derived: the .pub file is exactly what was handed out and stays right
    # when a key is rotated.
    # see docs/archive.md#public-halves-are-not-secrets
    echo "=== public";        cat /vol/.ssh/*.pub                    2>/dev/null; echo
    echo "=== credentials";   cat /vol/.claude/.credentials.json     2>/dev/null; echo
    # No section names a path the agent chose: such a path covers nothing from
    # the day the agent picks another, and says nothing when it does. What
    # covers those keys is this section, comparing every fetched secret
    # verbatim whatever it is called, and the shapes in image/config/secret-shapes.txt.
    # see docs/archive.md#a-path-the-agent-chose-is-not-a-mechanism
    #
    # One section per fetched secret. `vault-cache` is emitted whatever happens,
    # so an unreadable or absent directory is told apart from a volume where
    # nothing has been fetched.
    echo "=== vault-cache"
    for f in /vol/.cache/vault/*; do
        [ -f "$f" ] || continue
        echo "=== vault:$(basename "$f")"; cat "$f" 2>/dev/null; echo
    done
' 2>/dev/null || true)


# --- the vault entries that are not credentials ---
# From the same list the guard reads — `image/config/vault-exempt.txt`, one file for
# two readers that cannot see each other. Appended on the same stream as the
# secrets, so no reader can be given the secrets and not the exemptions.
# see docs/vault.md
#
# Blanks and comments out, and anything with a space in it out with them — a
# vault key has none, and a note someone forgot to comment would otherwise
# become an exemption. An absent or unreadable list exempts nothing.

volume_secrets=$(printf '%s\n=== exempt\n%s\n' "$volume_secrets" \
    "$(awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
              if ($0 != "" && $0 !~ /[[:space:]]/) print }' \
        image/config/vault-exempt.txt 2>/dev/null || true)")
