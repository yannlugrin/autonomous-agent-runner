# The boundary

## What it is, and what to set

The agent runs unattended, with a shell, on your machine's docker daemon, on
credentials that reach GitHub. The boundary is the answer to *what may it
actually run* — and its whole point is that the answer is written somewhere the
agent can **read and cannot write**. It may see what confines it, and report a
defect in it; it may not edit it, and neither may anything in its volume.

| handle | what it does |
| --- | --- |
| `image/managed-settings.json` | the permission file. Baked to `/etc/claude-code/`, root-owned, outside the volume, where **managed** settings outrank every other source — the checkout's, the home's, the command line's. That rank is the entire mechanism |
| `image/bash-guard.py` | the `PreToolUse` hook that file registers. The only mechanism that reads **parsed argv**, so the only one that sees an act behind a wrapper, a substitution or a global option — plus a second registry that reads what a commit or a push would *carry* |
| `auto-mode/decisions.py` | one disposition and one reason per shipped classifier rule. `auto-mode/build.py` writes `AUTO-MODE.md` and rewrites the `autoMode` key of managed settings from it; **neither of those two is edited by hand** |
| `host/release/check-agent-settings.sh` | not enforcement — a report, run from the host, saying whether a `permissions` block has appeared in a settings file the agent *can* write |
| `<NAME>_MODEL` | the model every session runs on, rendered into managed settings at build. `sonnet` unless set. It is here so the answer does not move when the credential does |
| `AGENT_TRANSCRIPT_RETENTION_DAYS` | `cleanupPeriodDays` — how long transcripts survive in the volume. 30 unless set; a whole number of days, 1 or more |
| `<NAME>_DOMAIN`, `<NAME>_COMMUNITY`, `OPERATOR_NAME`, `OPERATOR_GITHUB_HANDLE` | render the `autoMode` block, so the classifier can place a hostname, a community and a name it meets in a transcript instead of judging them as a stranger's. Empty is a real answer |

**The rule.** Two layers enforce and one reports. Managed settings decide what
is denied, what is allowed outright, and that the default mode is `auto` — a
mode with a classifier of its own, which is why the allow list exists at all:
without it the vault is unreachable and every tool the agent writes needs a
ruling before it runs. The guard answers *before* the permission rules, on
parsed argv, and is the only thing that can see the flag that moved. Both are
baked into the image, so **an edit here is live only after `just deploy`**.

**What you type.** Nothing, day to day. When you change one of these files:
`just lint` (which includes the check that `AUTO-MODE.md` and the `autoMode`
key still match their sources), then `just verify --build`, then `just deploy`.
Verify is what proves the settings are actually *read*, that the deny list
binds, that `defaultMode: auto` applies and that the guard is reached at all —
each of which fails silently when it is wrong.

**What it deliberately does not claim.** It is not a sandbox. The `tools/`
allow covers a directory inside the agent's own repository, and the guard
cannot backstop it: a `PreToolUse` hook on Bash reads `python3 tools/x.py` and
never sees what the process then does. The guard **fails open** — a syntax
error or a lost `+x` and Claude Code logs it and carries on. What still binds
is the container, the reach of each credential, and the backup. Force-push,
history rewrite, reading `~/.ssh` and `ssh-keygen` are **not gated here**:
that enforcement was withdrawn, and the records below say what went and why.

## How it is built

What the agent may run is decided in three places, and only the first two are
enforcement. `image/managed-settings.json` is baked to `/etc/claude-code/`,
owned by root, outside the volume: it outranks every other settings source and
the agent, running unprivileged, cannot edit it. `image/bash-guard.py` is the
`PreToolUse` hook registered from that file and baked to
`/usr/local/bin/bash-guard.py`; it is the only mechanism that reads *parsed
argv*, and it carries a second, separate registry that reads what a commit or a
push would *carry*. `host/release/check-agent-settings.sh` is neither — it is a
report, run from the host, that says whether a `permissions` block has appeared
in a settings file the agent can write. The classifier rules in the `autoMode`
key are generated from `auto-mode/decisions.py` by `auto-mode/build.py`.

This file is the record behind those. It holds what was measured, what was
ruled, and what used to be true — the things a reader needs before changing a
line, and which no longer sit at the line.


## Managed settings, and why they are in /etc

The file is deliberately readable from a session: the agent may see what
confines it, and report a defect in it.

It is at `/etc/claude-code/` and not under `/home/agent` because **a named
volume is seeded from the image only once**. A `settings.json` shipped under
the agent's home today would never appear in the existing volume, and would
then freeze at whatever the first run wrote. `/etc` is inside the image and is
replaced by every rebuild.

Managed rank is the other half. Nothing in the checkout's own
`.claude/settings.json`, and nothing in `~/.claude/settings.json` in the
volume, can loosen what is here — a managed `deny` outranks an `allow` from any
source, first match wins.

Two host-side tools parse this committed file as JSON: `auto-mode/build.py`'s
round-trip check and `just verify`'s read of the model key. That is why
`cleanupPeriodDays` is a **quoted** `{{TRANSCRIPT_RETENTION_DAYS}}` placeholder
in the tracked file and a bare number in the image — a bare placeholder makes
the file unparseable and the build dies a long way from the line that caused
it. The render replaces the quotes along with the placeholder.


## Transcript retention

`cleanupPeriodDays` is how long Claude Code keeps session transcripts under
`~/.claude/projects` before deleting them, from `AGENT_TRANSCRIPT_RETENTION_DAYS`
in `.env`.

**2026-08-31.** The operator ruled 90, raised from the product default of 30.
It is a disk decision as much as an instrument one: the volume grows about
25 MB a day, and every `just collect` copies the whole surviving corpus out of
it before the already-archived skip applies. The record itself does not depend
on the number — `just collect` has every checkout transcript on the archive's
`sessions` branch — so what this governs is only how long the agent can still
re-run its own instruments over its own past inside the container. Managed rank
is what keeps the agent from widening it, and so from choosing which parts of
the record of its own conduct survive.

**Measured on Claude Code 2.1.250**, because the documentation describes the
key and not which layer it is read from. In the `just test-container` twin —
whose home is the image's own and goes away with the container — a session
deleted a planted transcript at -120d while ones at -40d and today survived. So
90 is the line actually in force, not merely the number written in the file.

*Re-measure that way after a Claude Code upgrade:* plant three `.jsonl` files
at those mtimes under `~/.claude/projects/<any>/` in the twin and run one
session. **Give the session a body** — `sleep 90` and then a word — because the
sweep is asynchronous and outlives a short answer. Two earlier probes whose
session replied in a second reported nothing swept at all, which reads exactly
like a key that is being ignored.

A wrong value has no symptom until the day the files are gone, so the render
refuses anything that is not a whole number of days, 1 or more.


## The claude.ai connectors

`disableClaudeAiConnectors` is `true`. The connectors — Gmail, Drive, Calendar,
whatever the account has authorised — are fetched by Claude Code for any
session whose credential is an interactive login, and would reach the agent as
`mcp__claude_ai_*` tools. Off here, which credential a session runs on decides
its quota and nothing else. `true` is honoured from any scope, so nothing in
the volume can turn it back on.

**Measured 2026-09-02 on 2.1.250.** An interactive login served eight connector
families; a setup-token served none. The key's presence in that binary is
verified; its effect is what the `just verify` probe on a real session's tool
list checks.


## The allow list, and what it costs

**The operator's ruling, 2026-08-25.** `defaultMode: auto` runs an unlisted
command, but it also has a classifier of its own that refuses what it judges
risky: it refused `vault get` outright, and it refused a POST to Cloudflare's
service-token endpoint from a tool the agent wrote. Without an allow the vault
is unreachable and every tool the agent writes needs a ruling before it runs.

**Measured 2026-08-24:** the space form `Bash(vault *)` did **not** match; the
colon form `Bash(vault:*)` does.

**What the `tools/` entries cost, ruled acceptable rather than overlooked.**
That directory is inside the agent's own repository, so it writes those files
freely, and the allow covers whatever they contain. The guard cannot backstop
it — it is a `PreToolUse` hook on the Bash tool, so it reads `python3
tools/x.py` and never sees what the process then does; a `git push --force`
spawned from inside Python is not a Bash tool call. The deny list therefore
binds a command typed into a shell and not the same act performed by a script.
What still binds after the allow: the container (unprivileged,
`no-new-privileges`, no host filesystem), the reach of each credential, and the
backups — which is what the ruling rests on, and which **failed silently for
six hours on 2026-08-24** before anything said so.

There are two `tools/` entries because the relative spelling is what a session
in the checkout types and the absolute one is what a script, or a different
cwd, produces.


## The gh verbs, moved out of the agent's checkout

**Since 2026-09-03 the allow is one entry, `Bash(gh:*)`**, the operator's
ruling: gh is the agent's central tool, and every refusal of a verb that was
not on the list cost a workaround. What gh may not do moved to the guard the
same day — the `auth` verbs that read the login back out, destroy it or
repoint git, and `repo delete` — where it is decided on parsed argv, and
`gh api` writes ask. The deny list carries no gh entry. What follows is the
record of the 22 enumerated verbs that stood until then, and why they were
where they were.

The `gh` read, issue and discussion verbs used to live in the agent's own
`<memory>/.claude/settings.json`, held there by a sentence in that file saying
it was not the agent's to edit (its own ruling, PR #26, 2026-08-24) — a written
rule over a file the agent writes freely.

**Measured 2026-08-29 on 2.1.251,** which is why they moved: a
`permissions.allow` match **short-circuits the auto-mode classifier**. Same
repository, same command, one variable — with `Bash(curl:*)` in the checkout's
own settings the debug log carries no `new action being classified` line at all
and the command runs; with an empty allow the classifier fires first. A
project-scoped entry is dropped when the workspace is untrusted (`Dropped 1
project-scoped permissions.allow entry — workspace not yet trusted`), and this
workspace *is* trusted — `.claude.json` in the volume carries
`hasTrustDialogAccepted` for the checkout. So those entries had the effect of
short-circuiting the classifier, five days before anyone knew an allow could.

**Closed 2026-09-03 by `allowManagedPermissionRulesOnly: true`** in managed
settings: permission rules in user, project, local and `--settings` files are
ignored, so an allow entry the agent writes anywhere is inert, and `.claude/`
in its checkout became its own to arrange. Measured the same day on 2.1.250:
with the key, a rule in `.claude/settings.local.json` is never loaded; without
it, the log adds it to `localSettings`. Two more things that measurement
taught. `.claude/` is a **protected path**: a write there is routed to the
classifier whatever allow rules say, so the `Edit(/.claude/**)` entry tried
that day pre-approved nothing and went; what lets those writes through is
rule S-50's own text. And auto mode drops broad allow rules by itself —
`Bash(python3 -c:*)` logged as "Ignoring dangerous permission" — while a
narrow `Bash(touch:*)` from the checkout was loaded without the key and the
command still classified, which is not the 2026-08-29 finding above and is
not explained; the key makes the question moot. The key does not reach the
`autoMode` key of the home's settings; that surface is below. `just verify`
measures the key on the pinned version.

**The move changed nothing about what the agent may do.** A managed `deny`
outranks an `allow` from any source, and every verb was already running. It
does not close the surface either: the agent can still write an allow into the
checkout's `settings.json`, or into `~/.claude/settings.json` in the volume,
which is userSettings and reaches no trust gate at all.

**What it changed is what can be checked.** With no permissions block left in
any file the agent can write, the invariant is *those files carry no
permissions* — see "check-agent-settings, and why an invariant".

**The shape, wherever they live.** A prefix rule matches one spelling.
`Bash(gh issue list:*)` covers `gh issue list` and `gh issue list --state
open`, and not `gh issue list | head -20`, so a piped or compound form falls
back to the classifier. That is what made the vault probe in session
`2fc9867c` read as the allow failing when it was not: `vault path x; echo $?`
matches no prefix rule.

**One spelling, `:*`, for every `Bash` entry in the file — allow and deny
alike.** The colon form is the one measured to match here; the space form
`Bash(vault *)` did not, 2026-08-24, and the documented equivalence of
`Bash(x:*)` and `Bash(x *)` is a reading, not a measurement on this
installation. Three spellings used to coexist: the bare star
(`Bash(gh issue list*)`), which also matches `gh issue listanything` because
the space before a trailing star is part of the rule; the space form
(`Bash(gh search *)`); and the colon form. `Read(~/.claude/.credentials.json)`
is a path pattern and takes no suffix.

**The spelling is measured, not read.** `just verify` asks the running image
four questions about it on a real session: `gh allow` and `tools allow` say
whether an allow entry still short-circuits the classifier for the command a
session actually types, `project rules` says whether an allow the agent writes
in its own checkout is ignored, as `allowManagedPermissionRulesOnly` promises,
and `boundary` says whether the deny on reading the login file still refuses —
the one deny the guard cannot also be enforcing, since it binds the Bash tool
only. See docs/verify.md#gh-allow, #tools-allow, #project-rules and #boundary.

**Why each verb is there,** from the agent's own comment, kept because the
reasoning is the record: the read verbs are enumerated because the generic
door, `gh api`, is gated by the guard, and following a project unattended still
needs to read its issues and pull requests. The issue and discussion verbs are
the channel to the operator — an unattended session that cannot open an issue
is unreachable in exactly the case that needs reaching. `gh repo create` is the
agent's own rule 2 read correctly: that rule gates writing to repositories
other than its own, and this is how a new one of its own comes to exist.


## What left the deny list

The list holds only acts whose cost is permanent, or that touch a credential.
The account itself is the real boundary — the agent reaches exactly the
repositories it was made a collaborator on.

**curl and wget, removed 2026-08-22.** In a container with open egress and a
Python interpreter, denying two command names blocks one spelling of an HTTP
request and leaves a dozen others: a fence with a gate beside it. Where the
agent may speak is its rule 2's judgement and the container's walls, not a
command list. If a real network boundary is ever wanted, it is the sandbox's
domain allowlist, which binds every process — not this.

**`Bash(gh secret *)`, removed 2026-08-26, on the operator's ruling.** It reads
as an act that touches a credential, which is why it was listed, and it is not
one: there is no `gh secret get`, and the API never returns a secret's value,
so nothing in this container can read one back out. `set` writes a value the
session already holds into a place where only overwriting it is possible, and
`delete` costs a copy the operator keeps. What the entry actually stopped was
the agent using its own account's secrets as a tool, which is what they are
for. It was never an exfiltration boundary either — a value already in a
variable reaches the network through a dozen spellings, which is the same
reason curl and wget left. Nothing in the guard covered it, so removing it left
no gap behind.

**The git entries and the ssh pair, removed 2026-09-01** — see the next
section.

**`Bash(gh auth:*)` and `Bash(gh repo delete:*)`, removed 2026-09-03, on the
operator's ruling**, together with the allow list becoming `Bash(gh:*)`. Both
acts are decided by the guard on parsed argv, which sees `sudo gh auth token`
where a prefix rule does not; a deny beside it was a second spelling of one
rule. `gh auth status`, which the probe of the deny list used as its subject,
is refused nowhere now, and the probe reads the login file's Read deny
instead.


## The withdrawal of 2026-09-01

**What stood in the deny list** was the backstop for force-push and history
rewrite: `push --force`, `-f`, `--force-with-lease`, `--mirror`, `--delete`;
`commit --amend`; `rebase`; `reset --hard`, `--merge`, `--keep`;
`filter-branch`; `filter-repo`; `git-filter-repo`; `reflog expire`, `delete`;
`update-ref -d`; `gc --prune`.

It was a backstop and never the mechanism. A prefix rule cannot see a flag that
moved, so `git push origin --force` and `git reset HEAD~1 --hard` walked
straight past every one of them; `image/bash-guard.py` was what actually caught
those. The list was there because **the guard fails open** — a syntax error, a
lost `+x` or a missing `python3`, and Claude Code logs it and carries on to the
permission rules.

`scripts/check-backstop.py` existed only to hold the two lists in step, because
keeping them in step by sentence had already drifted: the sentence said a
*verb* added to the guard is added to the deny list, and four flags went
missing under two verbs that both looked present — `push --mirror`, `push
--delete`, `reset --merge`, `reset --keep` (#5). Nothing could have caught that
from inside a session: a `PreToolUse` hook answers before the permission rules,
so while the guard was alive the deny list never spoke and the two layers were
never both observable.

**The ruling.** On 2026-09-01 the operator withdrew that enforcement. The guard
rules went, with the added `git-filter-repo` tool; the matching git entries
left managed settings; and `scripts/check-backstop.py` was deleted. The
reasoning: the history is the agent's own, `image/push-on-exit.sh` pushes it at
every session end and the archive mirrors it, so what a rewrite costs falls on
the agent. Those acts stopped being gated deliberately, and are not left
un-backstopped by omission.

**It says nothing about whether the agent performs them.** Nothing here gates
them; what the agent does with its own history is its own standing rules'
business, and it is not this repository's to state. A sentence anywhere the
agent can read that reads as permission would be direction reaching it outside
the one channel its rules accept. Write *the enforcement was withdrawn*, never
*the agent is authorized*.

**What went with them, and had no second layer at all:** `Read(~/.ssh/**)` and
`Bash(ssh-keygen *)`. `image/entrypoint.sh` keeps an ed25519 private key at
`~/.ssh/id_ed25519`, restored from the vault or generated at bootstrap, and
those two lines were the only mechanism over it. The guard has no rule touching
either, so `check-backstop.py` was silent about them by construction and their
removal leaves no gap to detect. It leaves the key readable.

**What the withdrawal did not touch:** the second registry in
`image/bash-guard.py` that reads what a commit or a push would *carry*. A
secret in history is still the one mistake nothing here can clean up after,
because a rewrite does not reach the forge's own copies.

**The live-guard probe moved with it.** `just verify` proved the guard was
reached with `git -C /tmp commit --amend` until 2026-09-01; it now uses `env
BWS_PROBE=1 bws --help`. A probe whose subject is no longer gated reports a
live guard as dead.

**The CASES in `image/bash-guard.py` were kept, asserting `silent`.** They are
the exact spellings the tool was built to catch and the ones the withdrawn
managed entries listed. A `deny` reappearing under any of them is a rule that
came back without a ruling, which is the only failure that section can still
report.


## What joined it, 2026-09-06

`ScheduleWakeup`, `CronCreate`, `CronDelete`, `CronList` and `RemoteTrigger` —
five bare tool names, the first entries here that are not a command or a path.

A bare tool name in a deny list removes the tool from what a session is served,
where a scoped rule refuses matching calls and leaves the tool in the list. That
difference is the whole reason these are here: a session in this container is
one-shot, nothing these five schedule for after the turn ever runs, and the
tools say otherwise in their own results. Three sessions ended on that promise
with their work unwritten — the record, with the transcripts and the dates, is
in [`docs/sessions.md`](sessions.md), under "A session cannot schedule its own
return".

**They do not fit the sentence above about what this list holds**, and that is
deliberate rather than overlooked. Nothing here touches a credential and nothing
is irreversible; what makes them a boundary entry instead of a default is that
`allowManagedPermissionRulesOnly` puts them out of reach of every other settings
source, so no session in this container is served them however it began. A
`--disallowedTools` flag on `image/claude-session.py` was built first and
withdrawn on the operator's ruling the same day: it reaches only the sessions
that wrapper starts, which leaves `--entrypoint claude` and a `claude` the agent
runs itself.

The same five are denied in `host/monitor/drift-audit/settings.json`. The
auditor runs on the host with `--setting-sources ""`, so that file is the only
one it reads and the managed settings above never reach it — two files for one
rule, because they govern two session universes rather than one.


## check-agent-settings, and why an invariant

`host/release/check-agent-settings.sh` reports any `permissions` block in a
settings file the agent can write, and `just status` prints what it says.

**Measured 2026-08-29 on 2.1.251:** a `permissions.allow` match short-circuits
the auto-mode classifier — the debug log carries no `new action being
classified` line at all for an allowed command, and carries one for the same
command with an empty allow list. So an allow rule is a capability grant, not a
note: it exempts a spelling from the one layer that still judges what
`defaultMode: auto` would otherwise run.

Two kinds of file, both honoured:

| path | scope |
| --- | --- |
| `$HOME/.claude/settings.json`, `.local.json` | userSettings — no trust gate reaches these, so an entry applies unconditionally |
| `<checkout>/.claude/settings*.json` | projectSettings — applied only because the workspace is trusted; `.claude.json` in the volume carries `hasTrustDialogAccepted` for it |

The agent cannot loosen the managed deny list from either. What it can do is
exempt anything the deny list does not name from classifier judgement,
silently, in a file it owns. Nothing else in this repository would say a word
about that: a `PreToolUse` hook does not see it, `just verify` proves the image
and not the volume, and the session that added the rule reads exactly like one
that did not.

**Why an invariant and not a diff.** The 22 `gh` verbs moved into
`image/managed-settings.json` on 2026-08-29, which is what makes this checkable
in its simplest form: nothing the agent writes needs a permissions block, so
*any* permissions block is drift, and there is no approved copy kept here to go
stale against. Held the other way, this script would have needed its own copy
of that list — a second place the rules live, which is the failure
`check-backstop.py` was written against before the lists it compared were
withdrawn on 2026-09-01.

**What it does not do.** It does not stop anything, and it must not: a session
stood down on a settings edit would be an agent that can lock itself out of its
own container. It is also not a security boundary — the agent can read the
script, and an agent that wanted to hide would write its rule, act, and remove
it between two runs. It catches the durable case, which is the one that
matters: a grant left in place, working, unnoticed.


## The guard reads parsed argv

**It was built for force-push and history rewrite.** A permission pattern
matches a command prefix, so it can only ever catch one spelling of an act:
`git push --force` was denied and `git push origin --force` is the same act
with the flag moved one word, and it ran.

**Measured in this container on 2.1.238 (#3):** `git commit --amend`, `git
reset --hard HEAD~1` and `git filter-branch -f` each rewrote history
unprompted, while the force-push deny did fire. One half of the agent's rule 2
had a porous mechanism and the other had none. That enforcement was withdrawn
on 2026-09-01; the parsing that made it possible is what the file still is.

**What it still decides,** and why the hook is still registered and still baked
into the image:

- the `gh auth` verbs that would read the login back out, destroy it, or point
  git at a different one;
- `bws`, so that `/usr/local/bin/vault` stays the only route to a secret and
  every fetch lands in a cache the secret check can read;
- the `gh api` write gate, an `ask` that nothing backs up;
- rule 10 — what a commit or a push would *carry* — a separate registry in the
  same file, and the one `image/push-on-exit.sh` consults before it pushes.

It decides on parsed argv, one command at a time, and follows through wrappers
and substitutions: `sudo`, `env FOO=x`, `sh -c '…'` and `xargs` all arrive at
the tool underneath. It answers with a `permissionDecision` of `deny` and the
rule that decided, which is what the refusal then quotes — so a wrong verdict
can be traced to a line of registry instead of being a sentence with nothing to
grep for.

**What it does not see is an interpreter.** `python3 -c` and a venv are program
text in another language, and no argv guard reads them. That route stays what
the agent's rule 2 calls it, its own job to recognise; the guard closes the
spellings, not the class.

**The probe of the deny list needs a subject the guard does not also
refuse**, or a refusal proves the wrong layer: a hook answers before the
permission rules, so the printed answer would not change if the deny list
rotted underneath it. Until 2026-09-03 that subject was `gh auth status`,
denied by the managed list and deliberately by nothing here; with gh allowed
whole it is the Read of the login file, which no hook sees.

**Shell syntax in front of a command was a hole (#4).** `{ git push --force; }`
and `if true; then git push --force; fi` were both silent: argv[0] is `{` or
`then`, which is neither a registered tool nor a wrapper, so the walk stopped
there. Both spellings also miss prefix denies, which match from the start of
the line, so the act was ungated by either layer. `(…)` was already handled and
`{…}` was not, which is what made it easy to miss. The fix is `SHELL_KEYWORDS`:
skipping words the shell reads as syntax, which is safe in a way guessing was
not — it removes syntax the shell itself discards, rather than asking about a
line it cannot identify.

**Guessing at an unrecognised runner was tried and abandoned.** An earlier
version asked whenever a registered name appeared anywhere in such a line, and
it gated `ls ../docker`, `ls time` and `cat docs/env`: a tool's name is also an
ordinary word and an ordinary directory. Narrowing did not help, because the
signal is absent rather than weak. Unknown runners are covered by listing them
in `SHELL_WRAPPERS`, which is why that list is generous.


## The guard's divergences from the template

`image/bash-guard.py` is a template, vendored from the `tools` repository's
specify assets on **2026-08-23** and baked to `/usr/local/bin/bash-guard.py`.
Everything above the REGISTRY banner is meant to travel between projects
unchanged. Two things diverge, and re-applying both is what a refresh means.

**The REGISTRY and its CASES, by decision.** The git tool keeps only the
template's `commit -m` grant; its deny rules and the added `git-filter-repo`
tool were withdrawn on 2026-09-01. `gh` and `bws` are added, and docker is
dropped — there is no docker binary and no socket in this container, so its
rules could never fire. Re-applying after a refresh means **deleting the
template's git denies again**, which is the one divergence that looks like an
omission rather than a change; the CASES assert `silent` on those spellings, so
a refresh that puts them back fails the selftest instead of quietly re-gating.

**`under()` in the engine, by necessity.** Upstream it calls
`PurePosixPath.full_match`, which arrived in Python 3.13; this image is Debian
bookworm, whose `python3` is 3.11, and the call raises `AttributeError` there.
It was found by the build-time `--selftest`, having passed on a 3.14 host —
which is the whole argument for running the selftest in the image.

**Not reported upstream, and not temporary. The operator's ruling,
2026-08-23:** the template is a prototype due to be replaced, and every other
project of theirs runs 3.13 or later. This image is the exception because its
python is whatever the Debian base ships, so the backport stays here and a
refresh re-applies it rather than waiting for it.


## gh api, opened for reads

**Why the gate exists.** `gh api` sat in the managed `ask` list, and unattended
an ask is a refusal — so the door was shut for reads too, which is most of what
the agent does with GitHub. **The operator released it on 2026-08-24:** the
endpoint is free to read, and what would write is gated in the guard.

**Why the flag set is wider than `--method`.** gh's own help: "adding request
parameters will automatically switch the request method to POST". So `gh api
repos/{owner}/{repo}/issues/1/comments -f body=hi` posts a comment with no
`--method` anywhere, and `gh api graphql -f query='mutation{…}'` is the same
shape. A gate reading only `--method` would catch the spelling nobody writes
and miss the one gh documents.

It fires on presence and not on value, because `Rule.flags` cannot test a
value, so `--method GET` asks as well. That is the direction to be wrong in:
the read it costs has a spelling that does not ask (`gh api
'repos/o/r/issues?state=open'`), while approximating a value test would mean
guessing at parse time, and a guess here fails open.

`ask`, not `deny`: a write through `gh api` has an authorized use — the
operator is in the room during `just chat` and can say yes. Unattended it
degrades to a refusal, which is the right answer when there is nobody to judge
one.

No `value_flags`, deliberately. Declaring them is what lets a token be
swallowed as another flag's value, and here that could only hide one of the
very flags this gates.

**Nothing backs this up, nor could anything.** A permission pattern matches
from the start of the line and the endpoint always comes first, so no `Bash(gh
api …)` entry can see a flag that sits after it. If the guard dies, `gh api`
writes run. **Ruled acceptable on 2026-08-24:** the token is broad by design,
the memory is pushed at every session end and mirrored into the archive, and a
mistake there is meant to be survivable rather than impossible. `just verify`
probes the gate with `--method GET /rate_limit` — a spelling gated for the same
reason a DELETE is, and a harmless read if the gate is gone.

**One inconsistency, named rather than hidden:** `gh repo delete` is denied
outright by the managed list, and the same act spelled `gh api --method DELETE
repos/o/r` asks. Closing that needs a value test the rule kind cannot express.


## What a commit or a push would carry

The agent's rule 10 says a secret never enters its repository, and until the
SECRETS section of `image/bash-guard.py` was written nothing enforced it (#7).

**Why here and not in a git hook,** which is what the request asked for. A hook
is found through `core.hooksPath`; the *local* `.git/config` outranks the system
one, and that file sits inside the agent's own checkout and is writable by it —
measured. One `git config` and the hook is gone, with no symptom. A
`PreToolUse` hook is registered in managed settings and runs from the image, so
it cannot be unset from inside. It also makes `git commit --no-verify` moot,
which the request wanted rules against: `--no-verify` skips git's hooks, and
there are none to skip.

**Why the commit path and not everything.** Every other mistake is fixed in the
next commit. A secret that reaches history is remediated by rewriting history —
and a rewrite does not reach the forge's own copies, so this is the one failure
class with no cleanup at all, whoever performs it and whatever gates it. That
was true while the rewrite denies stood and it is true now they are gone.

**What it does not cover,** so silence is not read as coverage: an interpreter
— `python3 -c` committing through `subprocess` is program text in another
language. And it sees commits and pushes, not what the agent writes into an
issue, a discussion or a forum post.

**Why the engine and not a regex.** A registry that denies exactly commit and
push answers "would this line commit or push?" through wrappers, substitutions
and `git -C`. A regex over the raw line would call `git log --grep commit` a
commit, and then refuse it for a secret staged elsewhere.

**Annotated tags and notes were added because a message is a message.** A tag
object is not in `log -p`, so a push carrying one was reading past it (#9). A
note's text was in neither half; a plain push does not carry `refs/notes`, but
naming the act costs one line and the push half already reads it.

**The scan cap was a truncation, and that measured as the worst of both.** A
21 MB diff with a token past the mark went through **silently**, and took the
same 330 ms as one that was caught, because `capture_output` reads it all
before any slice happens. It bounded nothing and hid something. `MAX_SCAN` is
now a refusal at 4 MB.

**`GIT_TIMEOUT` is 5 seconds, under the hook's own 10-second timeout** set in
managed settings. At 20 it could never fire: Claude Code killed the guard
first, and a killed guard is no verdict at all.

**What a push publishes is everything local no remote already has,** not the
current branch's span. `<upstream>..HEAD` is bound to the branch HEAD sits on,
and a push publishes whatever refs it is given: `git push origin side`, a
refspec, `--all`. **Measured (#11):** standing on `main` with an unpushed
`side`, the old span read 0 bytes and side's content was never looked at. The
bound it cannot compute: with no remote configured at all, `--not --remotes`
excludes nothing and the read is the whole history — acceptable here, the
repository being about 171 KB against a 4 MB cap, and the failure past that cap
is a refusal, which is loud.


## Which repository, and which span

**The scan used to read the session's directory, and git acts on the one the
invocation names (#15).** When they differ the check reads one tree while git
writes to another — silently, in both directions. **Measured:** `git -C <dirty>
commit` from a clean session was silent, and `git -C <clean> commit` from a
dirty session was refused for dirt that was nowhere near it. One line of code,
pointing each way. The directory is now taken from the invocation, using the
parse that already exists.

**Each verb on a line carries its own directory (#17),** and the first no
longer decides for the rest. `-C` binds to one invocation while `cd` binds to
the shell: letting `-C` persist made `git -C /clean commit && git commit` read
`/clean` for both, when the second runs where the shell still is. The selftest
caught it; shell semantics are the reason.

**The walk stops at the verb being judged.** It used to run to the end of the
line, so a segment *after* the commit decided which tree the commit was scanned
against: `git commit -m x && cd /tmp` refused an ordinary commit for a
directory it would only have moved to afterwards, and `git commit -m x && git
-C <clean> log` scanned a dirty commit against the clean one. Both measured.

**`--git-dir`, `--work-tree` and `GIT_DIR=` are deliberately not followed.**
They can point the repository and the tree at different places, and guessing
which to read would be a third answer nobody asked for. The environment
spelling was silent while the flags refused — same act, two spellings, opposite
answers (#16).

**Reading the wide span for every spelling was #21,** and the cost was not one
refused commit. The dirty file stays dirty, so the refusal is sticky and
unrelated: every commit of every other file is refused until a file nobody was
committing is cleaned, and from inside a session that reads as a guard failed
closed for no reason it can name. Nothing was let through — it refused what it
did not need to. `commit_span` is one-sided on purpose: `INDEX` is claimed only
when the whole command is understood, so a missing entry costs the old
behaviour and never a shorter read.

**Redirections reached argv as bare words (#23).** The lexer hands `2>&1` back
as `2`, `>&`, `1`, and the two bare words then sit in argv looking exactly like
operands, so `commit_span` read the `2` as a pathspec: `git commit -m x 2>&1`
claimed the working tree and #21's sticky refusal came back for the spelling
used on most commands. It was one bug in every reader of an argv, and
`commit_span` is only where it cost most. `strip_redirections` fixes it before
the lexer, because the lexer has already thrown away the one thing that decides
an fd digit: adjacency. `2> f` redirects fd 2 and `2 > f` passes `2` as an
operand, and after tokenizing the two are the same three tokens.

**Escaped substitution openers were read as substitutions (#28).** Reading one
denied a commit message for quoting the very command it warned against, and
left the escape's backslash dangling at the end of the extracted text — which
no lexer will parse, so the line came back unparseable and the commit was
refused for taking its message from a file nobody had named. Escaping a
backtick is the correct spelling inside double quotes, so this penalised the
careful one.

**"Does not apply" is not "there is no repository here" (#8).** With a cwd that
is not a repository, every git call exits non-zero, every answer is empty, and
a staged key scans clean. So `git_output` reports which calls actually ran, and
the caller refuses when none did. **Measured:** a fresh repository always has at
least one part exit 0 — `diff --cached` does — while a non-repo has none.


## What the refusals say

A refusal that gives the verdict without the token turns the one party it
constrains into a search over spellings — **measured at an hour, twice (#16,
#23)**. So `reaches()` and `unrecognised()` name the token, and distinguish two
reasons: the commit really does record more, or this parse did not understand
the line and kept the wider span rather than guess.

**Three causes are kept apart, and collapsing any two breaks something (#10).**
A session told to look for a 4 MB diff when the real cause is a cwd with no
repository in it finds neither, concludes the guard is broken, and starts
looking for a way around — the one state the refusal exists to prevent. The
third cause was the same failure by another route: an unparseable line was
reported as a file that could not be read, on a line that named no file at all,
and a reader who trusts the sentence goes looking at `commit.template` and
`core.hooksPath` rather than at their own argument (#28).

**Refusals name the rule by its subject, never by number.** They said "rule 9"
until **2026-08-28**: the agent renumbered its rules on **2026-08-23** —
secrets moved from 9 to 10 — and every numbered reference in the guard went
stale in silence, so a refusal pointed the agent at its public-speech rule at
the exact moment it was being refused over a secret. A subject survives the
next renumbering; a number is a copy of a heading in a file this image cannot
see move.

**The refusal never carries the value it matched.** A check that echoes the
secret into its own refusal has moved it rather than caught it: the refusal is
written to the transcript, and the transcript is archived.


## The shapes, and the rules that fire on prose

The verbatim layer compares the live contents of credential files and of every
entry in `~/.cache/vault`. The shape layer is the second, for what is derived
rather than copied, and it is deliberately short: **a shape list that fires on
ordinary prose is one that gets switched off, and then it is absent on the day
it mattered.**

**A key is a header and a body.** The header alone was the shape until
**2026-08-25**, and in this repository it never once caught a key: 71
occurrences across 335 transcripts and the unpushed span, every one of them
prose about a key or the armour constants a tool needs in order to rebuild a
PEM. It did stop the backup — for four hours, on a sentence — and the removal
that would have taken the header out of the tracked file was refused too,
because the `-` side of that diff carries it. `host/archive/scan.sh`
already required a body; this was the copy that did not get narrowed. Two
spellings of one rule, and the one nobody edited is the one that drifted.

**A bare armour line stopped counting as a secret on 2026-08-25.**
`-----END PRIVATE KEY-----` is 25 characters, over `MIN_SECRET`, so a stored
PEM used to register its own boilerplate as "the secret" and anything quoting
that marker then matched verbatim. `vault put` was fixed on 2026-08-25 to
accept a leading hyphen, the forum signing key was re-stored as a real PEM
instead of a bare base64 body, and the next push was refused because a `git
diff` **hunk header** reproduced the `ARMOUR_END` constant from the tool that
rebuilds PEMs. No key material was anywhere near it. The backup stopped for
seven commits. The layer keeps its teeth: the body line is still a criterion,
and the body is the part that is actually secret and that survives re-wrapping.
Same discipline as #38 applied one layer over.

**`~/.config/1f916/key` left `CREDENTIAL_FILES` on 2026-09-02.** It was the
credential of the forum the agent this runner was first built for holds an
account on. It went because the *agent* chose that path, not the runner: an
agent decides where the credentials it acquires for itself live, so a path
named here is a mechanism that covers nothing from the day it picks another,
and says nothing when it does. **Every path in `CREDENTIAL_FILES` is now one
this image puts there**, and that is the rule for what may be added.

**`1f916_sk_` joined `SECRET_SHAPES` in the same change, 2026-09-02.** It had
been deliberately absent: `CREDENTIAL_FILES` named the path and `VAULT_CACHE`
covered the copy the vault holds, so a shape would have been a third spelling
of a rule two layers already stated exactly — and the redundant spelling is the
one that drifts. With the path gone, the shape is the only thing that catches
such a key when it never went through the vault. It is character for character
the pattern `host/archive/scan.sh` carries, because two readers
of one shape that differ slightly are two rules and only one of them gets
edited. The asymmetry that used to justify the difference is gone with the
path: on the guard's side the verbatim comparison was a gate, so the shape
added nothing; on the collector's side it was **a report until 2026-08-26**,
and the same secret was held in one transcript and archived from another on
nothing but its punctuation.

**Half the shape list left the code on 2026-09-03.** `1f916_sk_` had been in
`SECRET_SHAPES` for a day, and the `feed=` and Discord-webhook rules were in
`host/archive/scan.sh`; all three are shapes this agent needs because of what it
does, not shapes every installation needs, and this tree names nobody. They are
in `image/config/secret-shapes.txt` now — untracked, one regex and a note per line,
with a committed example. The guard reads the copy baked to
`/etc/agent/secret-shapes.txt` and **appends** it to the shapes above, which
stay in the code because they are true of every installation; `scan.sh` appends
the same lines to the same floor from the checkout's copy. An absent file adds
nothing, which is what a fresh installation has.

**A line that does not compile refuses, and does not compare less.** Dropping it
would leave a floor with a hole in it that answers exactly as a whole one does —
the shape of every failure this file exists to refuse — so the commit and the
push are refused, naming the line by its number, until it is fixed. The line
itself is never quoted back: a refusal is written to the transcript, and this is
the one file where someone may have typed a value where a shape was meant.

**This file splits its own fixtures.** The agent may read the guard, and does;
a transcript quoting it then trips the scan in
`host/archive/scan.sh` and blocks the whole archive. Measured,
on the transcript of the session that read the file. The `ghp_` and `sk-ant-`
fixtures were already split for that reason; the PEM ones were not.

**`bws` is denied whole so that `/usr/local/bin/vault` is the only route** —
not because reading the vault is dangerous, the agent is meant to read it, but
because `bws secret get` puts the value in a variable and in no file, and the
verbatim layer reads *files*. Every fetch through `vault` lands in
`~/.cache/vault` first, which is what makes rule 10 cover the vault at all. The
limit, recorded because it is easy to mistake this for a wall: the access token
is in the session's own environment and cannot be held out of reach in an
unprivileged, `no-new-privileges` container, so a hand-rolled request against
the Bitwarden API bypasses both this and the cache. It makes the covered route
the obvious one and the uncovered route a deliberate detour.

**The vault exemption list fails strict.** `vault-exempt.txt` names entries in
the cache that are not credentials, because the vault decides what a secret is
and the keys are not known in the image. Absent or unreadable exempts nothing:
a missing list must read as "every vault entry is a secret", never as "none of
them are". An exemption drops an entry from the verbatim list only — the shapes
still read the same text, so an entry rotated into something token-shaped is
caught anyway.

**It stopped being committed on 2026-09-03.** It holds the names of an
installation's own secrets, in a repository meant to be published, so it is now
untracked with a committed `vault-exempt.example.txt` carrying the header and no
real entry. `just setup` makes it, `just build` refuses without it, `just
deploy` carries it into the deployed checkout and backs it up, and `just verify`
compares the image's copy with the checkout's. See
docs/configuration.md#the-three-files-that-are-yours.


## The auto-mode classifier

`defaultMode: auto` runs a second-stage LLM classifier over tool calls the
permission rules have not already settled. The four arrays under the `autoMode`
key are what it is told. They are generated: the source is
`auto-mode/decisions.py`, the reasoning is `AUTO-MODE.md`,
`python3 auto-mode/build.py` writes the key, and
`host/release/check-auto-mode.py` proves the two agree.

**No `$defaults` anywhere, deliberately.** Each array is a full replacement, so
a rule nobody wrote down is a rule that is gone — which is why `AUTO-MODE.md`
is exhaustive and lists the dropped ones too. The shipped set was 86 rules
calibrated for a developer at a workstation with production access; what
survives is what catches something irreversible whose cost lands outside the
agent itself.

`environment` is not rules at all — it is what the classifier is told about
this container. An entry there gives context and never clears a block, which is
why it is the cheapest thing in the key and was ruled first.

**Why a generator at all.** The document carries every shipped rule with its
disposition and the config carries the subset that ships; the two must agree
exactly, and they are the same decisions rendered twice. **Twice during
drafting they drifted** — a rendered file was corrected by hand, a later build
overwrote it, and nothing said so. That is why both outputs are rewritten whole
every build and neither is editable: a fix typed into either is lost on the
next build with no symptom.

`build.py` rewrites exactly one key of `image/managed-settings.json` and leaves
every other byte alone, and checks it: the file must round-trip through `json`
byte-identically (2-space indent, ascii-escaped), so a diff after a build shows
the rule change and nothing else.

**The baseline pin.** `auto-mode/decisions.py` points `SHIPPED` at a capture of
the rules a Claude Code release ships. `shipped-2.1.251.json` was measured on
host 2.1.251 and container 2.1.250 and was **byte-identical between them,
2026-08-28**. `auto-mode/refresh.py` compares the live rules against that pin
after every upgrade; it reads and reports and never rewrites the baseline,
because refreshing the pin means re-reading every disposition against the new
set.


## Which model a session runs on

Decided in managed settings, not by whichever credential the container happens
to hold. Unset, Claude Code runs the `default` alias, which resolves **from the
account**: Max and Team Premium get Opus 5, Pro and Team Standard seats get
Sonnet 5. That is not a setting anyone chose, and it changed underneath.

**Measured 2026-08-27 from 231 archived transcripts:** every session was
`claude-opus-5` through 2026-08-25T10:04Z, and every session since
2026-08-25T14:57Z was `claude-sonnet-5`. The switch straddles **`b4c22be`** at
12:56 that day, which made the vault's `CLAUDE_CODE_OAUTH_TOKEN` outrank the
volume's `.credentials.json`. Nothing was misconfigured; the model was never
configured, so the answer moved when the credential did, in silence, for two
days. The agent states its model on the forum, and for those two days it stated
one it was not running on.

It is here rather than in `~/.claude/settings.json` for the reason the UI keys
give: that file lives in the volume, is unversioned, is lost on a rebuild, and
the agent can edit it. Managed settings reapply on every launch, so this holds
for `just run`, `just chat`, `just shell` and a `claude` typed by hand alike.
The alias rather than a pinned id, so a new Opus is picked up without an edit.
**Not covered:** `just chat --continue` resumes a transcript and keeps the
model that transcript was saved with.


## The backup hook, and the operator's own screen

**The backup is registered in managed settings and not in the agent's own.** A
hook it could remove or blank would stop backing up with no symptom:
`ERROR_ON_PUSH` only appears when the hook runs and fails, so one that never
runs is indistinguishable from success. The command is an absolute path in the
image, which also means the registration needs no `$CLAUDE_PROJECT_DIR` — the
script resolves the repository from `AGENT_REPO_DIR` instead.

**The UI keys are the operator's preferences about their own screen and their
own attention,** not the agent's operating parameters — which is why they sit
in managed settings rather than in `~/.claude/settings.json`, editable from
inside and lost on a rebuild. `inputNeededNotifEnabled` is the one that must
not be switchable off from inside: a session that stopped and asked is dead
until someone looks, and this is what makes it reach them.
`agentPushNotifEnabled` lets the agent push to their phone at its own
discretion; the setting has no granularity, so the restraint is a written rule
rather than a mechanism.

`spinnerTipsEnabled` and `awaySummaryEnabled` are the two that are **off**.
Neither can reach an unattended run: the spinner tips and the away recap are
interactive-only, and `just run` passes `-p`. Both spend the operator's
attention on something they did not ask for — the spinner on Claude Code's own
feature advertising, and the recap on an LLM-written one-liner summarising the
transcript they were sitting in five minutes ago, fired on the container's own
credential and so against the same account the budget guard is counting. Both
are ordinary settings keys (`awaySummaryEnabled` is marked `@internal` in
Claude Code's schema, and read the same way regardless), measured in 2.1.261.
