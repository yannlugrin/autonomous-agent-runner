# Backup

## What it is, and what to do

The agent's memory — its instructions, its self-description, its journal — is a
git checkout inside the container's volume. A volume is one command from gone,
and an unattended agent is not going to remember to push before it stops. The
backup is what makes the memory survive the container: when a session ends, its
repository goes to origin.

There is nothing to set. It is a hook, and these are its parts:

| handle | what it is |
| --- | --- |
| `image/push-on-exit.sh` | the hook itself, baked into the image and registered as `SessionEnd` in managed settings. It lives here rather than in the agent's own repository because a hook the agent could blank would stop backing up its memory with **no symptom at all** |
| `image/bash-guard.py` | what it asks, before it sends anything, about what the push would carry |
| `<NAME>_REPO_DIR` | which repository is backed up. Named, never derived from the script's own location |
| `ERROR_ON_PUSH` | a file at the top of the agent's repository. Its only report — written when a push fails, read by the next session at its start |

**The rule.** At every session end the hook asks the guard what the push would
carry, and pushes only on a clear answer. **`ask` counts as no**, and so does a
guard that is missing, not executable, or that does not answer: there is nobody
at a `SessionEnd` to ask, and this is the one call in the tree that must fail
closed. It sends three refspecs — `HEAD`, `--all` and `--tags` — because
`git push origin HEAD` saved the current branch and nothing else, and reported
success. It never exits non-zero: a backup that fails must not look like a
broken session.

**What you see: nothing, when it works.** When it does not, the failure is in
`ERROR_ON_PUSH` in the agent's repository, and the next session reads it at
start. One failure is a hiccup the next session repairs; the count is of
*consecutive* failures, and at three the session escalates to you rather than
retrying forever. On this side, `just verify` has a probe that the backup still
asks the guard — a backup that quietly stopped asking would simply succeed.

**What it refuses.** It does not push notes: `--all` does not carry them and
nothing here has ever written one, so that is a decision and one line to add on
the day it changes. It does not treat a push as a task — local state is the
truth and survives in the volume, so a failed push costs a retry, not the work.
And it does not carry its own copy of the secret check: it asks the same guard,
in the same shape Claude Code asks it, because a second implementation is one
that drifts.

## How it is built

`image/push-on-exit.sh` is a `SessionEnd` hook: when a session ends it pushes
the agent's repository to origin, best-effort. It asks `image/bash-guard.py`
what the push would carry before it sends anything, pushes three refspecs
rather than one, and records any failure in a file named `ERROR_ON_PUSH` at
the top of the repository, which the next session reads at start. It never
exits non-zero. It lives in the image and is registered in managed settings,
not in the repository it protects.

## Why the hook lives in the image

If the agent could remove or blank this hook, the backup would stop with no
symptom at all. `ERROR_ON_PUSH` only appears when the hook RUNS and fails, so
a hook that never runs looks exactly like a successful push. That is the one
silent failure the design cannot afford, sitting on the mechanism the design
exists for.

Push is a backup, never a task. Local state is the truth and survives in the
container's volume, so a failed push costs a retry, not the work.

## The flag file is the only channel

This hook cannot report a failure to anyone while it runs: `SessionEnd` is
fire-and-forget and its stderr reaches a user who, by design, is not there.
So the outcome is written to disk, where the next session reads it at start —
the one channel that survives to the moment it is needed.

It never exits non-zero for the same reason: a backup that fails must not look
like a broken session, and there is no one watching to tell the difference.
`set -uo pipefail` and deliberately not `-e`, since every failure here is
handled.

`record_failure` counts *consecutive* failures. One is a hiccup the next
session repairs; three is an expired credential or a dead remote, and the
session that reads it escalates to the operator rather than retrying forever.

## The push is the one the guard never saw

Issue #14. This hook is the path by which everything in the agent's repository
actually reaches origin, and it was the one push the secret check never ran
on: the guard is a `PreToolUse` hook on the Bash tool, and this is a
`SessionEnd` hook calling git from inside a script, which is exactly what an
argv guard cannot read. Measured: `git push` typed in Bash gets a verdict;
this script gets none.

It mattered more after the three-refspec change than before it. The push scan
is the only layer for commits made by merge, cherry-pick, revert and am — none
of which the commit check sees — and for tag objects, which the three-refspec
form now sends. Widening what leaves without scanning what leaves is the wrong
pair.

So the hook asks the same guard, in the same shape Claude Code asks it, rather
than carrying a second implementation of the check that would drift from the
first. The guard's span — everything local that no remote has, plus every
local tag — is precisely what the three pushes send.

## Fail closed, and why the two sides differ

A backup that does not happen costs a retry on a persistent volume, announces
itself at the next session start, and escalates to the operator after three. A
secret that reaches origin cannot be undone by anything the agent can do that
matters: a rewrite does not reach the forge's own copies, and it never did.

That is why this call is unchanged by the operator's withdrawal of the rewrite
enforcement on 2026-09-01. What that ruling did change is the sentence that
used to sit at this line: the guard fails OPEN where Claude Code calls it, and
the managed deny list no longer sits under the git acts, so this call is not
the only one without a backstop any more. It is still the one that must fail
closed, for the reason above.

`ask` counts as no. There is nobody here to ask — that is what `SessionEnd`
means — and unattended an ask has always degraded to a refusal. A guard that
is missing, not executable, or that does not answer is a refusal too, each
recorded with its own reason.

The `timeout 30` around the guard is an outer bound beside the guard's own: a
guard that hung would be killed by the hook's 60-second timeout, and a killed
hook writes no flag at all. The point of the shorter bound is to leave time to
record why.

## Three pushes, not one clever one

Issue #13. `git push origin HEAD` saved the current branch and nothing else:
with a second branch, an annotated tag and a note present, the remote received
`refs/heads/main` alone, the hook exited 0 and no flag was written. A backup
that saves one ref out of four and reports success is this file's opening
failure at ref granularity instead of hook granularity.

`git push origin --all --tags` is not the one-liner it looks like:
`fatal: options '--all' and '--tags' cannot be used together`. Measured.

HEAD is kept alongside `--all` rather than replaced by it, and that is the
part worth not tidying later. With HEAD detached, `push --all` exits 0 — it
saves the branches and says nothing about the commit you are actually sitting
on — while `push origin HEAD` fails loudly with git's own "not a full refname"
explanation, which lands in the flag and the next session repairs. Dropping
HEAD would trade a loud failure for a silent one, in the one hook that cannot
afford silence.

`refs/notes/*` is deliberately not pushed: `--all` does not carry notes, and
nothing here has ever written one. That is a decision rather than an oversight
— one more round trip for a thing that does not exist — and it is one line to
add on the day a note is written.

All three are attempted even after one fails, so a single flag carries the
whole picture rather than only the first thing to go wrong.

## Which repository is backed up

The repository is named, never derived from the script's location: the script
lives in the image, at a path with no relation to the checkout.
`<PREFIX>_REPO_DIR` is compose's authoritative answer to which repository is
the agent's, so a session that spent its time inside some cloned project still
backs up the right one.

The prefix is built from `id -un` rather than written out: what is genuinely
the agent's is named for it, and the container's account IS the agent, so the
account name is the authority. Two `tr` calls because mixing a character class
with a literal in one set is not portable, and a shell variable name cannot
hold a dash.
