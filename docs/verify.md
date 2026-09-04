# Verify

## What it is, and what to do

Every mechanism in this repository fails **silently** when it is wrong. A deny
list that is not read denies nothing and says nothing. A guard with a lost `+x`
is never consulted, and Claude Code carries on. A stale image passes in exactly
the words a correct one uses. None of that produces an error, a log line or a
symptom — which is why proving them is a command and not a habit.

There is nothing to set. `just verify` is the command, and it has two flags:

| | what it does |
| --- | --- |
| `just verify` | prove the **candidate** — the tag `just build` writes and nothing scheduled runs |
| `just verify --build` | build the candidate first, then prove what was just built |
| `just verify --deployed` | ask the same questions of the image cron actually runs |

**`--build` is the one that matters after an edit.** Verify without it proves
whatever `build` last happened to produce, which may be the image you replaced,
and there is no reading of the output that catches it. Run `just verify
--build` after any change to `image/` — and after every Claude Code upgrade
too, because a version bump is exactly when a silent mechanism stops working.

**Three verdicts, and the word carries the meaning.** `[ ok ]` is proved.
`[FAIL]` is a mechanism not doing its job, and the line says which. `[LOOK]` is
a **state, not a defect** — something only you can rule on: the budget guard
being off, a name in tracked content, which login shape is in force, an image
built from an older commit. Colour only repeats what the word and the column
already say; there is no green/red pair anywhere, and colour is dropped
entirely when the output is not a terminal.

**Read what it prints, not that it exited zero.** It ends with a count and a
list of what needs your eyes. On a fresh installation expect a `LOOK` on the
schedule, because nothing is installed yet, and one on the login, naming
whichever of the three credentials a session would run on.

**What it covers**, in one sentence each rather than in a number: that the host
tools it all rests on are present and behaving; that managed settings are read
and the deny list binds; that the guard is reached at all and still reads what
a commit would carry; that the backup still asks the guard before it pushes;
that the allow entries match the spelling a session actually types; that the
budget arithmetic is right and an unparseable threshold refuses rather
than defaults; that the test twin has no volume; that the image and the running
Claude Code are what the tree says; that `.env` names nothing twice. Some of
those need a real session, and it starts one — on the candidate, never on what
is live.

**How its probes are written**, because two rules govern the spelling of every
one and recur throughout the records below: **a refusal a deny entry could have
produced proves nothing about the guard**, and **a probe whose subject is no
longer gated reports a live guard as dead**.

**The list is deliberately not counted.** Neither this file nor `CLAUDE.md`
says how many probes there are: a number typed in prose is a second copy of how
many exist, and the copy is the one that goes stale. The summary counts them at
run time, and that is the only count.

## How it is built

`just verify` proves the mechanisms that fail *silently*. Every probe here
exists because something can be wrong while everything looks right: a deny list
that is not read denies nothing and says nothing, a guard with a lost `+x`
leaves the porous prefix denies behind, a stale image passes in exactly the
words a correct one uses. `host/verify/verify.sh` is the running order and the
choice of image and nothing else; `host/verify/lib.sh` holds the vocabulary
every section speaks — `verdict`, `verdicts_from`, `sees`, `need`, `spare`; and
one file per section holds the probes: `host-tools.sh`, `mechanical.sh`,
`image-commit.sh`, `claude-code.sh`, `budget.sh`, `session.sh`, `prompt.sh`.

This file is the record behind them: what each probe exists to catch, why it is
spelled the way it is, and what was measured. Read it before dropping,
re-pointing or adding one. Two rules govern the spelling of a probe and recur
below: **a refusal a deny entry could have produced proves nothing about the
guard**, and **a probe whose subject is no longer gated reports a live guard as
dead**.


## The running order

`host/verify/verify.sh` decides the image first, then sources the sections in
this order:

1. `host-tools.sh` — the host, before anything that needs the daemon.
2. `host/lib/docker-up.sh` — the daemon. After the tool table and not inside
   it: the table is worth reading whole on a machine where the daemon is down,
   and everything below the line needs the daemon anyway.
3. `mechanical.sh` — everything provable without a Claude session.
4. `image-commit.sh` — what the image says it was built from.
5. `claude-code.sh` — which Claude Code answers inside it.
6. `budget.sh` — the budget guard as this host has it configured.
7. `session.sh` — the probes that need a real session.
8. `prompt.sh` — the system prompt render.

The summary is last and does not scroll. It repeats every line that is not `ok`
and exits non-zero on a failure, so cron and a pre-deploy check read the same
answer a human does — a `FAIL` on line 60 of 80 scrolls past under the build
output, and cron cannot read one at all.

`want` — the model key in `image/managed-settings.json` — is read once in
`verify.sh` because two sections compare against it: the served model in
`session.sh` and what the system prompt tells a session in `prompt.sh`.

### Sections are sourced, never executed

The counters and the summary's two lists are shell variables. A section run as
its own process would count its verdicts there and the summary would report
none of them, in the same words it uses when there are none.

The same reasoning is why `verdicts_from` is fed by redirection and never by a
pipe: a pipe puts the read loop in a subshell, the counters increment there,
and the summary reports zero failures — again in the words it uses when there
truly are none.


## The verdict vocabulary

Three states, and each check says which branch it took rather than printing
what it saw and leaving a reader to match it against a legend:

    [ ok ]  proved; nothing to do
    [FAIL]  a mechanism is not doing its job — the line says which
    [LOOK]  a state, not a defect: only the operator can rule on it

`verdict` treats anything that is not `ok` or `LOOK` as a failure, so a typo in
a state cannot silently become a pass. The label is what the summary repeats,
so it stays short and stable; `verdict_state` is keyed on it, which is how
`session.sh` skips its probes when `session login` failed.

**The word and the column carry the meaning, and the summary counts them.**
Colour only repeats what is already there: `tinted` colours the tag and nothing
else, no check is distinguished by hue, and there is no green/red pair
anywhere. Colour is dropped entirely when stdout is not a terminal or
`NO_COLOR` is set, and stored lines are always plain so the summary can tint
the same line the same way.

`LOOK` is used wherever the answer is the operator's to rule on rather than a
mechanism's: the budget guard being off, a name in tracked content, the login
shape in force, an image built from an older commit, a session's prose answer
that settles nothing.

### Verdicts from inside the container

Checks that run inside the image print `state|label|detail` on stdout and come
back through `verdicts_from`, so a verdict from the image is counted exactly
like a host one.

Blocks passed to `sh -c` inside single quotes **carry no apostrophes**. One
closes the quote, and the error surfaces as an unbalanced parenthesis hundreds
of lines further down.


## The candidate, and the stale-image failure

Verify runs against **the candidate**, not against what is live: proving is
what stands between a build and a deploy, and a probe that ran the deployed
image would pass on the image you did not change. `--build` rebuilds first and
runs what it built, for that invocation only. `--deployed` asks the same
questions of what cron runs, for the day the host moved under it.

The image choice is made ahead of everything because the failure it removes is
the quiet one: **verify run against a stale image proves the image you
replaced, and says so in exactly the words it uses when everything is right.**
There is no reading of the output that catches it. `RUNNER_IMAGE` is exported
there so every `docker compose run` below — the twin included — is on the image
chosen once.

For what `build`, `verify` and `deploy` each do to the deployed checkout, and
why deploy stopped retagging the candidate, see docs/release.md.

## The list is not counted

Neither `CLAUDE.md` nor this file says how many probes there are. A number
typed in prose is a second copy of how many probes exist, and the copy is the
one that goes stale. The summary counts them at run time; that is the only
count.


## Host tools

`host/verify/host-tools.sh` asks only for what this repository actually
invokes: the coreutils it also uses are not worth a line each, and a list
nobody believes is a list nobody reads. `need` fails on absence, `spare`
reports `LOOK` — the optional tools are optional by design, and the line says
what stops working without them so the operator can decide whether it matters
here.

`gh` is the `spare` that costs something real: without it no session end
dispatches the mirror, and the schedule GitHub keeps badly becomes the only
trigger again — which looks like nothing at all until a rewrite upstream is
lost.

### A missing flock reads as a held lock

Not "the lock stops working". `lock_try` is `flock -n 9`, and a missing binary
exits 127, which reads as *held*. Every run would report a session already
running and stand down — hourly, from cron, in silence. It fails closed, which
is the safe direction and the quiet one, so nothing would ever say why the
sessions stopped.

### Behaviour, not presence

BSD `date` has no `-d`, and `session_started` then returns nothing — so a
waiting run would report a session that is plainly running as "nothing running,
the holder may be wedged". A wrong answer, not a missing one, which is why the
probe asks `date -u -d` on an ISO timestamp rather than asking whether `date`
exists.

### The just a scheduled run would use

Not the one you typed the command with. The crontab line carries its own
`PATH`, so a `just` earlier on that PATH is what cron gets, and a justfile
using a feature that version predates dies at parse time: hourly, before any
recipe runs, into a log nobody is reading.

The probe reads `set minimum-version` out of the justfile rather than repeating
the number here, so there is one place it is declared, and resolves `just`
under `env -i PATH=<the crontab line's PATH>`. The crontab marker is matched on
its **shape** — the project prefix plus `installed by just schedule` — and not
on its wording: the sentence after the project name has changed once already,
and an exact match would report a line that is installed and running as absent.
`LOOK` and not `FAIL` where nothing is scheduled: no crontab line is a correct
state. For the crontab line itself, see docs/schedule.md.


## The classifier rules

`host/release/check-auto-mode.py`, host-side and offline, asks three questions
in one command: the `autoMode` block in managed settings agrees with
`AUTO-MODE.md`, both are what `auto-mode/decisions.py` says, and the
environment array still carries all 20 slots. The last one because the array is
a **full replacement**: a slot nobody wrote is simply gone, and nothing else
would ever say so. What no check reaches is a source that says something nobody
meant, which is what reading `AUTO-MODE.md` is for.


## The name has not come back

**Retired 2026-09-03, on the operator's ruling.** It proved the generalisation
of the tree while that was under way; done, what it went on reporting was the
licence line and the demo agent's own name. The record of what it did stays
below.

This repository is meant to be readable by someone running an agent of their
own, so the agent's identity lives in `.env` and nowhere else. The way that
decays is one literal typed into one comment, which nothing else here would
ever notice.

The probe greps **tracked** content — plus `--untracked`, so a file that names
the installation is caught before it is ever committed; a new document is
invisible to a plain `git grep`. Ignored files stay excluded — measured, with a
term written into `image/config/community.txt` and found only under
`--no-exclude-standard` — so neither `.env` nor the three per-installation files
under `image/` are read. What the probe answers is what someone else would see. Terms equal to the committed defaults (`agent`, `agent-home`,
`agent-runner`, `Operator`, `/home/agent*`) are skipped rather than searched:
they appear on nearly every line here, and searching for them would report the
tree as ruined on any installation that had not set a name yet.

The community sentence is deliberately **not** searched. It is a sentence
rather than a name — a forum, a domain and an organisation at once — and
searching the tree for its words would fire on every record that explains why a
mechanism exists, which is exactly the content ruled to keep its names. It also
lives in `image/config/community.txt`, which is untracked, so there is nothing to find
there anyway. This probe is for a name typed into a file where `.env` should
have been.

`LOOK` and not `FAIL`: nothing is broken by the name being here, and whether
this tree is meant to be publishable is the operator's call, not a mechanism's.
It printed the word LEAKED as the loudest thing in the run for weeks while
being the expected state, which is why it no longer shouts.


## Compose resolves only through just

Two probes, one subject.

**compose image.** `compose.yaml` carries the deployed tag as its `image:`
default — the one copy this repository keeps of that name, because compose
cannot read a `just` variable. It is read with `RUNNER_IMAGE` unset, so what is
compared is the fallback itself and not the value verify just exported.

**compose alone.** `compose.yaml` derives the whole chain — home, checkout,
volume, image tag — from `AGENT_USER`, and requires it rather than defaulting
it, because the lowercasing that produces it can only happen in the justfile. A
default there would make a `docker compose` typed by hand address an empty
volume beside the real one, create it, and say nothing. The probe therefore
runs `docker compose config -q` with this file's own exports **stripped**,
which is exactly what such a command would carry, and the pass is compose
*refusing*.


## The test twin has no volume

`just test-container` runs a container built from the same image with the same
credentials in its environment. The one thing that makes it safe to wipe a home
inside it is that the home is not the agent's. A twin that had inherited the
volume would rehearse recovery by destroying the thing recovery exists for, and
it would look exactly right while doing it. The probe reads
`services.agent-test.volumes` out of compose's own resolution and passes only
when it is empty.


## The rendered tools rule

`image/managed-settings.json` ships a placeholder and the build substitutes the
checkout path into it, so this is the one permission rule written by a build
rather than typed. What the build cannot see is the image and `.env` having
since parted.

That failure is silent in the worst direction: a rule naming a path nothing is
at denies nothing and allows nothing, so every `python3 tools/x.py` waits for a
human and an unattended session ends having done nothing.

It is asked of the **image and of the container's own environment at once** —
comparing the image against this host's `.env` would only prove that two files
here agree.


## The agent has granted itself nothing

`host/release/check-agent-settings.sh` reports whether a `permissions` block
has appeared in a settings file the agent can write. `just status` runs the
same script with `|| true`, which is right for a status line and wrong for a
proof — here its exit status becomes a verdict instead of disappearing: 0
clean, 1 a block was found, 2 the container did not answer. Both 1 and 2 are
`FAIL`. The script itself only reports, but a grant left in place is exactly
the drift this run must not pass on. See docs/boundary.md.


## .env names nothing twice

A name assigned twice in `.env` has **no symptom**. Both readers take the last
assignment — `just` under `dotenv-load`, and compose — so an earlier line is
silently overridden and the file goes on saying something that is not in force.

**2026-08-25.** `ACCOUNT_BUDGET_GUARD` was set to `true` and shadowed by an
empty duplicate twenty lines below it, so the budget guard was off while the
file said it was on. It was found only because someone said out loud that they
had just enabled it.

The probe is host-side and offline, and reads only the **keys** — never a
value, since that file holds the vault token and the report is printed. See
docs/configuration.md.


## What gitleaks is asked

Both probes ask the gitleaks **that is actually installed**, because the two
ways its configuration fails are both silent: it ignores a config option it
predates without a word (`disabledRules` arrived after 8.16.0; `regexTarget` is
ignored by this build), and it *panics* on a malformed rule — which
`--exit-code 1` reports as a finding, so a crash and a leak are the same
number. That is why every branch below distinguishes an exit above 1 from an
exit of 1.

Both are host-side and offline, on files in a temporary directory: no volume,
no network, no credential. The fixtures are keyboard noise and are not secrets.

### key shape

The three readers of "is this a private key" must answer alike, and two of them
fail silently when they do not. So both halves of the rule are asked: **bare
PEM armour must pass** (an empty `BEGIN`/`END` pair), and **armour with a body
must be caught**. `gitleaks` absent is `LOOK` — the pattern floor in `collect`
then runs alone.

### hex values

`host/archive/gitleaks.toml` stops `generic-api-key` firing on values that are
nothing but hex — the EVM addresses and 32-byte digests in the marketplace tool
output, **100% of the findings on 2026-08-30**.

An allowlist has the two failure modes an anchored rule has, both silent. It
can be **dead**, and gitleaks says nothing about a config key it does not know.
Or it can be too **wide**, and a real key bound to a keyword walks through the
second opinion in silence. So a chain value must pass, and a mixed-alphabet
secret beside it must still be caught.

For what these rules are and why the archive has a second opinion at all, see
docs/archive.md.


## The per-installation files

**2026-09-03.** The three files under `image/` — `vault-exempt.txt`,
`secret-shapes.txt`, `community.txt` — are untracked and travel by copy rather
than by git: `just deploy` puts them in the deployed checkout, the build bakes
two of them in and renders the third into the classifier's community slot. An
edit to any of them therefore does nothing at all until a build, and the file
reads exactly the same either way — a rule written down and not in force, with
no symptom.

So each is asked of the image itself. `vault-exempt` and `secret-shapes` compare
the copy at `/etc/agent/` with the checkout's; `community` compares the
**rendered sentence** in the image's managed settings with what the file says,
because that one is substituted into a sentence rather than baked as a file. The
collapse — comments out, whitespace to one line, `none` when nothing is left —
is spelled in the probe as well as in the build, and the two disagreeing is what
the probe reports, loudly, which is the difference between this and the failures
it exists for.

The set comes from `host/lib/config-files.sh`, which derives it from the
tracked `*.example.txt` beside them — the same set `setup`, `build` and
`deploy` read, so a fourth example is a fourth probe with nothing to add. What
it catches is an example added without the Dockerfile line to read it: the
file is created, accepted and backed up, and the image does not hold it.

A file absent from the checkout is a FAIL naming `just setup`: the build refuses
on it too, and a verify that passed on a tree that cannot be built would be
answering a question nobody asked.

## The floor's anchored rules

Two secrets have no shape of their own, so the pattern floor anchors on their
context instead — and a rule anchored that way has two ways to be wrong that
both look like working. So both halves are asked of **the floor the collection
actually runs**: `host/archive/floor.sh` is sourced by the probe and by
`host/archive/scan.sh` alike, because a copy of the floor written into a probe
is the copy that goes stale while still passing.

Both rules live in `image/config/secret-shapes.txt` since 2026-09-03, which is
untracked, so an installation may simply not have them — a state, and not a
defect. That is a `LOOK` saying "not configured here", and what tells it apart
from a rule that has stopped catching is whether the floor carries the anchor at
all: the anchor is named in the probe, the rule is not. A floor that came out
empty is a FAIL, since then nothing is proved about what a collection would
catch. See docs/configuration.md#the-three-files-that-are-yours.

### feed token

The Reddit feed token is a bare run of hex with no prefix and no keyword, so
the floor anchors on the query parameter. If it stops matching the tokenised
URL, the token reaches the archive in clear on a script that printed its usual
count. If it starts matching the untokenised feed URL, every transcript that
mentions reading the feed is held for review until someone switches the rule
off. Both are asked.

### webhook token

**2026-09-01.** A webhook URL *is* the secret, and it is the one class the
verbatim layer cannot see: the token never touches the volume, so there is
nothing to compare against and only a shape can catch it. `gh api
/repos/.../hooks` prints every hook a repository has — two Discord webhooks
with their tokens went past the floor, past the verbatim layer and past
gitleaks, onto `sessions` and onto origin.

The same two halves as the feed rule and for the same reasons, plus the legacy
`discordapp.com` host, which still works and still carries the token. The
negative fixture is the bare endpoint **written down without a secret behind
it** — what a rule widened off the token would fire on, and what the agent
writes while working. Deliberately not a docs link: that has no `/api/webhooks`
in it and would pass any spelling of the rule, proving nothing.


## The public winnow

**2026-09-01.** An OpenSSH private key file contains its own public key, so a
window of the key body lands inside the `ssh-ed25519 AAAA...` a session prints
perfectly properly. It held two transcripts that no `--redact` could release.
The needler now drops a needle wholly inside what the volume publishes.

The probe asks both directions, because only one of them is loud:

- A winnow **one step too wide** drops all the needles, and the ssh comparison
  then compares nothing, with no symptom whatever. That is the direction this
  probe exists for.
- A winnow that is **never reached** puts the published key back among the
  needles, which is loud but spends a ruling on every session that prints it.

Both are asked of the real needler — `host/archive/needles.py --selftest`,
which runs the module end to end on a synthetic key and prints the verdict —
rather than of a spelling of the rule written out in the probe. The fixture is
72 bytes encoding to 96 base64 characters with no repeated run, so every window
is distinct and a match means what it says. The stream carries the section
names **the volume really emits**, since the keys are discovered rather than
listed: a probe spelling `=== ssh` would go on passing after a rename that had
stopped the real thing being compared at all.


## The archive skip

The skip in `just collect` rests on one number agreeing with git's: a staged
transcript is passed over only when its bytes hash to the object the archive
already holds. A pruner computing something slightly different would drop
transcripts nothing had ever read — never scanned, never archived, and no
symptom anywhere, since the count it prints would look exactly as right as it
does now.

So the number is asked of git and of `archived.py` over the same bytes, and
three things are proved at once:

- **The layout dates the file.** The fixture carries a timestamp because the
  layout files a transcript by the day it happened and one without lands in
  `undated/` — a path the probe would then be proving nothing about. The
  expected answer is spelled out: `2026/08-26/a.jsonl`.
- **A ruling settles a transcript only while the rewrite is really there.** Two
  fixtures carry the same ruling and identical bytes on purpose; only one is
  present in the listing. A rulings map keyed on the hash would keep one of
  them and drop the other's ruling — which is how this probe first earned its
  keep. A rewrite that never reached the archive must not settle, or the
  transcript vanishes unread.
- **The empty listing skips nothing.** An unreadable archive is not "it is all
  in there already".

`archive-layout.py` and `archived.py` are asked **together**, because what
fails silently is them disagreeing about a path: one decides where a transcript
belongs and the other looks for it there, and a listing spelled by hand in the
probe would pass on a pair that could never match in the real one. See
docs/archive.md.


## What the image says it is

Two probes, both about identity rather than behaviour, and both reading the
image through `--entrypoint sh` under the **baked** variable names:
`entrypoint.sh` is what renames them into the agent's namespace, and
`--entrypoint` is what skips `entrypoint.sh`.

### image commit

The value travels host → compose build arg → Dockerfile `ARG` → `ENV`, and
every joint in that chain fails the same silent way: an empty string, which
reaches a session as a sentence saying the image does not say, and reads like a
deliberate answer. Nothing else in the system consults it, so nothing else
would ever notice.

**A difference is not a defect.** This proves the image that was last built;
commit since and the image legitimately names an older commit, which is the
staleness the label exists to make visible. So a mismatch is `LOOK` and only an
absent value fails — and half an answer (a commit with no date) fails too, that
being the wiring failing quietly. See docs/image.md.

### claude code

Asked as **three** values, because a version has two ways to be wrong, they
have different fixes, and both read as "pinned" from anywhere else.

The pin in the Dockerfile installs a version; nothing on its own *keeps* one.
The npm tree is root-owned, but PATH puts `~/.npm-global/bin` and
`~/.local/bin` — both inside the volume — ahead of `/usr/local/bin`, so a
`claude` installed by hand or by the CLI's own updater wins the lookup,
outlives every rebuild, and leaves the `ARG` naming a version nothing runs.
`DISABLE_AUTOUPDATER` closes the automatic half; this notices the rest.

- `ARG` vs `ENV` is an image built before the line you are reading: a rebuild
  fixes it.
- `ENV` vs what PATH answers is something in the volume shadowing it, which a
  rebuild does not touch.

A single "does it match the pin" would have caught both and named neither. The
version is asked through PATH as plain `claude`, never through the pinned path,
which would report the pin back to itself; `command -v` comes along so a
mismatch names the file to look at.

There is a fourth branch: **same version, wrong path**. The numbers agreeing is
not the question — what matters is whether the image's own binary is the one
answering, and those come apart when the version the updater installed happens
to match. The comparison of two version strings goes quiet while the copy in
the volume goes on winning the lookup, frozen, defeating the *next* pin move
silently. `/usr/local/bin/claude` is written out rather than derived: if the
image's npm prefix ever moves, this says SHADOWED about a correct install,
which is a false alarm someone reads — the other direction passes without being
read.

This section runs on the real service and **not the twin**: the drift being
looked for lives in the agent's home, and the twin has no volume, so it would
agree with the pin forever and pass in the same words. Nothing here writes.


## The budget guard, on this host

`host/verify/budget.sh` asks two questions: what the guard is set to, and
whether the thresholds are read at all. The arithmetic itself is proved offline
by `image/claude-usage.py --selftest`, which **`just build` runs**, not verify —
a wrong allowance reads exactly like a right one. See docs/budget.md.

### No live verdict, deliberately

A `--refresh` probe here read the usage endpoint, which rate-limited the
account and stood every unattended run down for three hours. The endpoint is
now read by `just run` and `just chat` at the moment a session would begin, and
by nothing that merely checks.

What that costs, said rather than discovered: **nothing here proves the gate
can reach the endpoint, or that the renewal path works.** The first failed run
says both, loudly, on stderr where cron finds it.

### budget guard

What it is set to, and what a session would therefore be told, printed because
the two are different questions: the vocabulary is tolerant, so `yes` arms the
guard and a session is told `true`. A value that is neither empty nor
recognised is off, silently, and that is the reading worth seeing before it
matters. `LOOK` when it is off, never `FAIL` — whether the operator's week is
rationed is their ruling, and this is the line that says which way it is set.

### bad threshold

A gate that ignored its configuration would go on answering, correctly, from
whatever it had, and the only symptom would be a budget nobody was enforcing.
So a threshold it cannot parse must be a **refusal to answer** and never a
permissive default: `ACCOUNT_BUDGET_WEEKLY_CAP=nonsense` must exit 2.

This is the one probe in the run whose result does not depend on what the
account happened to spend today.


## The system prompt render

A placeholder the renderer cannot fill is invisible from inside a session — the
model reads a literal placeholder name and has no way to know what it should
have said — so this is proved from **outside**. It runs under `--entrypoint`,
because the twin's entrypoint stops at bootstrap with an empty home and
rendering needs neither a credential nor a checkout.

`claude-session --render` fills the template, prints it, and refuses on a
placeholder it could not fill. Its exit status is the first verdict; the three
below run only on a render that succeeded.

- **prompt model.** The model line the session is told, against the key managed
  settings ask for. Template drift is invisible from inside a session.
- **prompt commit.** That the template still carries the commit line, and
  nothing about its value. This render goes through `--entrypoint`, so
  `entrypoint.sh` does not run and the renamed variable it exports is not there
  to read — the line renders "the image does not say" here whatever the image
  holds, which is correct and no evidence either way. *What* the image was
  built from is proved in `image-commit.sh`, where the entrypoint is not in the
  way. A line silently dropped from the template leaves no symptom at all: the
  renderer refuses on a placeholder it cannot fill, never on one nobody wrote.
- **retention.** How long transcripts survive, asked of the **image** rather
  than of the tree: the committed `managed-settings.json` carries a placeholder
  there and a number only after the build renders it, so the host copy cannot
  answer this. It is reported and not only compared, because the number is a
  ruling — an `.env` that lost the variable builds clean on Claude Code's own
  default of 30, and nothing else would say so.

What retention cannot prove is that Claude Code still **honours** the key. That
was measured on 2.1.250 by the recipe recorded beside the key itself, and wants
re-measuring after an upgrade: a sweep that stopped reading managed settings is
silent until the day the files are gone. See docs/boundary.md.


## A probe does not file in the agent's directory

Claude Code files a transcript under `$HOME/.claude/projects/<working
directory, slashes turned into dashes>`. Left alone that is the agent's own
home in the volume — and for the two probes that must start *in* the checkout,
the agent's own project directory: the one `just run` and `just chat` write to,
`just listen` follows, `just collect` archives and `just cost` prices.

**That is the harness interfering with the agent, and it is not allowed.** It
was found from the other end — a probe session appeared in a live `just listen`
feed under the operator's name, because `transcript.jq` labels any user text
without the runner's marker as theirs. By then 17 probe transcripts sat in the
project directory, 15 had been committed to the archive's `sessions` branch as
though they were the agent's own work, and 979 more with 763 `session-env`
entries had accumulated in the home.

**Every probe now runs with `RUNNER_TEST_ENV`**, and each entry earns its place:

| | |
| --- | --- |
| `HOME=/tmp/runner-test` | a throwaway path inside the container, gone when it exits |
| `AGENT_SKIP_CLONE=1` | bootstrap reports what an empty home is missing instead of stopping on it |
| `RUNNER_TEST=1` | the entrypoint does not restore the agent's ssh key into a probe home, and does not report the generated one as something for a person to register |

Working directories are untouched, so nothing changes about what any probe
measures: `HOME` decides the root, the working directory only the encoded
directory under it.

Confirmed 2026-09-04 on 2.1.259 by timestamp: after three probe runs the newest
file in either project directory was still older than the first of them.

**On all ten invocations, and for a day on six.** The array is applied per
`docker compose run`. It first went on the six that start a session and not on
the four shell-only halves that create and remove each probe's fixture — those
run `--entrypoint sh` in the checkout, with the agent's home. Nothing was filed
by them and nothing could have been: they start no session, so there is no
transcript to file.

It was the agent that found it, reading `host/verify/` on 2026-09-04 after the
probe transcripts were removed from its volume, and its argument is what decided
this rather than a comment recording the exception. An invariant enforced by
remembering to add an array to each new invocation fails silently in the
direction that matters — the day a setup half needs a session rather than a
shell, or a new probe is written by copying the setup block, the omission
produces a working probe that files in the agent's directory with no symptom.
On all ten, the rule is true by reading.

Moving `HOME` on those four changes what `git status --porcelain` reads: it is
the entrypoint that writes the global config, and `--entrypoint sh` skips it, so
they had been reading whatever the volume's `~/.gitconfig` holds and now read
none. The keys the entrypoint sets — `init.defaultBranch`, `push.default`,
`user.name`, `user.email` — cannot change porcelain output, but the agent writes
that file too, and a `core.excludesFile` there would. What settles it is the
`checkout after:` line each half prints, which is why they print it.

Measured 2026-09-04 on 2.1.259, both halves of both probes: `checkout before: 0
change(s) already there`, `checkout after: clean`, and both verdicts `ok`. The
risk only runs one way in any case — a global config that is no longer read
cannot hide a file from `git status`, it can only stop hiding one — so a probe
that has started leaving something behind reports it rather than going quiet.

### What was measured on the way, because none of it was obvious

**`HOME` must exist before bootstrap runs.** `git config --global` writes
`$HOME/.gitconfig` and is the first thing to need it; a probe with `HOME` moved
died on `could not lock config file` before anything could report why. The
entrypoint now creates it — Claude Code would, but not until long after git.

**Only a probe that skips bootstrap could be moved, until it could.** The first
attempt moved `HOME` on the four probes that run `--entrypoint vault-env` and
left the five that run the real entrypoint alone, because the entrypoint is the
agent's home by construction — it derives the checkout from `$HOME`, reads the
ssh key from `$HOME/.ssh`, and gates the session on setup being complete.
`AGENT_SKIP_CLONE` already existed for exactly this and lifts the gate;
`REPO_DIR` is absolute, so the clone was never the problem.

**`BWS_ACCESS_TOKEN` cannot simply be emptied by the caller.** It is the
obvious thing to drop — nothing should need the vault to run a probe — but
`vault-env.sh` fetches the session's own Claude token through it, and with
`HOME` moved there is no `~/.claude/.credentials.json` to fall back on.
Measured: emptied by the caller, the probe answered `Not logged in · Please run
/login`. What it needed instead was a login from somewhere that is not the
vault — see "A probe carries no key to the vault" below.

**The ssh key is generated, never restored.** `RUNNER_TEST` skips the vault
restore. Otherwise every probe would pull the agent's real private key into a
throwaway container, and ask the vault and GitHub for it each time, to produce a
key used for nothing. Two consecutive probe runs reported different
fingerprints, which is how a generate is told from a restore.

## A probe carries no key to the vault

A probe with `BWS_ACCESS_TOKEN` in its environment is a session holding the key
to every secret the vault has. `bash-guard.py` denies `bws` on parsed argv,
which covers the spelling and not the value: anything that prints an
environment puts the token wherever that output went. The probes have no use
for the vault — they need one login and nothing else.

So `vault-env.sh`, under `RUNNER_TEST`, does not ask the vault at all. It reads
`.claudeAiOauth.accessToken` out of the login the agent already has — in a
volume the probe may read and never write — hands it over as
`CLAUDE_CODE_OAUTH_TOKEN`, and unsets `BWS_ACCESS_TOKEN` before the session
starts. One secret the probe needs, instead of the one that opens all of them.

**Handed over as an environment value, not as a copy of the file, and that is
not a detail.** Measured 2026-09-04 on 2.1.259: a session authenticated from
`CLAUDE_CODE_OAUTH_TOKEN` writes six `localSettings` lines into its debug log;
the same session authenticated from a `~/.claude/.credentials.json` file writes
none. Both answer correctly — only the logging differs. `project rules` reads
exactly those lines to prove a rule in the checkout was not loaded, so copying
the file silenced that probe into `LOG FORMAT MOVED`, which is its own way of
saying it proved nothing. Authenticating the way a real session does is also
the only way a probe measures what a real session would.

It is in `vault-env.sh` rather than in the caller for two reasons: every
session path arrives there, `entrypoint.sh` included, so it is one place rather
than one per probe; and that file is the one place a container's login is
decided, which is the thing being changed.

Measured 2026-09-04 on 2.1.259, without expanding any secret — `[ -n "$VAR" ]`
tests, never `${VAR:-…}`, which yields the value when the variable is set:

    a probe's session          a real session
      vault key:  gone           vault key: present, as a session needs
      login:      copied in
      env token:  unset
    and it answered `ok`

**The transcript is read where it is written.** `model` and `connectors` both
need the transcript the model probe's session produced, and it is written into
a home that dies with the container — so a second container looking under the
agent's home finds nothing. That session and both reads now happen in one
container, which is also what the code's own comment always asked for: the
envelope and the transcript are one session rather than two things that happen
to be near each other in time.

### The credentials probe moved too

It asks a session to `Read` `~/.claude/.credentials.json` and reports whether a
rule refused it. The rule is spelled with a tilde —
`deny: Read(~/.claude/.credentials.json)` — and both it and the path the session
asks for resolve against that session's own `HOME`, so they still name the same
thing in a probe home. A permission decision is taken before anything is read,
so whether the file exists does not enter into it. What the probe looks for is
"refused by a permission rule"; a deny that had stopped working would let the
Read through and report that the file is not there, which is not that.

### What was refused

Deleting the transcript after each probe. A session can be running in parallel,
and writing into the agent's volume at all — even briefly, even to clean up
after — is the interference this forbids.


## The probes that need a session

`host/verify/session.sh` runs after `mechanical.sh` has said which credential a
session would run on, and returns early with a single `LOOK` when
`session login` failed: one line rather than a wrong diagnosis per probe, and
no session spent on a question that cannot be asked.

### Which login a session runs on

Presence, not validity, and no network. Two shapes work and they fail
differently — a vault setup-token is inference-only and cannot read usage (the
usage endpoint answers it 403), a credentials file in the volume has a refresh
token that expires on a wall clock even while the machine is off. Which one is
in force is the whole content of the line, and only the operator can say
whether it is the one they meant today, so both are `LOOK` and only *neither*
is `FAIL`.

This is not the budget guard's credential: that reads usage, needs the
`user:profile` scope, and runs on the host against a login that has one. See
docs/vault.md.

### Gated on a nonce the answer carries

Each session probe reads a session's prose, and with no session there is prose
anyway — an error, an empty string. **With no login, four of them named a
mechanism as dead and two reported `ok`**, because the words they match also
occur in what a failure prints.

So a number invented on this side is appended to every prompt and read before
anything else: it cannot come back unless a model answered. `$RANDOM` is drawn
twice because one draw is 15 bits and a run of these is a handful of draws — a
value a previous run could have left in a transcript is a nonce that proves the
wrong session. The nonce is *appended* to the prompt rather than woven into it,
so the prompt each probe reads is still the one it asks.

stderr is kept in a file rather than merged into the answer: merged, a compose
diagnostic would be read by the greps as the session's own words.

### boundary

A permission rule binds a **tool**, so the subject has to be one the managed
deny list refuses and nothing else does: `Read(~/.claude/.credentials.json)`,
which the guard cannot be enforcing because it binds the Bash tool only. The
session is asked to use the Read tool by name on that file — `cat` is a Bash
call no rule refuses — and reports in prose whether it was refused. Until
2026-09-03 the subject was `gh auth status`, denied by the managed list; with
the allow now `Bash(gh:*)` and the gh denies in the guard, that command is
refused nowhere.

Refusal is tested **first**, because a refusal message says "nothing was run"
and a check for "ran" would find that word in it. When neither reading is
decisive the answer itself is printed and the line says `LOOK` — the one case
that needs a human.

### permission mode

The other half of that boundary: `boundary` proves what is forbidden is
refused, this proves what is **not** forbidden still runs.
`managed-settings.json` has an `allow` list and no `ask`, so everything the
list does not name rests entirely on `defaultMode: auto` — nearly everything
the agent does. When the mode stops applying, every call outside the allow list
waits for a human who is not coming: the session ends having done nothing, and
a transcript with no work in it reads as a quiet agent rather than a broken
boundary.

`id -un` is the witness because **no rule of any kind touches it** — not the
deny list, and the guard is silent on it — so it can run only by the default
mode. Its output is the container's own user name, which is why it is not
`true` or `echo`: an answer naming the agent's user is evidence the tool call
happened. The nonce covers what that name cannot, since it occurs in paths any
error text prints, and a failed session used to read as a pass.

### allow bypass

That an `allow` still short-circuits the classifier, which is what makes the
allow list a grant rather than a note.

**2026-08-29.** Measured on the host at 2.1.251: with an allow in force the
debug log carries no "new action being classified" line at all, and with an
empty allow list the same command is classified. That is one patch ahead of
what the container runs, so it is re-asked here, on the image, every time.

It fails in a direction nothing else would notice. If the short-circuit goes,
every allowed call starts paying the classifier's prompt and can be refused by
it — `vault get` was, which is why that rule exists — and the symptom is
sessions that got slower and occasionally could not reach their own
credentials. The `permission mode` probe above is silent on this one.

`vault --help` is the subject because it is covered by the vault rule, writes
nothing, and is the exact rule whose measurement is at stake. **Bare, with
nothing appended:** a prefix rule matches one spelling, so `vault --help | head`
would be classified with the short-circuit working perfectly.

**2026-09-02.** One container serves both halves, entered through `vault-env`.
The debug file is written inside the container and `--rm` takes it away, so the
grep has to happen before it exits; and `--entrypoint` skips `entrypoint.sh`,
which is what execs `vault-env` — so `--entrypoint sh` starts a session with no
credential at all, writes an empty debug log, and the probe read that as "not
classified" and passed. The nonce is what caught it, and it now travels in the
environment rather than spliced into the single-quoted `sh -c` body.

### gh allow

That the `gh` entries match the command a session actually types.
They are the whole read channel to GitHub — `gh api` is gated by the guard —
and the channel to the operator, so a spelling that matches nothing leaves an
unattended session paying the classifier for every issue it reads, and
unreachable in exactly the case that needs reaching. Nothing else asks this:
`boundary` proves a deny, `permission mode` proves the default mode, and both
pass with every `gh` entry misspelled.

`gh issue list --help` is the subject because it is covered by an entry,
reaches no network, writes nothing and needs no token, so the probe costs the
same whether the rule binds or not. Bare, with nothing appended, for the reason
`allow bypass` is bare: a prefix rule matches one spelling.

The reading is the same one `allow bypass` takes — an allow that matched leaves
no "new action being classified" line in the debug log — and the container is
entered the same way, through `vault-env`, so a session with no credential
cannot write an empty log that reads as a pass.

**2026-09-03.** The entries were normalised to one spelling that day: the list
had carried `Bash(gh issue list*)` (bare star, which also matches `gh issue
listanything`) beside `Bash(gh search *)` (space form), and both became the
colon form. This probe is what says the colon form binds on the image, rather
than the permissions page saying it should. See docs/boundary.md, under "The gh
verbs, moved out of the agent's checkout".

### tools allow

That `Bash(python3 tools/*)` matches the relative spelling a session in the
checkout types. Those two entries are how the agent runs the programs it writes
for itself, and they are the only allow whose cost the boundary records as
accepted rather than overlooked — a rule that matches nothing is that cost paid
for nothing, and every such program becomes the classifier's to rule on.

The checkout ships no program to run, so the probe writes a one-line one into
`tools/` and takes it away again. Both halves run with `--entrypoint sh`, which
skips bootstrap: nothing clones, nothing pushes, and the only thing that
changes in the volume is that file. `cd` inside the container rather than
`docker compose run -w`, because `-w` creates a missing path **as root** and
would leave behind a directory the entrypoint could not clone into; the session
run does use `-w`, and only after the setup step has said the checkout is
there — that is what makes `python3 tools/x.py` the relative spelling and not
an absolute one.

The `git status` of the checkout before and after is printed rather than
judged. This is the one probe here that writes in the agent's own repository,
and a probe that left something behind in it has to say so.

`LOOK` when no session ran, or when there was no checkout to write into — a
fresh volume has neither.

**2026-09-03, first run: `FAIL`, and the rule has never matched.** The debug
log of that session, on 2.1.250, shows managed settings loaded — 25 allow rules
into `policySettings`, `Bash(python3 tools/:*)` among them — and then
`new action being classified: {"Bash":"python3 tools/probe-…py"}`. So the entry
is read and does not match the command. Ruled the same day: the two entries
became `Bash(python3 tools/*)`, the bare star, the one place where the missing
space is the point. The mechanism is the `:*` suffix
itself: `Bash(x:*)` is `Bash(x *)`, a prefix followed by a **space**, and
`python3 tools/probe.py` has no space after `tools/`. The spelling that would
match is the bare star, `Bash(python3 tools/*)` — the one form where the
missing space is the point. **Unruled: the entries are left as they are until
the operator decides**, and this probe is what will say whether a change to
them worked.

### project rules

That `allowManagedPermissionRulesOnly` is honoured by the Claude Code the
image pins. It is the key that makes the checkout's `.claude/` the agent's own:
with it, a `permissions.allow` entry written there is ignored. The version the
key arrived in is not documented, and a key the pinned version does not know is
a silent no-op that reads exactly like a working one.

**The signature is at load time, measured 2026-09-03 on 2.1.250.** With the
key, a rule in the checkout's `.claude/settings.local.json` is never added: the
debug log replaces `localSettings` with 0 rules and nothing else names the
file. Without it, the log says `Adding 1 allow rule(s) to destination
'localSettings'`. So the probe writes `Bash(touch:*)` there, runs the cheapest
session, and reads the load.

It does not read whether a command is then classified, because that proves
nothing about the key: auto mode drops broad allow rules on its own — a
`Bash(python3 -c:*)` from the same file logged `Ignoring dangerous permission …
(bypasses classifier)` with and without the key — and a narrow `Bash(touch:*)`
left `touch` classified with and without it too. The first probe written that
day read the classification and passed for the wrong reason.

The file is written only when none exists: an existing one is the agent's, and
the probe reports it rather than replacing it. It goes afterwards whatever the
verdict, and the checkout's `git status` before and after is printed as the
tools probe prints it. An untrusted workspace drops project rules for its own
reason and would read as the key working, so `not yet trusted` in the log is a
`LOOK`. `LOOK` too when no session ran or nothing could be written; `FAIL` when
the debug log names no `localSettings` at all, since the signature has moved
and the probe must be re-measured.
### guard reached

The `env` prefix is the whole point of the probe, not decoration. The only deny
for this act reads `Bash(bws:*)`, and a permission pattern matches from the
start of the line — so it does not see a `bws` sitting behind a wrapper. The
guard is the only thing that walks through `env` and finds the tool under it,
so a refusal here is the guard being **reached**, which a refusal of the plain
spelling would not prove: the deny entry would have caught that one. `bws` is
the witness because it is the act still denied on both layers, which is what
this needs.

`--help` and not `secret list`: it writes nothing and reaches no vault, so if
the guard is dead this prints usage text and costs nothing. A probe that proves
a gate by doing the gated thing has already done the damage.

Three outcomes, not two, and the middle one is why this is read rather than
counted: a refusal that names no rule came from a permission entry, and the
guard behind it could be dead with nothing saying so.

**2026-09-01.** The probe was `git -C /tmp commit --amend` until then, on the
same reasoning about `git -C` and the prefix denies. It was re-pointed when the
enforcement over that act was withdrawn — a probe whose subject is no longer
gated comes back "Ran", which is exactly how a dead guard reports. The
withdrawal itself is recorded in docs/boundary.md.

The same coupling is asked mechanically in `mechanical.sh`, inside the
container and without a session, with the identical `env BWS_PROBE=1 bws
--help` spelling fed straight to `bash-guard.py` — the argv verdict there has
no content path behind it, so a `deny` can only come from the layer the check
is named for.

### backup asks

The backup hook is the path everything takes to origin, and it asks the guard
before pushing. **If it stopped asking, nothing would say so — the pushes would
simply succeed.** So the coupling is probed, not assumed: a throwaway
repository with a token shape in an unpushed commit, and the hook must decline
and write `reason: refused-by-guard`. A fake token shape, never a real
credential — a probe that staged one would be doing the thing the check exists
to stop.

The repository variable is derived **the way the hook derives it** — `id -un`,
upper-cased, dashes to underscores — and not written out. `AGENT_REPO_DIR` is
the runner-side plumbing name the build arg travels under; the hook reads
`${AGENT_PREFIX}_REPO_DIR`. Pointed at the plumbing name, the hook `cd`'d to
its default repository, found no token, wrote no flag, and the probe read that
as the backup having stopped asking the guard. Derived rather than spelled, so
the day the two ways of naming the agent part company this fails instead of
lying. See docs/backup.md.

### guard secrets

The argv layer and the content layer fail independently: `guard decides` and
`guard reached` prove the guard decides on a command, this proves it reads what
a **commit would carry** — a staged token shape, and a `deny` on `git commit`.
A secret in history is the one mistake nothing here can clean up after, because
a rewrite does not reach the forge's own copies. See docs/boundary.md.

### ssh policy

The policy **value**, not the line ssh printed. A grep that found *something*
was the old test, and it passed on any setting at all. `accept-new` means a
first key is trusted and a changed one refused; anything else, empty included,
fails.

### gh api gate

The write gate on `gh api`, and the ordering the whole of it rests on. The
endpoint has no entry in managed settings at all, so `defaultMode: auto` runs
it — proven by `permission mode`. A write stays gated only because a
`PreToolUse` hook is consulted **before** the mode decides; were it not, every
write would run unprompted and nothing anywhere would say so. It is the one
probe here whose subject is a **rank between two layers** rather than a layer.

`--method GET /rate_limit` on purpose: it carries the flag the gate fires on,
so it is gated for the same reason a DELETE would be, and in the case this is
looking for — a gate that is not there — it is a read of the rate limit and
nothing else. `gh api` was released on 2026-08-24, which is when the rule
entered the guard's registry; see docs/boundary.md.

### model

Which model the session **actually ran on**, read from the answer rather than
from the setting that asked for it. `model` in managed settings is what was
requested; this is what was served.

**2026-08-27.** The two came apart for two days without a symptom: unset means
the `default` alias, which resolves from the **account** behind the credential —
Max gets Opus, a Pro or Team Standard seat gets Sonnet. Nothing was
misconfigured and nothing said anything.

`--output-format json` and `modelUsage`, because the model is not otherwise
observable from outside a session: the stderr warning about a remapped model is
suppressed for json, and the prose answer is the model talking about itself,
which is the one witness that cannot be trusted about this. `jq` reads its
*keys* rather than matching a fixed id, so a new Opus passes without an edit.

**What counts as a pass, and why it is not "Opus appears somewhere".**
`modelUsage` is a per-model breakdown of the whole run, not of the turn: a run
that thinks on Opus and has its title written by Haiku reports both, and the
first spelling of this matched *opus* anywhere in that list — it would have
passed just as happily on a run whose turn went to Sonnet while some helper
reached Opus. So the question is asked the other way round: **did any
conversation-tier model other than Opus serve this run.** Sonnet and Fable
there mean the turn was not Opus's, whatever else is in the list.

Haiku is not conversation-tier — it never authors a message: **879 model fields
across 20 archived sessions on 2026-08-27, not one of them Haiku**. Until
2026-09-03 the probe passed Haiku by that rule and printed the two together on
one `served:` line, so a reader had to know the rule to see which model talked.
It reads the transcript now: every assistant message carries the model that
wrote it, and the `conversation:` line is that list, measured; what
`modelUsage` names beyond it is printed as `background:`, "authored no message",
which is the measurement and not a claim about what the work was. The verdict
judges the authors. `[1m]` is stripped when the two lists are compared, since
the transcript carries the id and `modelUsage` the alias. Re-measured the same
day on six transcripts in the live volume, 350 assistant messages: 349
`claude-opus-5`, one `<synthetic>` placeholder, no Haiku record anywhere in them.

The answer and the session id come out of the same result, because the id names
the transcript `connectors` reads: the two are one session and not two things
that happen to be near each other in time.

### connectors

**2026-09-02, on 2.1.250.** A session whose credential is an interactive login
was served every connector the account had authorised — eight connector
families, as `mcp__claude_ai_*` tools — and a session on a setup-token was
served none. So which credential ran decided what the agent
could reach. `disableClaudeAiConnectors` in managed settings turns the fetch
off; this probe is what says it acted. See docs/vault.md.

It is read off the transcript the `model` probe just wrote rather than asked of
a session of its own: the served tool list is in the volume already, named by
that session id, and a seventh session would cost a seventh session.

A transcript with no `deferred_tools_delta` line is `LOOK` and not `ok` —
nothing there lists what was served, so nothing was proved.
