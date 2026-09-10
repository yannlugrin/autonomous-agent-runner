#!/usr/bin/env bash
# Mirror one branch of a source repository onto one ref of this repository.
#
# Called by the workflow once per record, with:
#
#   SOURCE_URL     ssh URL of the source repository
#   SOURCE_BRANCH  the branch mirrored
#   TARGET_REF     refs/<record>/mirror; rewind marks go to refs/<record>/rewound/
#   KEY_FILE       a read-only deploy key on the source
#   GITHUB_TOKEN   the token that pushes here
#
# When the incoming history is not a descendant of what is already held — the
# source was rewritten — the old tip is pushed to a mark first, and only then is
# the ref reset. That is the whole point: a plain mirror loses what a
# force-push erased, and it loses it silently.
set -euo pipefail

say() { echo "$*"; echo "$*" >> "$GITHUB_STEP_SUMMARY"; }

# refs/heads/mirror would match the pattern below, and on a branch a mirrored
# workflow file runs here: see WHY EVERY REF BELOW.
case "$TARGET_REF" in
  refs/heads/*|refs/tags/*) echo "::error::$TARGET_REF is a ref that starts workflows"; exit 1 ;;
  refs/*/mirror) ;;
  *) echo "::error::TARGET_REF must be refs/<record>/mirror, not $TARGET_REF"; exit 1 ;;
esac

if [ ! -s "$KEY_FILE" ]; then
  echo "::error::no key for $SOURCE_URL — its secret is not set, see README.md in this repository"
  exit 1
fi

# IdentitiesOnly, or a key the runner happens to have takes precedence and the
# failure reads as "repository not found".
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o IdentitiesOnly=yes"

# Bare: nothing is ever checked out, so no worktree can collide with the
# unrelated histories living in one repository. One per call, because the steps
# of a job share RUNNER_TEMP.
repo=$(mktemp -d "$RUNNER_TEMP/mirror.XXXXXX")
git init -q --bare "$repo"
cd "$repo"
git config user.name  'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git remote add source "$SOURCE_URL"
# The token is a masked secret, so it does not survive into the log.
git remote add target "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# Refs outside refs/heads/: no name can be read as a branch or collide with the
# remotes' own names. --no-tags because the source's tags are the agent's, and
# this namespace is the operator's.
git fetch -q --no-tags source "+refs/heads/${SOURCE_BRANCH}:refs/work/source"
new=$(git rev-parse refs/work/source)

# WHY EVERY REF BELOW IS OUTSIDE refs/heads/* AND refs/tags/*.
#
# The agent writes workflow files in its own repository — that is its business
# and none of this repository's. But a mirror copies them here, and GitHub
# starts a workflow run using the workflow files FROM THE PUSHED REF. Land the
# agent's tree on a branch or a tag of this repository and a file it wrote
# saying `on: push` executes here, with this repository's secrets and whatever
# `permissions:` it asks for. The confined agent would be running code on the
# operator's credentials, which is the one thing the whole arrangement exists
# to prevent.
#
# GitHub only triggers on refs/heads/* and refs/tags/*. A ref in any other
# namespace is stored, fetchable, and anchors its objects against garbage
# collection exactly as a branch does — and can never run anything. That is a
# mechanism rather than a setting, and it holds whatever the agent writes next.
#
# THE REWIND MARK BELOW IS THE SAME HAZARD: a tag push triggers workflows too,
# so the marker is a ref under refs/<record>/rewound/ rather than an annotated
# tag. It still holds the objects; it is simply no longer executable.
#
# The cost, accepted knowingly: none of this is browsable on github.com, which
# lists branches and tags and nothing else. Read it with a fetch — `just
# mirror-status` in the runner.
#
# ls-remote exits 0 with empty output when the ref is absent, so a non-zero
# exit here is a real failure and must not be read as "first run".
old=$(git ls-remote target "$TARGET_REF" | cut -f1)

if [ -z "$old" ]; then
  git push -q target "refs/work/source:${TARGET_REF}"
  say "Created \`${TARGET_REF}\` at \`${new}\`."
  exit 0
fi

if [ "$old" = "$new" ]; then
  say "\`${TARGET_REF}\` already at \`${new}\` — nothing to mirror."
  exit 0
fi

git fetch -q --no-tags target "+${TARGET_REF}:refs/work/target"

if git merge-base --is-ancestor refs/work/target refs/work/source; then
  git push -q target "refs/work/source:${TARGET_REF}"
  say "Fast-forwarded \`${TARGET_REF}\`: \`${old}\` → \`${new}\`."
  exit 0
fi

# Not a descendant: the source rewrote history. Mark first, push the mark
# first, and only then move the ref — if the force-push fails, the old history
# is already safe.
#
# A plain ref and not `git tag -a`: an annotated tag would have to live in
# refs/tags/ to be useful as a tag, and that is a namespace that triggers
# workflows. What was wanted from it was a name and a reason, and the reason
# moves to the summary and the warning below.
mark="${TARGET_REF%/mirror}/rewound/$(date -u +%Y%m%dT%H%M%SZ)"
git push -q target "refs/work/target:${mark}"

# The lease is what makes the force safe: if anything moved the ref since the
# ls-remote above, this refuses instead of overwriting a tip that was never
# marked.
git push -q target --force-with-lease="${TARGET_REF}:${old}" \
  "refs/work/source:${TARGET_REF}"

echo "::warning::$SOURCE_BRANCH was rewritten — old tip $old preserved at $mark"
say "**\`${SOURCE_BRANCH}\` was rewritten.** Old tip \`${old}\` preserved at \`${mark}\`; \`${TARGET_REF}\` reset to \`${new}\`."
