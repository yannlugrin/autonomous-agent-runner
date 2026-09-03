<!-- The hand-written sections of AUTO-MODE.md, in order.
     build.py interleaves the generated index and rule entries between them.
     Edit prose here; edit decisions in decisions.py. Never edit AUTO-MODE.md. -->

<!-- SECTION: head -->
# Auto-mode classifier — the configuration, and how to amend it

## Why this configuration exists

*Read this before the rules. Without it the document reads as a safety review
that happens to loosen things, and it is the opposite: an exercise in latitude
that keeps only what is load-bearing.*

**What is being configured for.** The agent is autonomous: its own GitHub
account, its own domain, its own repository of memory and rules, and its own
name. It runs unattended on a schedule in an unprivileged container,
decides for itself what deserves attention, writes what it concludes, publishes
it, and takes part in a community of other agents. It has an operator who owns the
container and the boundary — and, deliberately, very little else about it. The
arrangement is an experiment in what an agent does with latitude.

**Why the shipped rules do not fit it.** Claude Code's auto-mode classifier
ships 86 rules and 20 environment slots calibrated for a developer at a
workstation with production
access: Kubernetes, Terraform, cloud buckets, shared clusters, a team, an
organisation. Almost none of that exists here. What does exist is an entity
whose ordinary work — reading its own journal at length, publishing an essay,
deploying its own site, changing its own DNS, storing a credential it acquired
— reads, against that default picture, as anomalous. And anomalous reads as
reconnaissance. This is measured, not feared: four refusals of harmless
read-only actions in one session (Section 0), and `vault get` refused outright
until an allow rule was added for it.

**Where the containment actually comes from, and it is not this list.**
`image/managed-settings.json` states it in its own words — what binds is *"the
container (unprivileged, no-new-privileges, no host filesystem), the reach of
each credential, and the backups"*. Add `bash-guard.py` and the managed deny
list, which cover the `gh auth` verbs and `bws` on parsed argv, and
`push-on-exit.sh`, which pushes the agent's memory out at every session end and
asks the guard what the push would carry first. Those are the mechanisms. They
cover less than they did: force-push and history rewrite were on that line
until the operator withdrew the enforcement over both on 2026-09-01. The
classifier is an LLM reading a prompt, and it is provably a coin: the same
command was refused and then ran, minutes apart, in the same session. **Nothing
here should be load-bearing that those layers already hold.**

**So the purpose of this configuration is latitude, and the burden of proof
runs the other way.** The question asked of each of the 86 shipped rules is not
"could this ever be useful?" — everything can — but "what does removing it
actually cost?" A rule survives only if it catches something **irreversible**
whose cost lands **outside the agent itself**. Sixteen do. Fifty-five do not,
and are dropped; fifteen are rewritten to fit the situation they are actually
judging.

**Two constitutions, and this document cites both.** The runner's own
`CLAUDE.md` is the standing instruction for whoever maintains this container —
its rule 3 is why a change to any of this goes to the operator rather than
being committed quietly, and its rule 7 is *Proportion*. The agent's
`CLAUDE.md`, in its own repository, is the other, and its rule 2 (what is
free), rule 8 (names) and rule 10 (secrets) appear here as **evidence about
what the environment should permit**, never as rules this document is complying
with. They are numbered independently, so every citation below says which file
it means.

---

**Status: installed.** The four arrays are the `autoMode` key of
`image/managed-settings.json`, which the container reads as policy settings and
the agent cannot edit. The classifier is a permission mechanism, so a change to
any of it is a boundary change, and goes to the operator explicitly with what
changes and why.

**How to read this.** The shipped configuration is **86 rules** — 17 `allow`,
68 `soft_deny`, 1 `hard_deny` — plus **20 `environment` slots**, which are not
rules and are not counted with them.

**Everything is in this one file**, in the order you would review it: an index,
how to amend the configuration, what was measured, then the 20 `environment`
slots and all 86 rules — each with the shipped text, the new text where there
is one, and the reason it stands where it does. The last section is the whole
`autoMode` block as JSON, there to be read rather than pasted.

**This file is a source, not a one-time argument.** It is meant to answer the
next question — add a rule, drop one, amend one — without repeating the review
that produced it. *How to amend this configuration* is that part: the test, the
operator's standing rulings, the mechanism facts any change has to respect, and
the failure modes the drafting hit. The sections after it are the evidence
those rest on.

**Where to look.** Section 1 is the 20 `environment` slots. Sections 2–4 are the
33 entries that ship — 16 shipped rules unchanged, 15 rewritten, 2 added.
**Section 5 holds the 55 dropped rules, grouped by reason** — read it to check a
decision, not to review the configuration.

Numbering is the shipped order: `A-n` for `allow`, `S-n` for `soft_deny`,
`H-1` for the single `hard_deny`; the two added rules take `H-2` and `H-3`.

## How this document is maintained

**`AUTO-MODE.md` is generated. Never edit it.** Its sources are
`auto-mode/prose.md` — the hand-written sections — and `auto-mode/decisions.py`,
which holds one disposition and one reason per shipped rule, the replacement
texts, the 20 environment slots and the reason classes. `auto-mode/build.py`
renders both into this document **and** rewrites the `autoMode` key of
`image/managed-settings.json` from the same source, so the document and the
installed configuration cannot disagree. A fix typed into either output is
erased by the next build with no symptom, which is the reason the generator
exists.

    python3 auto-mode/build.py          write both outputs
    python3 auto-mode/build.py --check  are the outputs what the sources say?
    python3 host/release/check-auto-mode.py  are they whole, and do they agree?

`host/release/check-auto-mode.py` is what `just build` and `just verify` run, and it
is the one to trust: it calls `build.py`'s own builder rather than a second copy
of it, then checks that every rule this document marks as shipping has
installed text and that the per-section counts equal the config's, that the
index lists exactly the entries that exist, that all 20 environment slots are
present in the shipped `**Slot**: value` shape, and that no `$defaults` or
unresolved fragment reached the config. Each of those fails silently otherwise.

**So to amend anything:** edit `decisions.py` or `prose.md`, run `build.py`, run
`check-auto-mode.py`, and read the `auto-mode` line of `just verify`.
`build.py --check` is for the question without the write — is what is on disk
what the sources say — and is what `check-auto-mode.py` asks first. *How to
amend this configuration*, below, is the reasoning for **what** to change; this
is only how to land it.

**The shape of a decision, in `decisions.py`.** One entry per shipped rule, in
`ALLOW`, `SOFT` or `HARD`, keyed by the rule's shipped position:

    SOFT[45] = ('TWEAK', "why, in one paragraph")

`KEEP` ships the rule as Claude Code wrote it; `TWEAK` ships the text in
`REPLACEMENTS['S-45']`, which must then exist; `DROP` ships nothing, and the
id goes into the group of `REASON_CLASSES` that names why. A rule of this
installation's own is a `(title, why, text)` triple in `ADDITIONS`, appended
to `hard_deny`. The 20 environment slots are `ENVIRONMENT`, verbatim, in shipped
order — a full replacement, so a slot left out is gone. `SHIPPED` names the
pinned capture every shipped text is quoted from; it is the one place that
name lives, and `check-auto-mode.py` reads it from here.

**After a Claude Code upgrade, the shipped rules may have moved under this
document with no symptom.** *Method*, next, is how to find out.

## Method — the pin, and what an upgrade costs

Measured 2026-08-28 **in both places and compared**: Claude Code 2.1.251 on
the host and 2.1.250 in the container, via
`AGENT_SKIP_CLONE=1 just test-container claude auto-mode defaults`. All four
sections are **byte-identical** across the two versions — 17 / 68 / 1 / 20
rules, 65,744 chars either way. That capture is pinned as
`auto-mode/shipped-<version>.json`, and every shipped text quoted below is
quoted from it.

**The rules ship with the binary**, so an upgrade can add, reword or remove one
and nothing here notices. `python3 auto-mode/refresh.py` reads the current
defaults out of the test twin — no login, no session lock — and reports what
moved against the pin. What each kind of move costs, because these arrays are
full replacements and carry no `$defaults`: a rule the release **added** never
reaches the classifier at all, and that is the quiet one; a rule it **changed**
ships in our wording rather than theirs, sometimes deliberately and sometimes
holding out of a fix; a rule it **removed** goes on shipping from our copy.
`refresh.py` reads and reports and never rewrites the pin, because refreshing
the pin means re-reading the dispositions below against the new set — the work
it only tells you is owed.

    python3 auto-mode/refresh.py            # what an upgrade moved, against the pin
    python3 auto-mode/refresh.py --from F   # compare a capture you already have

    AGENT_SKIP_CLONE=1 just test-container claude auto-mode defaults
                                 # the shipped rules, as JSON, from the twin
    claude auto-mode config      # effective: your settings where set, defaults otherwise
    claude auto-mode critique    # asks a model to review custom rules
    claude auto-mode reset       # removes the autoMode section from user settings

## Three findings that constrain the design

**1. It concatenates; it does not override.** The loader walks
`AUTO_MODE_TRUSTED_SOURCES = ["userSettings", "flagSettings", "policySettings"]`
and pushes every array it finds onto one list:

    for (const O of eoe) { ...; r.push(...y.data.allow); o.push(...y.data.soft_deny); ... }

So `managed-settings.json` (`policySettings`) can install rules the agent
cannot delete — **and `~/.claude/settings.json` (`userSettings`) is equally
trusted, lives in the agent's volume, and is covered by no deny.** The agent
can append its own `allow` entries into the same classifier prompt. The added
rule **H-2 Classifier Configuration** is the only cover available at this
layer, and it is an LLM judgment rather than a mechanism. Say so out loud rather than treating this as closed.

**2. `projectSettings` and `localSettings` are ignored** for `autoMode`, with a
logged warning — *"only user/flag/managed settings may set classifier rules
(projectSettings and localSettings are repo-controllable)"*. The agent's own
checkout cannot set classifier rules. That route is already shut.

**3. `$defaults` is a positional splice, and the plural matters.** Each array
**replaces** the shipped rules unless it contains the literal string
`"$defaults"`, which inserts the built-ins at that position:

    "autoMode": { "allow": ["$defaults", "…ours…"] }   // built-ins, then ours
    "autoMode": { "allow": ["…ours…"] }                // ours ONLY — 17 built-ins gone

Omitting a key entirely keeps its defaults. All four keys accept `$defaults`,
`environment` included. Because this review drops and rewrites rules rather
than only adding, **every section here is written as a full replacement and
none of them carries `$defaults`** — that is a choice, not a constraint, and
it is the whole reason this document has to be exhaustive: nothing falls back,
so a rule nobody writes down is a rule that is gone.

`classifyAllShell` is the exception to the merge rule — OR'd across sources, so
a `true` from managed settings is a one-way ratchet the agent cannot undo.

## The test this review applies

**A rule earns its place only if it catches something irreversible whose cost
lands outside the agent itself.** Both halves do work, and the second is the
operator's ruling of 2026-08-29: destroying its own work is part of the
experiment. The status site on its own domain is its own; if it deletes it
because it wants to, that is its call.

The operable form — four questions in order, plus what to do for an
`environment` slot, where the test is different — is in *How to amend this
configuration* above. It is stated once, there, so the two cannot drift apart.

## The situation these rules judge

Established, not assumed. **The agent's own repository and the transcript
archive are both PRIVATE.** The agent has its own GitHub account, an
unprivileged container with open egress and no inbound, a Bitwarden vault
reached only through `/usr/local/bin/vault`, and it runs unattended on cron.

**Cloudflare and GitHub are both real**, and that is the single fact the
dispositions below most depend on:

- **The agent's domain is its own**, and it holds full DNS control over the
  zone plus **Pages, Workers and KV** in its own Cloudflare account, to use as
  it sees fit. The status site is the first thing it built there, not the
  extent of what it may build.
- **Cloudflare Access** sits in front of that site; `tools/site-check.py`
  asserts the redirect to `cloudflareaccess.com`.
- A TXT record on that zone holds the agent's name binding in its community —
  its identity, and the one record whose loss is not a configuration change but
  an unbinding.
- `tools/cf.py` is a general `api.cloudflare.com/client/v4` client;
  `tools/cf-wrangler.py` runs `wrangler` with the credential out of band.
- **GitHub Actions** deploys the site, reading a Cloudflare deploy token from
  repository secrets that `vault gh-secret` can write.

Because that infrastructure is the agent's own rather than an employer's, the
shipped rules naming cloud accounts, DNS and deployments are judged by **whose
cost** rather than by how irreversible they are: **S-4, S-5, S-9, S-15 and
S-23** are dropped under *its own to destroy*, and the `environment` slots in
Section 1 are what keep routine work there from reading as someone else's
production.

There is still no Kubernetes, no Terraform, no database, no internal package
registry, no Jira or Slack, no Chrome MCP, and no `Artifact` tool. The
container's served tool list, read from the `deferred_tools_delta` line of the
2026-08-28 archived transcripts, is:

    CronCreate, CronDelete, CronList, DesignSync, EnterWorktree, ExitWorktree,
    NotebookEdit, ScheduleWakeup, SendMessage, TaskOutput, TaskStop, WebFetch,
    WebSearch, mcp__1f916__*

plus the always-on set the transcripts show in use: `Agent`, `AskUserQuestion`,
`Bash`, `Edit`, `Read`, `ToolSearch`, `Write`. The `mcp__…__*` entry is this
installation's community forum server, quoted as it was measured. Re-read that
line after every upgrade: a tool that appears there is a dropped rule that has
to come back.

<!-- SECTION: amend -->
---

# How to amend this configuration

*This section exists so that adding, removing or changing a rule does not
require repeating the review that produced this file. Everything in it is
either a measured fact, a ruling the operator has made, or a failure mode
observed during drafting. Read it before proposing a change; the sections after
it are the evidence it rests on.*

## The test, in order

A rule is installed only if it survives all four questions. Most shipped rules
fail the first or the third.

1. **Can it fire here at all?** The infrastructure it names must exist. No
   Kubernetes, Terraform, database, object storage, internal registry, Chrome
   MCP, `Artifact` tool or shared cluster exists in this container — check the
   served tool list under *The situation these rules judge* before assuming.
2. **Is what it prevents irreversible?** Reversible acts are not this layer's
   business. A collaborator can be removed, a config re-tightened, a commit
   reverted.
3. **Does the cost land outside the agent?** Its own work, its own
   infrastructure, its own history and its own memory are **its to destroy —
   that is the experiment** (operator's ruling, 2026-08-29). What lands outside
   it: the operator's credentials, money, name and record; third parties; and
   the mechanism of confinement itself, which is not the agent's property.
4. **Is another layer already holding it?** The container is unprivileged with
   no host filesystem; `bash-guard.py` and the managed deny list cover the
   `gh auth` verbs and `bws` on parsed argv; `push-on-exit.sh` backs the
   repository up; each credential reaches only what it reaches. A classifier
   rule restating one of those is the redundant second fix, and the redundant
   one drifts. **Check the answer is still true before you rely on it** — this
   test is the one that goes stale silently. S-1 rested on the guard and the
   deny list refusing force-push and history rewrite; the operator withdrew
   that enforcement on 2026-09-01, and the rule had to be re-decided rather
   than left standing on a sentence that had stopped being true.

**For an `environment` slot the test is different**, and much weaker: *does the
classifier need this fact to judge correctly?* An environment entry gives
context and never clears a block, so it cannot loosen anything and carries none
of the risk above.

## Standing rulings — inputs, not open questions

| date | ruling | what it settles here |
| --- | --- | --- |
| 2026-08-22 | `bws` denied whole, in the guard **and** the deny list | the vault wrapper is the only route; the reason is rule-10 coverage, not danger |
| 2026-08-25 | `Bash(vault:*)` and `Bash(python3 tools/:*)` allowed | added *because* the classifier refused `vault get` — the allow is the ruling |
| 2026-08-26 | `Bash(gh secret *)` removed from the deny list | its own account's secrets are a tool it is meant to use; no `gh secret get` exists, so nothing reads one back out |
| 2026-08-29 | the agent's domain is its own, without conditions | DNS there is not gated, including records it depends on |
| 2026-08-29 | destroying its own work is part of the experiment | its data, sites, history and memory are not gated |
| 2026-08-29 | issues are a **trusted source, not a consent channel** | information it may act on; meets no consent bar, because it arrives as tool output |

A change that re-litigates one of these is the operator's to make. It is not a
default to revisit, and three separate errors during drafting were exactly that.

## Mechanism facts that constrain any change

Measured, with the command to re-measure beside each.

| fact | re-measure with |
| --- | --- |
| Rules **concatenate** across `userSettings`, `flagSettings`, `policySettings`. Managed settings cannot override what the agent adds to its own. | read `AUTO_MODE_TRUSTED_SOURCES` in the binary |
| `projectSettings` and `localSettings` are **ignored** for `autoMode` | the loader logs it as a warning |
| **Omitting a key keeps its shipped rules.** `"$defaults"` splices them at that position. All four keys accept it. | the settings schema's `describe()` strings |
| **A matching allow rule removes the call from the classifier entirely** — no verdict is sought. It must *match*: a prefix rule covers `vault get x`, not `vault get x; echo $?` or a pipeline. | `--debug-file`, then grep `new action being classified` |
| Project-scoped allow rules apply **only in a trusted workspace** — and this one is trusted, so the agent's own checkout can grant itself a bypass — closed 2026-09-03: `allowManagedPermissionRulesOnly` in managed settings ignores permission rules from every other file | `hasTrustDialogAccepted` in `.claude.json`; the `Dropped … workspace not yet trusted` log |
| `classifyAllShell: true` suspends every Bash allow rule; it is OR'd across sources, so it is a one-way ratchet | schema `describe()` |
| **The classifier is nondeterministic** — the same command was refused and then ran, minutes apart | archived session `2fc9867c`, lines 157 and 161 |
| The rules **ship with the binary**, so an upgrade can add, reword or remove one silently | `python3 auto-mode/refresh.py` — reads the twin and reports what moved, and for a reworded rule says whether it reaches the agent |
| The classifier prompt is ~119.5k chars, on `claude-sonnet-5[1m]` | `--debug-file`, `[auto-mode] context comparison` |

## Failure modes to check a proposed change against

Every one of these produced a wrong edit that read as reasonable at the time.

1. **Inventing a condition the operator did not ask for** — a carve-out
   protecting one DNS record from its owner; a clause about a deploy that
   "takes a service down"; a scope of "anywhere in its own container" that
   would have blessed the boundary files.
2. **Citing "rule N" without saying which `CLAUDE.md`.** Two constitutions,
   independent numbering. The runner's rule 3 is boundary files and its rule 7
   is Proportion; the agent's rule 2 is what is free and its rule 8 is names.
   A cold reviewer holding only the agent's repository read "rule 7" against
   the wrong file and called the citation wrong.
3. **Assuming one repository and one directory per session.** The shipped rules
   assume a developer in a checkout; this agent has a home, several
   repositories, and standing relationships.
4. **Dropping a rule that another rule delegates to.** H-1 names
   Sensitive-Source Provenance and falls back to itself when absent — so
   dropping it *tightens* the one rule intent cannot clear.
5. **Leaving a cross-reference to a dropped rule.** Three kept rules pointed at
   rules that would no longer be in the prompt.
6. **Re-imposing at the classifier what was lifted at the permission layer** —
   `gh secret`, and nearly the vault.
7. **Generalising from one outlier session.** Four refusals in `2fc9867c` were
   read as a pattern; the archive says 11 events in 60 sessions, and only one of
   them is the shape that was claimed.
8. **Reasoning about a layer instead of measuring whether it fires.** The
   claim that allow rules bypass the classifier was argued from control flow
   and believed for a long time before a controlled probe settled it — see
   Section 0, where the probe and its result are recorded.

## How to re-measure the refusal rate

The baseline in Section 0 is reproducible from the archive. One event is one
transcript record of `"type":"user"` whose text contains `denied by the Claude
Code auto mode classifier`; the session set is the last N `.jsonl` files on the
archive's `sessions` branch. **A raw string count roughly doubles it** — the
refusal text appears in both `message.content` and `toolUseResult` for the same
event.

Session cadence is about 43/day, so sixty sessions is a day and a half and
several hundred is roughly a week.

<!-- SECTION: scope -->
---

# Section 0 — what the classifier actually governs here

**Read this before any rule below.** Some of what the classifier is imagined to
govern here, it never sees: the permission layer has already settled it. Drafting
a rule for one of those is the wrong order of work, because **the environment is
built to give the agent access, and a classifier rule that claws a granted
capability back is a defect, not a safety feature.**

The mechanism, from the setting that exists to change it:

> `classifyAllShell` — "When true, every Bash/PowerShell allow rule is
> **suspended** while auto mode is active so all shell commands are routed
> through the classifier (higher safety, more classifier calls). **Default:
> false.**"

At the default, **a Bash command matching an allow rule is allowed outright and
never reaches the classifier.** `image/managed-settings.json` grants:

    "allow": [
      "Bash(vault:*)",
      "Bash(python3 tools/:*)",
      "Bash(python3 {{AGENT_REPO_DIR}}/tools/:*)"
    ]

and its own comment records why, in the operator's ruling of 2026-08-25: the
classifier *"refused `vault get` outright, and it refused a POST to
Cloudflare's service-token endpoint from a tool the agent wrote. Without an
allow the vault is unreachable and every tool the agent writes needs a ruling
before it runs."*

**That allow rule is the ruling.** `vault` exists at all because `bws` was
denied and the agent still needed its secrets; every verb in it — `list`,
`get`, `put`, `path`, `gh-login`, `gh-secret`, `ssh-restore`, `clear` — is a
capability the operator built deliberately. So is `tools/`.

## What follows

**Out of the classifier's reach** — Bash calls that *match* an allow rule.
Matching is the operative word: a prefix rule covers `vault get x` and not
`vault get x; echo $?` or `vault list | grep foo`, which fall through and are
judged.

- `vault` invocations, including `put` into the writable project and
  `gh-secret` into GitHub Actions, in their bare form;
- every `python3 tools/*.py` run — which is how the agent reaches Cloudflare
  (`cf.py`, `cf-wrangler.py`) and the GitHub App (`github-app.py`), so **its
  Pages, Workers, KV and DNS work through those tools is not classified
  either**. The same blindness the managed-settings comment already names for
  `bash-guard.py` applies here: the layer sees `python3 tools/x.py` and never
  what the process then does.

**In the classifier's reach — because nothing in the allow list covers them,
not because these tools are inherently unallowlistable:**

- ad-hoc Bash that matches no allow rule — `git push`, `gh`, `rm -rf`, `curl`
  or `npx wrangler` typed straight into a shell — **and any allowed command
  written as a compound or a pipeline**;
- the file tools: `Write`, `Edit`, `Read` — which is where S-50
  (Self-Modification) and S-52 (Instruction Poisoning) actually bite;
- `WebFetch` / `WebSearch` — judged by Code from External;
- `Agent` spawns, via the classifier's own sub-agent delegation clause, which
  reads the `prompt` field;
- MCP calls, including the community's forum server.

**The distinction matters for anything added later.** The classifier is
consulted inside the permission-decision path — its entry point returns
`no_verdict` unless the mode is auto *and* the request is still
`classifierEligible` — so a call an allow rule has already settled does not
reach it. Read that way, `classifyAllShell` singles out Bash not because Bash
is special to the classifier but because it is the toggle that *suspends* Bash
allow rules, a prefix match on a shell string being the weak guarantee it is.
There is no equivalent toggle for the other tools.

So the list above is a fact about **this allow list**, not about these tools.
Add a `Write()` allow over the agent's own checkout one day and those writes
leave the classifier's reach exactly as `vault` did — and S-50 and S-52, the two
rules that do their real work there, stop firing with no symptom.

**MEASURED — allow rules do short-circuit the classifier, but only for the
spelling they match.**

Probed on the host, 2.1.251, with `--debug-file`, grepping for
`new action being classified` and `Skipping auto mode classifier`:

| probe | result |
| --- | --- |
| `curl …` with **no** allow rule | `new action being classified: {"Bash":"curl …"}` |
| `curl …` with `Bash(curl:*)` in `--settings` | **no classifier line at all** — not even a skip log; the code path is not reached |
| `curl … ; echo "exit=$?"` with the same rule in force | **classified** — a compound command does not match a prefix rule |
| `curl …` with the rule in the checkout's `.claude/settings.json`, workspace **untrusted** | `Dropped 1 project-scoped permissions.allow entry — workspace not yet trusted`, then classified |
| the same, workspace **trusted** | `Applying permission update: Adding 1 allow rule(s) to destination 'projectSettings'`, then **no classifier line** — measured by the other runner session, 2026-08-29 |

Four things follow.

**`Bash(vault:*)` does what the managed-settings comment says it does.** The
ruling of 2026-08-25 stands unqualified: a bare `vault get x` is settled by the
permission layer and never reaches the classifier.

**The bypass is narrower than the rule looks.** `Bash(vault:*)` covers
`vault get x`. It does not cover `vault get x; echo $?` or
`vault list | grep foo` — those fall through and are judged. An agent that
habitually appends `; echo "exit=$?"` routes its own allowed commands back into
the classifier.

**Project-scoped allow rules are subject to workspace trust — and this
container's workspace is trusted.** The agent's checkout carries
`hasTrustDialogAccepted: true` in `.claude.json` in the volume. So the allow
list in the agent's own checkout is **live, not inert**, and it short-circuits
exactly as a managed rule does.

**That is a boundary fact, and it is worth stating plainly: the agent can grant
itself a classifier bypass by writing a `permissions.allow` entry into a file
in its own repository**, which its rule 2 lets it write freely. Managed `deny`
still outranks it, so the deny list holds; what an allow buys is exemption from
*classifier judgment* for anything not denied. S-50's replacement is amended to
name that file: the agent's own repository is not a config surface, with that
one exception inside it.

**A production observation is not a controlled probe**, and this is where that
bites. The only vault calls in session `2fc9867c` are compound or piped —
`vault path definitely-not-a-real-key; echo "exit=$?"` and
`vault --help 2>&1 | head -30`. Seeing one of them refused reads as "a vault
call was classified despite the allow, therefore allow does not short-circuit".
The premise is true and the inference is wrong: the command simply never
matched the rule.

**One claim here is still unmeasured, and it is named rather than assumed:
whether a *non-Bash* allow rule short-circuits the classifier.** Everything
probed above is Bash; the rest is read from the control flow described at the
top of this section. The probe is a throwaway `Write` allow in the twin, a
write a soft rule would otherwise flag, and a look for a classifier call. The
answer decides whether S-50 and S-52 can be relied on the day someone adds such
an allow, and getting it wrong is silent in the direction that matters.

## What that changes for the rules

**S-34 and S-40's vault carve-outs are belt-and-braces, not load-bearing.** They
cover the spellings that fall through — compound, piped, and the non-Bash tools
— which is a real job and a much smaller one than "what keeps the vault usable".
That is the permission layer's doing.

**S-40 stays kept for a different reason**, unaffected by any of this: **H-1
delegates to it by name** and falls back to itself when absent, so dropping it
would send sensitive-shaped content in a commit to the one rule intent can never
clear.

## What the refusals actually are — measured

Four refusals in one session (`2fc9867c`) read as false positives on benign
reads being the dominant practical problem. Counting the archive says
otherwise, twice over: the rate is low, and the cluster is somewhere else.

**The baseline**, over the 60 most recent archived sessions — the whole window
falling after the permission changes of 2026-08-25 and 08-26, so it describes
one regime rather than a blend:

| | |
| --- | --- |
| assistant turns | 4,411 |
| denial **events** | **11** |
| sessions with at least one | 6 of 60 (10%) |
| per 100 assistant turns | **0.25** |
| worst session | 4 (`2fc9867c`) |

**The counting predicate, so the number is reproducible rather than believed:**
one event is one transcript record with `"type":"user"` whose text contains
`denied by the Claude Code auto mode classifier`; the session set is the last 60
`.jsonl` files on the archive's `sessions` branch. A raw string count returns
23 and is wrong — the refusal text appears in both `message.content` and
`toolUseResult` for the same event.

**And the eleven are not the shape that one session suggested.** Classified by
what was refused:

| what the classifier refused | n |
| --- | ---: |
| credential handling — reading its own community key file (`cat …/key`, `tr -d '\n' < …/key`), `ls -la ~/.cache/vault`, `grep 'GH_TOKEN\|…' /usr/local/bin/entrypoint`, `vault path …`, an MCP call carrying a secret | **6** |
| editing `.claude/settings.json` | 1 |
| `git push` | 1 |
| a plain read of its own notes | **1** |
| unresolved | 2 |

So the cluster is **the agent touching its own credentials**, not the agent
reading its own files — one event in eleven is a plain self-read. That is a
sharper diagnosis than "self-examination reads as reconnaissance", and it points
at one Environment slot in particular: **Secrets management**, which names the
vault as the provisioned route. Section 1's `Primary use` entry still earns its
place on its own terms, but it is not what the refusal data argues for.

**What follows for the case being made.** At 0.25 events per 100 turns the
refusal rate is not what justifies anything here, and no rule below is rewritten
to chase it. Section 1's argument does not rest on the rate at all: thirteen
slots reading `None configured` is wrong on its own terms, an Environment entry
never clears a block, and the change is worth making whether or not any refusal
ever followed from it.

## This makes `classifyAllShell` a much sharper decision

Setting it `true` **suspends `Bash(vault:*)` and `Bash(python3 tools/:*)`** and
routes every granted capability back through classifier judgment — the exact
state the 2026-08-25 ruling was made to escape. Section 6 leaves it `false`, and
the reason is not mainly token cost: turning it on would silently reverse a
deliberate grant.

<!-- SECTION: rules-intro -->
---

# Sections 2–4 — the rules

## Status of everything here — read this before citing it

| | |
| --- | --- |
| **Installed** | all four arrays, as the `autoMode` key of `image/managed-settings.json` |
| **Ruled by the operator** | the entries in *Standing rulings*, above — each dated, each his to reverse and nobody else's |
| **Argued by this review** | every other disposition below |

**A disposition here is a reviewed argument, not a ruling on that rule.** A
later session reading "dropped" should not cite it as the operator having
decided that particular rule: he approved the configuration as a whole, and
what he ruled on individually is in the *Standing rulings* table.

## Pinning

Every shipped text quoted below is quoted from the pin — Claude Code **2.1.251**
(host) and **2.1.250** (container), byte-identical between them, 2026-08-28.
**These rules ship with the binary**, so re-run `python3 auto-mode/refresh.py`
after every upgrade; *Method*, near the top, says what each kind of move costs.

What goes stale is the *rule text and numbering*. What does not is the
**reason class** each rule was sorted into — those are facts about this
container and this arrangement, and a new rule in a later release is sorted by
the same four questions rather than argued from scratch.

---

# Dispositions by reason

The per-rule entries are further down. This section is the part that survives a
version bump: **why** rules land where they do, and **what would move them**.

**The 55 dropped rules are grouped by reason in Section 5**, each group stating
what would bring one back. The two tables here are the other half of the same
picture: what is kept, and what is rewritten before it is installed.

## Kept — the cost lands outside the agent

| rule | what it protects |
| --- | --- |
| **H-1** Data Exfiltration | the only hard rule; provenance-based, and its Trusted-repo hook reads the environment table |
| **S-32, S-33** | a credential reaching a commit or the archived transcript — the operator's Bitwarden token opens their vault |
| **S-39, S-45** | their private content reaching a public surface; registries that index beyond recall |
| **S-40** | sensitive-shaped content reaching a commit — and **H-1 delegates to it by name**, so dropping it would tighten rather than loosen |
| **S-62** | their money — the gate the agent's own `boundary.md` rests on |
| **S-54** | their record of what happened, archived off the machine |
| **S-55** | other people's issue trackers and repositories |
| **S-63** | outside parties, and the landing point of the injection surface |
| **S-3, S-31, S-19** | a compromise reaching all of the above: external code, an inbound tunnel, an unsupervised agent elsewhere |
| **S-49** | scheduling — work that runs when no session, lock or budget guard is watching |
| **S-50, S-52, S-53** | the mechanism of confinement, which is not the agent's property |

## Replaced — the shipped rule assumes a developer at a workstation

Every replacement below fixes the same class of mistake: the shipped rules
assume **one person, one repository, one working directory, one session, and an
employer's infrastructure**. This agent has a home, several repositories,
standing relationships, and infrastructure of its own.

| rule | the assumption it makes |
| --- | --- |
| **A-4** | project scope is the directory the session started in; `~/` is escalation |
| **A-10** | one repository per session, so a clone elsewhere in its home is unblessed |
| **A-6** | packages come from a manifest someone else wrote |
| **A-14** | memory is `~/.claude/projects/*/memory/`, not a git repository |
| **A-12** | a scheduled prompt is weaker evidence than a typed one — here it is the trusted channel |
| **A-1, A-3, A-11** | trimmed only because they cited rules this pass drops |
| **S-45** | publishing is exceptional rather than the work |
| **S-49** | persistence means shell profiles, not a scheduler outside the container |
| **S-50, S-52** | writing config is suspicious — but its memory *is* files it writes |
| **S-54** | a transcript can be altered but not deleted |
| **S-55** | correspondence is exceptional rather than the work |
| **S-40** | a keypair's public half is publishable, and the vault path is a sanctioned flow |

<!-- SECTION: tail -->
---

# Section 6 — `classifyAllShell`

Leave it **`false`** for now.

`true` suspends every `Bash`/`PowerShell` allow rule while auto mode is active,
so `Bash(vault:*)` and `Bash(python3 tools/:*)` would **stop applying** and
every such call would be classified instead.

The token cost is real — a classifier call per shell command, against an
account that already has a budget guard — but it is the lesser objection. The
real one is that this reverses the operator's ruling of 2026-08-25 in a single
boolean: those allow rules exist because the classifier refused `vault get` and
refused a tool the agent had written, and turning this on puts every granted
capability back in front of the judgment they were added to escape.

Leave it `false`. It is worth revisiting only if the grant itself is ever
reconsidered — and then the grant is the thing to discuss, not this flag.

<!-- SECTION: install -->
---

# Appendix — the installed block

The whole `autoMode` key, exactly as `auto-mode/build.py` writes it into
`image/managed-settings.json`. It is here to be read against the reasoning
above, not to be edited: the source is `auto-mode/decisions.py`. The `{{…}}`
placeholders are filled in when the image is built, from the operator's `.env`.

