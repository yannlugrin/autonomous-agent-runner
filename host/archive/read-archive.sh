# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # the lowercase names here are collect.sh's,
# which sources this file, and scan.sh reads what it leaves; shellcheck reads a
# sourced fragment on its own and can see neither.
#
# The first stage of `just collect --scan-archive`: what the archive holds.
#
# Sourced by host/archive/collect.sh in place of read-volume.sh. It fills
# `$staging` with the transcripts on origin's `sessions`, sets `found` and
# `archive_ref`, and puts the vault's secrets in `volume_secrets` — the name the
# gate reads, though nothing here comes from the volume.
# see docs/archive.md#what-is-on-origin-is-not-read-again


# --- origin's `sessions`, and not this clone's ---
# A local `sessions` is only as current as the last collection made in this
# clone, and a scan of it would miss everything collected on the other host.

git -C "$ARCHIVE" fetch --quiet origin "$BRANCH" 2>/dev/null \
    || echo "note: could not fetch $ARCHIVE — reading origin/$BRANCH as last fetched."
git -C "$ARCHIVE" show-ref --quiet --verify "refs/remotes/origin/$BRANCH" \
    || die "No origin/$BRANCH in $ARCHIVE: nothing has been archived yet."
archive_ref="origin/$BRANCH"


# --- the transcripts ---

echo "Extracting the transcripts on $archive_ref ..."
git -C "$ARCHIVE" archive "$archive_ref" transcripts | tar -x -C "$staging" \
    || die "Could not read the transcripts out of $archive_ref."

found=$(find "$staging" -name '*.jsonl' | wc -l)
[ "$found" -gt 0 ] || die "No transcripts on $archive_ref. Nothing to scan."
echo "Found $found transcript(s)."


# --- the vault's secrets, for the verbatim layer ---
# Through the image's own `vault`, the one route to them, which keeps the
# scratch project out as it does for every reader. In a throwaway container that
# mounts no volume, with a read-only root and `vault`'s cache in RAM, and the
# values reach this shell on stdout and stay in it, as read-volume.sh keeps the
# volume's: never on disk, never on a command line.
#
# The public half of each private key is derived and sent as `public`, which is
# what read-volume.sh reads from the .pub files. Without it a window of a key's
# body that sits inside its own public blob — printed quite properly — reads as
# the key itself: measured 2026-09-12, two transcripts named for github-ssh-key
# that held only its public key.  see docs/archive.md#public-halves-are-not-secrets
#
# A secret that lives only in the volume is not compared: an ssh key never
# stored in the vault, or an interactive login's credentials file.

image="${RUNNER_IMAGE:-$RUNNER_IMAGE_DEPLOYED}"
docker image inspect "$image" >/dev/null 2>&1 || image="$RUNNER_IMAGE_CANDIDATE"
host/lib/docker-up.sh --image "$image"

echo "Reading the vault's secrets for the verbatim comparison ..."
if vault_stream=$(docker run --rm -e BWS_ACCESS_TOKEN -e BWS_SERVER_URL \
        --read-only --tmpfs /tmp:mode=1777 -e HOME=/tmp/scan-archive \
        --cap-drop ALL --security-opt no-new-privileges \
        --entrypoint /bin/bash "$image" -c '
    set -uo pipefail
    umask 077
    mkdir -p "$HOME"
    keys=$(vault list | cut -f1) || exit 1
    publics=""
    echo "=== vault-cache"
    for key in $keys; do
        path=$(vault get "$key") || exit 1
        echo "=== vault:$key"
        cat "$path"
        echo
        # A copy with a final newline: the vault stores a key without one, and
        # ssh-keygen then answers "error in libcrypto" and derives nothing.
        { cat "$path"; echo; } > "$HOME/derive"
        if pub=$(ssh-keygen -y -f "$HOME/derive" 2>/dev/null); then
            publics="$publics$pub
"
        fi
        rm -f "$HOME/derive"
    done
    echo "=== public"
    printf "%s" "$publics"
    echo' 2>/dev/null); then
    printf 'Compared against %s vault secret(s).\n' \
        "$(printf '%s\n' "$vault_stream" | grep -c '^=== vault:')"
else
    echo "note: the vault could not be read — the verbatim layer compares against nothing."
    vault_stream=""
fi

# shellcheck source=SCRIPTDIR/exempt.sh
. host/archive/exempt.sh
volume_secrets=$(with_exemptions "$vault_stream")
