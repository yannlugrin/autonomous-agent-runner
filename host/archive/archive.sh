# shellcheck shell=bash
# shellcheck disable=SC2154  # the lowercase names here are collect.sh's, which
# sources this file; shellcheck reads a sourced fragment on its own and cannot
# see the caller that assigns them.
#
# The commit, and the push.
#
# Sourced by host/archive/collect.sh, last. It checks `sessions` out in a
# throwaway worktree, places every staged transcript where the layout map says
# it belongs, appends the run's rulings to the ledger, commits the two together
# and — with --push — pushes.
# see docs/archive.md#the-commit


# --- the worktree ---
# Where `sessions` comes from, in order: the local branch, the remote's if this
# clone has never checked it out, and an orphan branch if it exists nowhere yet
# — the first collection into a fresh archive.
# see docs/archive.md#the-worktree-and-why-the-commit-is-never-made-in-the-archive-checkout

wt="$(mktemp -d)/$BRANCH"   # must not exist yet: `worktree add` creates it

if git -C "$ARCHIVE" show-ref --quiet --verify "refs/heads/$BRANCH"; then
    add=(add --quiet "$wt" "$BRANCH")
elif git -C "$ARCHIVE" show-ref --quiet --verify "refs/remotes/origin/$BRANCH"; then
    add=(add --quiet -b "$BRANCH" "$wt" "origin/$BRANCH")
else
    add=(add --quiet --orphan -b "$BRANCH" "$wt")
fi

# The one case this refuses: `$BRANCH` already checked out somewhere. git
# names that worktree in its own message, and forcing a second checkout of
# one branch — or moving the ref under it — is how the other tree silently
# starts reporting the new transcripts as deletions.
git -C "$ARCHIVE" worktree "${add[@]}" || die \
    "Could not check out '$BRANCH' — see the message above.
If it is checked out elsewhere, commit from there or remove that worktree."


# --- the transcripts, placed ---
# One by one, by the same map the pruner read, rather than by mirroring the
# staging tree: the archive's layout is not the volume's. A held transcript was
# removed from staging above and is simply not there to copy, which is how it
# stays out.
mkdir -p "$wt/transcripts"
while IFS="$(printf '\t')" read -r rel where; do
    [ -n "$where" ] || continue
    [ -f "$staging/$rel" ] || continue
    mkdir -p "$wt/transcripts/${where%/*}"
    cp "$staging/$rel" "$wt/transcripts/$where" || die \
        "could not place $rel at transcripts/$where. Nothing was committed."
done < "$layout"


# --- the rulings, recorded ---
# The ruling joins the transcripts in one commit. Written here rather than in
# ledger.sh, which only reads it, because this worktree is the only place
# `sessions` has a working file at all.
# see docs/archive.md#the-ledger-and-where-it-lives
if [ -n "$pending" ]; then
    if [ ! -f "$wt/$LEDGER" ]; then
        cat > "$wt/$LEDGER" <<'HEADER'
# Transcripts whose credential-shaped content was inspected and ruled on.
# One line per file:
#
#     <sha256 of the transcript>  approve  <path>   # why it is nothing
#     <sha256 of the transcript>  redact  <path>   # why it was rewritten
#
# `approve` archives the file as it stands: the shape was a fixture, a public
# key, prose about a key. `redact` archives it with the credential rewritten
# out, for a session worth keeping that carried a real one — the volume
# still holds the original, and redacting is not rotating.
#
# A line with no verb is an old one and means `clear`, which is the only
# thing it could have meant.
#
# Written only by `just collect`, in the same commit as the
# transcript it rules on. The hash is of the contents as they sit in the
# volume, so a transcript that grows is offered for review again — an entry
# vouches for what was read, not for a file name.
HEADER
    fi
    printf '%s\n' "$pending" | sed '/^$/d' >> "$wt/$LEDGER"
    # Counted, since a run may carry several. Both numbers are said even when
    # one is zero: "Recorded 3 approval(s)" alone reads as a run that had no
    # redaction in it, and that is the half worth being sure about.
    printf 'Recorded %s approval(s) and %s redaction(s) in %s.\n' \
        "$(printf '%s\n' "$pending" | grep -c '  approve  ' || true)" \
        "$(printf '%s\n' "$pending" | grep -c '  redact  ' || true)" "$LEDGER"
fi


# --- the commit ---

if [ -z "$(git -C "$wt" status --porcelain)" ]; then
    echo "No change since the last collection."
    # Not an exit when --push, deliberately: a commit whose push failed would
    # otherwise sit unpushed until some later collection had something new to
    # say, and a backup only attempted when there is something new is not one.
    # The cost is one no-op push.  see docs/archive.md#the-push
    if [ "$PUSH" != true ]; then
        held_note
        exit 0
    fi
else
    # Counted after staging, from the index, because that is the only place the
    # number is exact: `status --porcelain` collapses an untracked directory
    # into one entry, and the count is the only record of a collection's size
    # once the files are indistinguishable from the rest.
    # see docs/archive.md#counting-a-collections-size
    #
    # --no-renames because the default pairs a deletion with an addition of the
    # same content and prints one line for the two, and two transcripts with
    # identical bytes is not far-fetched here.
    git -C "$wt" add -A transcripts "$LEDGER" 2>/dev/null || git -C "$wt" add -A transcripts
    changed=$(git -C "$wt" diff --cached --no-renames --name-only)
    added=$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l)
    git -C "$wt" commit -q -m "transcripts: collected $(date -u +%Y-%m-%dT%H:%MZ) ($added file(s) changed)"
    echo "Committed to $BRANCH in $ARCHIVE."

    # Said only of what actually moved, counted from the staged diff: a
    # redaction is re-derived whenever its transcript is read, so counting
    # those describes the machinery rather than what happened. On its own line
    # and never folded into the clean count above — a redacted transcript is
    # not one found to be nothing, and one number for both would misinform
    # about the only two outcomes the ledger exists to tell apart.
    rewritten=0
    while read -r _hash rel; do
        [ -n "$rel" ] || continue
        if printf '%s\n' "$changed" | grep -qxF "transcripts/$rel"; then
            rewritten=$((rewritten + 1))
        fi
    done <<< "$(printf '%s\n' "$to_redact" | sed '/^$/d')"
    if [ "$rewritten" -gt 0 ]; then
        echo "$rewritten of them had a credential rewritten out first. The volume keeps the originals."
    fi
fi


# --- the push ---

if [ "$PUSH" = true ]; then
    # --set-upstream, because the first collection into a fresh archive creates
    # the branch here and it has no upstream yet.
    #
    # The failure is named rather than left to `set -e`: a push that fails after
    # the commit leaves the transcripts in the local archive and nowhere else,
    # which the caller's message would report as nothing archived. It is also
    # the last chance to print what the gate held back.
    if git -C "$wt" push --set-upstream origin "$BRANCH"; then
        echo "Pushed."
    else
        held_note
        # Not "committed but not pushed": this run may have had nothing new
        # to commit and be re-offering an older one. What is true either way
        # is where the transcripts are and where they are not.
        die "The push FAILED — see above. What is on $BRANCH in $ARCHIVE is there
and nowhere else. Push it yourself, or re-run 'just collect --push': an unpushed
commit is offered again."
    fi
else
    echo "Not pushed. Re-run with --push, or push $BRANCH yourself."
fi
held_note
