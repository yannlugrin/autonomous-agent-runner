# The archive

## What it is, and what to set

A session leaves its transcript inside the container's volume, where Claude
Code deletes it again after `AGENT_TRANSCRIPT_RETENTION_DAYS`. The archive is
the copy that lasts: a **private repository, separate from the agent's own**,
holding one transcript per session, the host's status snapshot, and a mirror of
the agent's memory. It is what makes the record of what the agent did outlive
the volume — and outlive a memory repository the agent is free to rewrite.

The other half of it is a gate. A transcript carries every command's output
verbatim, so it is the likeliest place in this system for a credential to
appear, and a credential that reaches a forge cannot be taken back — a rewrite
never reaches the forge's own copies. So nothing is published before it is
scanned, and what does not pass is **held back and named**, never redacted on
the machine's own judgement.

| handle | what it does |
| --- | --- |
| `AGENT_ARCHIVE_REPO` | `owner/name` of the archive. Nothing can derive it — the archive is usually not the agent's own account — and without it `collect`, `read`, `sessions` and `mirror-status` say so rather than guessing |
| `AGENT_ARCHIVE` | where that clone sits. `archive/` inside this checkout unless set, gitignored, made by `just setup-archive`; a relative value counts from the checkout, not from where `just` ran |
| `AGENT_ARCHIVE_WORKFLOW` | the mirror workflow's file name **in the archive**. `mirror-<agent>.yml` unless set; nothing here renames that file |
| `AGENT_ARCHIVE_MIRROR_COOLDOWN` | minutes before a session may ask the mirror to run again. Unset or unreadable means every session asks — a cost knob, where the direction with no undo is a mirror that did not run |
| `just setup-archive` | once: clone the archive and write the two secrets its mirror workflow runs on, on your own `gh` credential. The agent is told none of it |
| `just collect` | read the transcripts out of the volume, put them through the gate, commit what passes. `--push` publishes, `--held` lists what is held back, `--approve <hash> "why"` archives one as it stands, `--redact <hash> "why"` archives it with the credential rewritten out |
| `just sessions` | what the archive holds, newest first. `--all`, `--day D` |
| `just read <n>` | one row of that listing, whole |
| `just mirror-status` | whether the memory's mirror is enabled, current, and whether anything upstream was rewound. It only reads |
| `just publish-status` | the host's half of the status page, onto the `status` branch. `--now` ignores the ten-minute floor |
| the `config` branch | this installation's own three files under `image/`, written by `just deploy` once a deploy has succeeded and read back by `just setup --restore`. Nothing is typed at it |

**The rule.** The collection runs on the **host**, reading the volume from
outside through a throwaway container, so nothing the agent executes can shape
it. Each branch has exactly one writer: `sessions` and `status` are written
from here, `config` by `just deploy`, and `refs/archive/<agent>` — the memory's
mirror — only by a workflow inside the archive. Three layers ask whether a transcript carries a
credential: a floor of anchored shapes, a **verbatim** comparison against the
values the volume's own vault cache holds, and `gitleaks` as a second opinion.
A hit stops the run. A ruling names the transcript by its hash, goes into the
same commit as the transcript, and is remembered, so nothing is judged twice.

**Day to day you type nothing.** `just run` ends by calling `just collect
--push` itself, and `just status` says how many transcripts the gate is
holding. By hand, `just collect` commits and does not publish. When something
is held, `just collect --held` names the file and says **where** the credential
appears, in words rather than by printing it; you then `--approve` or
`--redact` it with a reason, and the reason is what the archive records.

**What it refuses.** It will not redact quietly — silent redaction hides the
incident, which matters more than the file does. It will not accept a ruling
that names nothing the run is holding, rather than applying it to whichever
file came first. And a shape rule that fires on ordinary prose is dropped
rather than kept: a gate that cries wolf at every collection is a gate somebody
switches off, and then it is not there on the day it matters.

## How it is built

Every session the agent runs leaves a transcript in the volume. `just collect`
reads them from the host — never from inside the container — puts them through
a credential gate, and commits what passes to `sessions`, an orphan branch of
the archive repository. A second orphan branch, `status`, carries the snapshot
`just status` renders. A third record, `refs/archive/<agent>`, is a mirror of
the agent's own memory repository, written by a workflow in the archive and
read by `just mirror`.

The host side lives in `host/archive/`: `collect.sh` and the six stages it
sources — `read-volume.sh`, `ledger.sh`, `scan.sh`, `rule.sh`, `report.sh`,
`archive.sh` — with the six Python programs the gate is made of beside them
(`needles.py`, `shapes.py`, `check.py`, `redact.py`, `passages.py`,
`findings.py`), `archive-layout.py` and `archived.py` (where a transcript
belongs, and whether the archive already holds it), `gitleaks.toml` (the second
opinion's config), `status-collect.py` and `publish-status.sh` (the snapshot and
its branch), `sessions.sh` and `session-meta.jq` (the listing), `mirror.sh` and
`dispatch-mirror.sh` (the mirror's health, and asking it to run), and `setup.sh`
(the clone and the mirror's credentials). `host/lib/archive.sh` holds what the
read-only recipes share.

Three properties hold the whole thing up, and every record below is in service
of one of them: the collection runs on the host, so nothing the agent executes
can influence it; each branch has exactly one writer; and a credential that
reaches origin cannot be taken back, so the gate stops the run rather than
redacting quietly.


## The stages of a collection

Until 2026-09-02 the whole collection was one file, `collect-transcripts.sh`,
1766 lines of which about 740 were Python written to temp files as heredocs and
run — `NEEDLER`, `REDACTOR`, `SHAPER`, `CHECK`, `CONTEXT` and `RULES`. None of
that Python was visible to ruff or mypy, none of it could be imported or tested
on its own, and `just verify`'s public-winnow probe had to awk-scrape the
needler back out of the shell to run it.

It is now `collect.sh` — the flags, the paths, the staging directory and its
cleanup — sourcing six stages in the order they run:

  * `read-volume.sh` — the transcripts out of the volume, the volume's own
    secrets in, and the layout map saying where each transcript belongs.
  * `ledger.sh` — where `sessions` is for reading, and what has already been
    ruled on. The writing half is in `archive.sh`, because an entry goes into
    the same commit as the transcript it rules on.
  * `scan.sh` — the pattern floor, `detect()`, gitleaks, the fingerprint and
    the skip, and the list of what the gate objects to.
  * `rule.sh` — what `--approve` and `--redact` resolve to, the `--held` count,
    the redaction and its proof.
  * `report.sh` — the held-back report, one per file, and what the run read.
  * `archive.sh` — the worktree, the placing, the ledger, the commit, the push.

**Sourced and not run.** The stages share one shell's variables because they
are one collection: the volume's secrets are read once and kept in the process,
never written to disk, and handing them between processes would undo that.
The cost is that shellcheck reads each fragment alone and can see neither the
caller that assigns a name nor the later stage that reads it, which is why each
carries a file-level `SC2154` directive saying so.

**The six programs are files beside them**, each with a docstring stating what
it reads and what it prints: `needles.py` (the strings whose presence in a
transcript means a real credential is in it, and the reader of the volume
stream that `check.py` and `redact.py` share), `shapes.py` (long runs described
rather than printed, shared with `passages.py`), `check.py`, `redact.py`,
`passages.py` and `findings.py`. They all run on the host, as they did as
heredocs; none of them was ever piped into the container.

**What the split changed on purpose**, measured against the same fixture
sequence before and after — a `just collect` holding a transcript, `--held`,
`just status`, an `--approve`, a second fixture and a `--redact`, the branch log
and the ledger. Every line of every report was identical except three:

  * The **fingerprint** now hashes every file in `host/archive/`, found rather
    than listed, instead of naming four files. A hand list stops covering the
    file added beside it, silently, and after a split into eleven files that is
    no longer a small risk. The cost is one full re-read after an edit to a file
    in that directory that is not part of the gate.
  * The **redaction marker** reads `[redacted: … — collect.sh]`, not
    `collect-transcripts.sh`. It is what a reader of the archive is told
    rewrote the file, and it must name something that exists.
  * The **ledger header**, written once when the file is created, says "Written
    only by `just collect`" for the same reason.

**`LABELS` and `EXPECTED` are gone.** Both were tables of one row. `redact.py`
now asks `label_for(name)` — the `credentials` section, then the two families
that name themselves — and `check.py` compares the one fixed section in a block
of its own beside the `ssh:` and `vault:` families. The
missing-versus-empty distinction is untouched, and is the whole mechanism: a
section that never arrived is `NOT COMPARED`, which raises the alarm, and one
that arrived empty is "nothing in the volume to compare against", which does
not.

**The public-winnow probe** is `needles.py --selftest`, which builds the
synthetic key, runs the module end to end and prints `just verify`'s own
`state|label|detail` line. The scrape it replaces read the heredoc back out of
the shell with awk; a probe that has to reconstruct its subject is a probe that
stops proving anything the day the subject moves.

## What reaches the archive at all

### Only the checkout's own sessions

Claude Code files a transcript under the mangled cwd, and `run` and `chat` are
the only things that start a session inside the checkout — `just verify`'s
probes and `just shell` land in `/home/agent` instead. Measured 2026-08-26: 394
of the 566 files on `sessions` were probe transcripts, sixteen lines each, and
the list nobody could read was seventy percent of them. Collection now takes
only what is filed under `AGENT_PROJECT_DIR`.

Those files are not scanned either, and that is consistent rather than a gap:
the gate decides what reaches the archive, and what is never archived cannot
leak from it. The volume keeps them.

The risk this takes is silent — a session started without `-w` would file
itself outside and never be archived, with nothing to notice — so the count of
what was left behind is printed on every run. A number that jumps is the
symptom.

Only the transcripts are extracted. Shell snapshots and file history are noise,
and file history alone has been measured at 55 MB.

### Root inside the extraction container

The transcripts are 0600 owned by uid 1001, so root inside the throwaway
container has to do the reading — but everything it writes to the bind mount
comes out root-owned, and then the host user can neither copy nor delete it. It
hands ownership back before exiting. Learned twice in one evening.

### The layout on disk

`archive-layout.py` is the one definition of where a staged transcript belongs:

    transcripts/2026/08-26/<session-id>.jsonl
    transcripts/2026/08-26/<session-id>--agent-<agent-id>.jsonl

It is deliberately not the volume's own layout. The volume files everything by
the mangled cwd — one directory holding every transcript there has ever been,
named by uuid, in no order. At 169 files that is not a list anybody reads. A day
is roughly ten of them and the date is what a person actually navigates by, so
the day is the directory.

A subagent sits beside its session rather than in a folder under it. The volume
nests it at `<session-id>/subagents/agent-<id>.jsonl`, which reads as a
directory among files and cannot be opened as a peer; the compound name says
which session it belongs to without needing the nesting to say it.

The date is the transcript's own, read from the first entry carrying a
timestamp — never the file's mtime, which is the moment this run copied it out
of the volume and is therefore today for every transcript ever written. A
transcript with no timestamp goes to `undated/`, because a date invented here
would sort correctly and be wrong.

Three things must agree about that layout — the pruner that decides a file is
already archived, the copy that places it, and through the first, the count the
run reports — so it is written once and read as a map. Two spellings of a
directory name drift, and the drift is silent: a pruner looking in the wrong
place finds nothing already archived and re-reads all of it, for ever.


## The gate

A transcript carries every command's output verbatim, so it is the most likely
place in this whole system for a credential to appear. A hit stops the run:
nothing is redacted automatically, because silent redaction hides the incident
that matters more than the file does. Three layers ask the question — a pattern
floor, a verbatim comparison against what the volume actually holds, and
gitleaks — and `detect()` in `scan.sh` runs all three.

### A rule that fires on ordinary prose gets switched off

This is the doctrine every shape rule below is written against, and it is the
reason each one is anchored the way it is. Public keys are deliberately not in
the pattern floor: the bootstrap prints one on purpose, so a transcript
routinely contains `ssh-ed25519 AAAA...` — measured, four times in one real
session. A gate that fires on every ordinary collection is a gate that gets
switched off, and then it is not there on the day it matters.

### A key is a header and a body

Matching a PEM header alone fired three times and twice it was prose *about* a
key — the guard's own fixtures, and a sentence in an issue reply the agent had
read. The floor's rule requires the armour and a base64 body behind it.

The body may sit behind a real newline or a JSON-escaped one, and in these files
it is always the latter: a transcript is JSONL, and a JSON string cannot hold a
literal newline, so anything armoured inside one arrives on a single line where
grep can see it whole.

The pattern string is written in the dialect both readers share. It is handed to
`grep -E` and to Python's `re`, and `[[:space:]]` is a POSIX class only the
first understands — Python reads it as a set of the letters in "space" and
quietly matches something else. It did: the passage display found nothing for a
genuine key block, which is the one case it exists for. A separator of an
escaped newline or a space means the same thing to both, and grep cannot cross a
real newline anyway.

### The floor is built in one place, and half of it is this installation's

**2026-09-03.** `host/archive/floor.sh` sets `patterns`, and both the collection
and the two verify probes that ask whether the anchored rules still catch what
they were written for source it — a probe that retypes the floor is the copy
that goes stale while still passing.

It is two halves. The shapes true of every installation are in that file: PEM
bodies, `ghp_`, `github_pat_`, `sk-ant-`, `AKIA`. The shapes of the secrets this
agent holds because of what it *does* — a forum's key format, a feed token, a
webhook URL — are in `image/config/secret-shapes.txt`, which is untracked, and are
appended to the half above; `image/bash-guard.py` adds the same lines to its own
floor from the copy baked into the image. An absent file adds nothing, which is
what a fresh installation has, and the generic half still runs. See
docs/configuration.md#the-three-files-that-are-yours.

That file is hashed into the gate fingerprint beside `host/archive/` itself. A
shape added today has to make the next run read every transcript again, and a
rule of the gate living outside the directory the fingerprint walks is exactly
the kind of thing that silently stops being covered.

### The 1f916 secret shape

Added 2026-08-26, because of what happened without it: the same secret was
caught in one transcript and missed in another, on nothing but its punctuation.
gitleaks' `generic-api-key` rule wants a keyword bound to the value by a quote
or an `=`, so `"secret":"1f916_sk_..."` in an MCP call fired and
`secret:\n1f916_sk_...` out of a command's stdout did not — and the second one
was archived and pushed on 2026-08-23. A shape nobody wrote down is a shape
caught by luck.

`_sk_` rather than a bare `1f916_` prefix: the handle, the citizen number and
the public key are all published on purpose, and a rule that fires on those is
one that gets switched off.

The rule itself moved to `image/config/secret-shapes.txt` on 2026-09-03, being one
installation's and not every installation's; what it is and why it is spelled
that way is unchanged.

### The shape and the verbatim layer stopped being complements

Until 2026-09-02 `1f916_sk_` was in the collection's pattern floor and not in
`bash-guard.py`, deliberately: the guard's vault cache compares every fetched
secret verbatim, and the token lands in that directory the moment `vault` reads
it, so a shape on that side would have been a third spelling of a rule the
verbatim layer already stated exactly. The collection runs on the host, where
there is no vault cache to compare against and shapes are all there is.

On 2026-09-02 the shape went into both. The path the guard compared verbatim was
dropped that day — the agent chose that path, so the runner cannot rely on it —
which left the shape as the only cover for a key that never passed through the
vault. See docs/boundary.md for the guard's half.

`feed=` is untouched by that: `vault` is still the only way that token arrives.

### The feed token shape

Added 2026-08-27 for the Reddit feed token, and it is anchored on the parameter
rather than the value because the value has no shape at all: a bare run of hex
with no prefix, no keyword and nothing for gitleaks' generic rules to bind to.
Nothing in the default ruleset matches it — measured 2026-08-26, before the
token was provisioned — which is the whole reason the line exists.

What it does not catch, written down rather than discovered later: the token in
a URL, and only there. A bare value on its own line matches nothing, on any
layer, and cannot — there is no shape to match. It holds only because the token
is never used except as a query parameter, which is also why anchoring on
`feed=` costs no false positives: the untokenised feed URLs
(`/r/1f916/new/.rss`) carry no such parameter.

The rule moved to `image/config/secret-shapes.txt` on 2026-09-03, with the one above.

### A webhook URL is the secret

A webhook URL is a credential that never touches the volume, which is the class
the verbatim layer is structurally blind to: nothing on disk has ever held it,
so there is no value to compare against and the only layer that can see it is a
shape.

`gh api /repos/.../hooks` prints every hook a repository has, secret and all —
measured 2026-09-01, two Discord webhooks with their 68-character tokens, which
passed the floor, passed the verbatim comparison and passed gitleaks (0
findings, asked of the installed one), and are on `sessions` and on origin.
Anyone holding such a URL can post as the integration.

The rule is anchored on the path for the reason `feed=` is anchored on its
parameter. The host and `/api/webhooks/` carry no entropy and cost nothing, the
numeric id is public, and the token behind it is the part worth stopping on.
`discordapp` is the legacy host and still works, so it is in the rule rather
than discovered on the day one turns up. Measured over the 417 transcripts in
the volume: one match, the file above, and no others.

The rule moved to `image/config/secret-shapes.txt` on 2026-09-03, with the two above.


## What gitleaks is told

`host/archive/gitleaks.toml` changes exactly one default rule and adds exactly
one allowlist entry. gitleaks reads shapes the floor does not, and the floor
exists mainly so that a host without gitleaks still has a check; nothing in that
config should make gitleaks weaker at finding keys.

### The armour pair must pass

gitleaks' own `private-key` rule matches BEGIN...END with anything between,
including nothing. Measured 2026-08-25 on 8.16.0:

    prose naming the header          clean
    the header on its own            clean
    BEGIN and END, nothing between   FLAGGED   <- this one
    BEGIN, a body, END               FLAGGED

The third is not a key. It is what a program holds in order to *rebuild* a PEM —
`tools/vault-signing-key.py` carries exactly that pair, because the vault
refuses a value beginning with a hyphen — and it kept three transcripts out of
the archive on 2026-08-25 while the same shape one layer over stopped the backup
for four hours. A key is a header and a body; `bash-guard.py` and the floor both
say so, and the redefinition makes the third reader agree. The regex is the
guard's, character for character, so they cannot drift.

Three ways of spelling it were measured and rejected:

- An **allowlist** cannot express it. The condition is "this span has no body",
  a negative, and gitleaks is Go: RE2 has no lookahead, so it cannot be written
  at all.
- **`[extend] disabledRules`** does nothing here. It arrived after 8.16.0, and
  an option this version does not know is ignored in silence — the config loads,
  the default rule goes on firing, and nothing says so.
- **A rule with an id and no regex makes gitleaks panic**, and `--exit-code 1`
  reports a panic as a finding: a crash and a leak are the same number.
  `scan.sh` refuses any exit above 1 for exactly that reason.

So the default rule is re-declared by its own id with a complete definition.
Measured on 8.16.0: the redefinition wins and the armour pair passes. `just
verify` proves that against the installed gitleaks rather than trusting it,
because the two failures above are both silent. See docs/verify.md.

### A value that is nothing but hex

Added 2026-08-30. The agent works on a marketplace whose tool output is full of
`token: '0x8335...2913'`, `authorization_hash: '051a4a...80bc'`, `tx_hash`,
`payload_hash` — EVM addresses and 32-byte digests, public by construction, and
every one of them a keyword bound to a high-entropy value, which is exactly what
`generic-api-key` is. Three transcripts in one night, eighteen findings, one
hundred percent false. It was one evening away from being the gate that gets
switched off.

What it gives up, named rather than discovered later: a real credential that is
pure hex *and* bound to a keyword now passes gitleaks. Measured on a corpus of
the shapes that matter — an AWS key, `1f916_sk_`, a PEM with a body all still
caught; `legacy_api_key = "0123456789abcdef0123456789abcdef"` no longer is. What <!-- gitleaks:allow — a fixture, not a secret -->
still covers that case is the pattern floor for every prefix written down there
(`feed=`, whose token is bare hex, is anchored on the parameter and is
unaffected), and the verbatim comparison against everything the volume actually
holds. What is given up is the unknown-unknown: a hex credential, of a service
nobody has met, that the volume does not hold.

The allowlist is written against the match, and that is measured too.
`regexTarget` is ignored in silence by this build — `match`, `secret` and `line`
all behave identically, and identically to the default, which is the match — so
an anchored regex against the secret alone allowlists nothing and says nothing,
the same silent failure `disabledRules` has above. Hence the shape: the
separator, the optional quote, the value, the end of the match.


## The verbatim layer

### It is a gate, not a report

Until 2026-08-26 the comparison against the real credentials ran only on files
the two shape layers had already flagged — a check that examines the suspects the
other check caught. It could therefore never find what the shapes missed, which
is the only thing it was there for. One transcript carried the live 1f916 secret past
both shape layers and was archived and pushed on 2026-08-23 while this comparison
sat one `if` away from it.

It now runs first, over every transcript, and a hit holds the file. This is the
layer with no false positives by construction: it does not say "this looks like a
credential", it says "this *is* a byte string the volume is holding". It is also
the only layer that covers a shape nobody has written down yet, which is every
secret the vault gains next.

What it costs: anything the operator puts in the vault is a secret as far as this
is concerned, because the keys are not known here — that is what a vault the
operator can add to without touching the image means. An identifier stored there
will hold transcripts until it is cleared with a note, and the ledger is where
that judgement belongs. `image/config/vault-exempt.txt` is the list of vault entries
ruled not to be credentials; see docs/vault.md.

The secrets are read out of the volume once, kept in the process, and handed to
grep on standard input. They are never written to disk, never passed as arguments
where `ps` would show them, and never printed — only the verdict comes back out.
The transcript is the untrusted side and is the only side ever quoted.

### A missing section is not an empty one

Every section of the volume stream ends with an explicit `echo`, and the two
discovered families emit their header whatever happens. `.credentials.json` ends
without a newline, so `=== f916` was printed onto the end of its last line, and
one missing byte cost two checks at once: the marker was no longer at the start
of a line so that key was never compared, and the JSON now had a marker glued to
it so it no longer parsed and fell through to the word-split fallback. Both
failures read as "nothing in the volume to compare against" — a check quietly
becoming a weaker check. That is why the report says a section is *missing*
rather than empty, and why `CHECK` treats `NOT COMPARED` as outranking every
other verdict: an answer that is absent is not an answer of no.

### Needles must be newline-free

A transcript is JSONL, so a newline inside a value arrives as the two characters
`\` and `n`. An exact whole-value match therefore cannot find a multi-line secret,
ever — which is what hid the 1f916 signing key inside one transcript behind the words
"no secret from the volume appears in this file". Every needle the NEEDLER emits
is newline-free for that reason.

The needler is a raw docstring for the same reason: it has to name the two
characters a JSON-escaped newline is made of, and `\n` inside an ordinary string
is a `SyntaxWarning` printed to stderr on every single run — including `--held`,
which `just status` calls each time it is asked.

### Windowing a key body

A PEM is reduced to its body: the armour is boilerplate, identical across every
key of its type. Only the *second half* of that body is windowed, because every
key of a format shares its opening bytes — every OpenSSH private key begins with
the base64 of `openssh-key-v1`, every PKCS#8 Ed25519 key with `MC4CAQAwBQYDK2Vw`.
Measured before this was shared: 24 characters at offset 0 of the ssh key matched
a freshly generated, unrelated key. Windowing the second half is what separates
"the key is in here" from "something key-shaped is".

Window 24 at stride 8, so any run of 31 contiguous characters from that half is
caught. A real leak carries the whole body and is caught many times over; a
fragment under 24 base64 characters is seventeen bytes of key and reconstructs
nothing. The stride is not a weakening for its own sake — a needle at every
offset meant hundreds of them, and the list is handed to one grep pass over every
transcript in the volume.

### The floor for a document

`DOCUMENT_MIN` is 40, and it is what keeps this layer free of false positives. A
login file is a document, most of which is not secret: `.credentials.json`
carries two 108-character tokens beside a 25-character oauth scope and a
22-character rate-limit tier, and those last two are words that appear in
ordinary output — `claude-usage.py` prints the tier by name. A gate that held
every transcript mentioning it would be switched off within a day. A credential
in a document is a long unbroken run; a scope name is a word. A file whose whole
content is one secret has no such problem and keeps the lower floor of 12.

### Public halves are not secrets

An OpenSSH private key file *contains* its own public key, so a window of its
body can land inside the public blob a transcript prints perfectly properly.
Measured 2026-09-01: 42 characters of the body, every one of them inside
`ssh-ed25519 AAAA...` as `gh api /user/keys` returned it, and the private scalar
nowhere in the file. That held two transcripts, and `--redact` could not release
them: it replaces whole forms and a window is not one, so the redaction proof
failed, the ledger entry was dropped and the same two came back every run for
ever.

`winnow()` now drops any needle wholly inside a published public key. It must
narrow and never blind: everything it drops has to be text the volume itself
publishes, which is why `public` is read from the `.pub` files rather than
reconstructed — an over-wide section here would empty the needle list and the ssh
comparison would become nothing at all, silently. `just verify` proves both
halves: the body still found, a bare public key no longer objected to. The `.pub`
file is read rather than derived because `ssh-keygen -y` would need the private
key on the host and openssh installed, while the `.pub` is already there, is
exactly what was handed out, and stays right when a key is rotated.

`public` is also excluded from the comparable sections for the redactor's sake
rather than the scan's: detection already drops what is publishable through
`winnow()`, but the redactor replaces from `values()` and does not, so a
comparable `public` section would rewrite every public key in every archived
transcript into a marker.

### Every private key, discovered rather than listed

The `.ssh` section walks `id_*` rather than naming a file. It named `id_ed25519`
alone and looked complete while `id_ed25519_signing`, minted on 2026-09-01, sat
beside it compared against nothing at all; it was found by hand, which is not a
way of finding things. A hand-written list of keys goes stale the next time one
is made, silently, and the silence is the whole defect.

The vault cache is discovered the same way and for the same reason: the keys are
not known here, so the sections are one per cached secret, named `vault:<key>`.
Until the vault existed, every credential the agent held was one put there by the
entrypoint; now a session can fetch a credential nobody wrote into this file, and
without the discovery the scanner would report "no secret from the volume appears
in this file" while holding none of them to compare.

### A path the agent chose is not a mechanism

Two sections left the volume stream on 2026-09-02, with their labels and
`EXPECTED` entries: `=== f916` reading `/vol/.config/1f916/key`, and
`=== f916-signing` reading `signing-key.pem` beside it. The agent chose those
paths, so they were never a mechanism this script could rely on — a path named
here covers nothing from the day the agent picks another, and says nothing when
it does.

What remains is the vault-cache section, which compares every fetched secret
verbatim whatever it is called, and the `1f916_sk_` shape in the floor, which
catches such a key even when it never went through the vault. `bash-guard.py`
dropped the same path and gained the same shape in the same change; see
docs/boundary.md.

### One definition of a credential's outward shape

The scan and the per-file report read the same NEEDLER. Two spellings of one rule
drift, and the one that drifts is the one nobody is looking at — which is how the
vault comparison came to be an exact whole-value match while the ssh comparison
beside it was armour-stripped and windowed, so a multi-line PEM in the vault could
not match anything in a JSONL transcript however plainly it was there. It did not.
On 2026-08-26 the per-file report told the operator "no secret from the volume
appears in this file" about a transcript holding the 1f916 signing key, under a
sentence inviting them to clear it.

`needles()` answers "is it in here" and windows a key body so a fragment is still
found; `values()` answers "what does a redaction replace" and returns whole forms
only, longest first. The two are separate because replacing windows would shred a
body into a row of markers with the parts between them left in place.


## Rulings and the ledger

### The ledger, and where it lives

`reviewed-transcripts.txt` sits on `sessions`, beside the transcripts it
describes, and is written by `just collect` and nothing else — so that
branch keeps the single writer the archive's README claims for it. That is also
what lets a ruling and the transcript it rules on land in the same commit: the
transcript cannot be archived until the ruling exists, so the ruling travels with
it rather than in a commit of its own somewhere else.

It is read with `git show` rather than from a working file because there is no
working file: `sessions` is an orphan branch nobody checks out. Which is the
other reason the ruling flags exist — appending a line by hand would mean a
worktree dance every time.

A ruling is per file, and every layer below names files, so one entry covers them
all. The hash is of the transcript's contents, so a transcript that grows is
offered for review again. That is the point rather than a wrinkle — and it is
also why a ruling holds for ever on a session that has ended: the volume's copy
never changes again, so the same hash comes back every collection and the ledger
answers it without asking.

### Two verbs, and telling them apart

Entries are

    <sha256>  approve  <path>  # why      archive it as it stands
    <sha256>  redact   <path>  # why      rewrite the credential out, then archive

An entry written before 2026-08-26 has no verb at all, which reads as `clear`
because that is the only thing it could have meant. The old reader was
`grep -q "^$h"` — hash at the start of a line, nothing else looked at — and left
as it was it would have read a redaction as a clearance and archived the file
whole, key and all, silently, looking exactly like it had worked.

### Where `sessions` is, for reading

The local branch, or the remote's when this clone has never checked it out. A
fresh clone of the archive has only `origin/sessions`, and `git show
sessions:...` fails there — git's DWIM looks under `refs/remotes/sessions`, never
`refs/remotes/origin/sessions`. The ledger then came back empty, and an empty
ledger is not "nothing has ever been ruled on": every transcript already cleared
or redacted was offered for review again, in a clone where the ruling was sitting
one ref away. Measured 2026-08-26 against a throwaway clone.

Empty when the branch exists nowhere yet, which is the first collection into a
fresh archive and reads as "no ledger, nothing archived" — both true.

The worktree block at the bottom of the file resolves the same three cases in the
same order, but is separate because what it does after resolving is different: it
checks the branch out, with a different flag for each case.

### A ruling names the hash

The report prints the sha256 a ruling is keyed on, the path the ledger records,
and the session id the file is called after — the last only so a refusal can name
the file the way the report's heading does.

A ruling names the hash, or an unambiguous start of it, and deliberately not the
session id: the hash is of the bytes that were reviewed, so a transcript that grew
between the report and the ruling matches nothing and is offered again, while a
session id would go on naming the file and would quietly rule on content nobody
read. A prefix keeps that — a file whose bytes changed does not keep the first
eight characters of its hash — and costs only the 56 characters that made a
hand-typed ruling name nothing.

The prefilled command carries twelve characters of the hash rather than all
sixty-four. It still names the bytes that were reviewed (the resolver takes a
prefix of eight or more and refuses an ambiguous one) and it fits on the line
beside the note, which is what a person actually reads before pasting it. The full
hash is in the HELD BACK list for anything that wants to quote it whole. The
command is printed *under* the transcript it rules on rather than once at the
bottom: it used to be printed in one place with the hash in another and `<the
hash above>` in the middle, which is "above" only when a single file is held, and
a hash copied from the wrong paragraph rules on a file nobody was looking at.

### A ruling that names nothing is a refusal

It was a no-op until 2026-08-30: an id that matched no held transcript wrote no
ledger entry, said nothing, and exited 0 — the run went on to archive whatever
else it had and the report printed the same held files again, one line longer
than the reader was looking at. Four rulings were typed against short ids that
day, over about fifteen minutes, and every one of them did nothing. A mistake this
cheap to make must be this loud.

Ambiguity is refused for the same reason rather than resolved to the first match:
the wrong transcript cleared is a credential pushed to origin.

When a refusal lists what is held, it lists only what is actually waiting. Every
transcript the gate objects to is in `flagged_at`, and most of them were ruled on
months ago and are re-flagged on every run by design — a list of fourteen with the
four that matter somewhere inside it is the shape of report this whole section is
trying to stop producing.

A ruling that names something already settled is not a mistake, it is a repeat — a
command pasted twice, or a second run of a script. The ledger settles it without
reading anything and the collection goes on; refusing there would stop a run that
has nothing wrong with it.

### Several rulings in one run

`RULINGS` has been a list since 2026-08-30. It used to be one of each, and a run
carrying two was refused — the stated reason being that two rulings would have to
share one `pending` line, which is a fact about a variable rather than about the
record. Every ruling still names one transcript and carries its own note, and they
land in one commit together the way the transcripts do.

What the refusal cost: four held transcripts meant four runs, each re-reading
every transcript in the volume, because at the time a run carrying a ruling could
not use the skip.

Two rulings resolving to the same transcript in one run are refused. Where a
redaction fails its proof, only that ruling's own pending line is dropped, never
the whole list — dropping all of them because one redaction did not hold would
silently discard rulings that did.

### A ruling does not force a full read

Until 2026-08-30 it did. The premise was wrong: the skip removes transcripts
already in the archive byte for byte, and a transcript waiting to be ruled on is
by definition not in it — it was held back. The one file a ruling can name is the
one file the skip can never take. Worse, a hash belonging to a skipped file is a
hash nothing looks for, so the entry was never written and the run ended having
silently done nothing.

What the belt cost: every ruling read all 307 transcripts, and gitleaks over all
of them is 15 of the 17 seconds. Four rulings on one evening was a minute of
gitleaks proving what the ledger already said, and the operator waiting through it
four times, which is how a review gets resented and then skipped.

What catches the case it was guarding: a ruling that resolves to nothing now
refuses and lists what is actually held, and one naming a transcript already
settled says so — neither of which needs the file to be read again.


## Redaction

### The third ending

Until 2026-08-26 a transcript carrying a real credential had two endings and both
were bad: held for ever, leaving a silent hole in the archive where a session was,
or cleared, which pushes the credential to origin where nothing can take it back.

The objection recorded above is to redacting *silently* — "silent redaction hides
the incident that matters more than the file does" — and it says nothing against a
redaction asked for by name, with a note, written into the record. That argument
became the design for every case only because the other verb was never built.

It runs from the same two definitions that `detect` does: the whole forms of what
the volume holds, and what the shape rules match. Not from gitleaks, which under
`--redact` reports `Secret: REDACTED` — it can say a file has a secret in it and
not what the secret was. A finding only gitleaks can see is therefore not
redactable from the report, and the proof says so out loud rather than archiving a
file it could not rewrite.

Redacting is not rotating. It rewrites what reaches the archive from here; it does
nothing about a copy already pushed to origin, and nothing about a credential that
is still valid.

### Redaction by position, deliberately not done

The comment here read `EndColumn: 0` until 2026-08-30, and the installed gitleaks
in fact reports both columns — which is what the passage display now marks with.
So a redaction *by position* is possible and is deliberately not done: rewriting
bytes nothing can name, on a column convention already measured to shift by one
between the first line of a file and the rest, is a different thing from replacing
a value the volume can show you. That is the operator's ruling to make, not a gap
to close quietly.

### The marker

The marker carries no quote and no backslash: it lands inside a JSON string in a
JSONL record, and either character would leave the line unparseable for everything
that reads a transcript afterwards — the passage display in the same file
included.

And no date. Redaction is re-applied from the ledger on every later collection, so
a date there would be today's rather than the ruling's, and the file would be
rewritten at every UTC midnight saying something that was not true. When it
happened is in the commit and in the ledger line beside it, which travel together
on purpose.

The two discovered families name themselves in the marker. A marker reading "the
ssh private key" over a volume holding three of them says the wrong thing about
two, and the marker is all a reader of the archive ever gets.

Whole forms are replaced longest first across every section, so a key body goes
before the lines it is made of and nothing is replaced inside a marker already
written. Then what the shapes matched, which is how a credential the volume no
longer holds still goes: a rotated token, a key from a session that ended. The
armour of a PEM survives both passes on purpose — it is boilerplate, it carries no
entropy that belongs to this key, and leaving it there is what makes the redaction
legible to whoever reads the transcript later.

### The ruling is remembered, and re-applied in silence

The entry is keyed on the hash of the transcript as it sits in the volume, and
that copy is never touched — a session that has ended hashes the same for ever, so
every later collection recognises it, redacts it again on its own and archives it
without a word. The volume keeps the original; only what reaches the archive is
rewritten.

Only a redaction asked for in this run is announced. A remembered one is
re-applied on every collection for as long as the transcript exists, and
announcing that three times a run for ever reads as something happening when
nothing is. Nothing is lost by the silence: a redaction that removed too little is
caught by the proof, which is loud.

### The proof

The same gate runs again over the rewritten copies. A redaction that missed a
second occurrence must not read as success, and the only check worth trusting to
say so is the one that found it in the first place — a second spelling would
drift, and the one that drifts is the one nobody runs by hand.

A file that still trips it goes back to being held, and the ledger entry this run
would have written is dropped, so a ruling that cannot be carried out is not
recorded as though it had been. When the entry was written by an earlier run there
is nothing to drop and the file stays held on every collection from here, loudly,
which is the right outcome: it means the gate now sees something the redactor
cannot name, and that is a decision for the operator rather than a state to paper
over.

### Offering redaction only when it can work

`--redact` replaces whole credentials the volume holds and whatever the shape rules
match; a file where neither is present cannot be redacted, and asking for it anyway
rewrites nothing, fails the proof, drops the ruling and offers the same transcript
again on the next run — for ever. Two sat in that loop on 2026-09-01 and nothing
said why.

The check has two halves computed in different places. The shape half is the floor's
own matches, which the shell knows and the checker does not. The volume half is a
third field `CHECK` has written since 2026-09-01, computed from the same `values()`
the redactor replaces from rather than from the needles: the two differ for exactly
the case that stranded those transcripts — a windowed match has no whole form in the
file, so the rewrite is a no-op. The report must not print a command that cannot
work.

### The default note carries evidence, not a judgement

The note is the record, so a default must not write a judgement nobody made. It
carries what objected and what the comparison against the real credentials
concluded, which is a sentence that stays true whatever the operator decides and one
they can account for a year later.

A default only where it is safe to have one. When the comparison found a real
credential, `--approve` keeps its placeholder: a ready excuse printed under a line
reading A REAL CREDENTIAL IS IN THIS FILE is the one thing this report must not
offer. `--redact` keeps its own unless there is a named credential to name. A check
that did not run gets neither.

No quote can reach the command line: the note is printed inside double quotes, and
one in the middle of it is a line that pastes as something else. Nor a `$`, a
backtick or a backslash — since 2026-08-30 the note can carry gitleaks' `Match`,
which is a piece of the *transcript*, and a double-quoted string is not inert about
those three. What the operator pastes must be the ruling they read.


## The held-back report

Flagged transcripts are held back, not refused. Refusing the whole collection was
right when the flagged transcript was the exception; it is not, because the agent
tests this machinery and reads issues about it, and prose describing a key trips the
scan exactly like a key does. An archive that stops on every such session is one that
never runs unattended, and then the record it exists to keep is the thing that goes
missing. The guarantee is unchanged — nothing credential-shaped reaches the archive
unreviewed — and what changes is that the rest of the record no longer waits behind
it.

### One report per held file

It used to run on the first of them and nothing else — `head -1`, and every heading
said "in the first of them" while the other files were named by hash and never
opened. The passage display being first-only was a reasonable economy; the credential
comparison being first-only was not, because that check is the whole difference
between "a fixture" and "a leak", and the files it never reached were ruled on from
their hash alone.

The Python programs are written to files rather than inlined for that reason: each is
now read once per held file, and a heredoc re-emitted inside the loop is the same text
written twice as far as drift is concerned.

### Describing a run instead of erasing it

A run of base64 was replaced by the word `<redacted>`, and that made the display
useless for the one thing it exists to do. The report tells the operator that a key
has a body of gibberish and prose about a key reads like a sentence — but "a body of
gibberish" *is* a run of twenty-plus base64 characters, so the mask and the criterion
were the same shape and it hid exactly the evidence being asked for. What is left
after masking reads identically for a real key and for a fixture. Measured on a real
held-back transcript: the deciding facts were a 20-character body ending in the word
`fake`, and neither the length nor the word survived the mask.

So the run is described instead of erased: how long it is, and a little from each end.
Length alone usually settles a key body — a real RSA-2048 body is about 1600
characters and no fixture is — and the ends are where `fake` tends to be. It still
never prints a whole body.

### Not starting immediately after a backslash

In a JSONL transcript a newline is the two characters `\` and `n`, and `n`, `t` and
`r` are all base64 characters — so a run introduced by `\n` swallowed the escape's
letter and was described as one character longer than it is, starting `nAE+pX` where
the value starts `AE+pXd`. A length and a first-six that are both off by one are the
two things an operator compares against what they see elsewhere. Measured 2026-08-26.

The cost, named: a run that genuinely follows a backslash is described from its second
character. One character of a masked value is nothing; a wrong length is not.

### Base64URL is in the alphabet

`-` and `_` joined the run alphabet on 2026-09-01, because base64URL exists and half
the tokens written down here are in it: `feed=`, `github_pat_`, `sk-ant-` and the
webhook rule all match a class the alphabet did not. Without them a token is not one
run but three, and the pieces shorter than the floor are printed in clear — measured
on a live Discord webhook token, 17 of its 68 characters straight through, in the
report and in the default `--approve` note, which is written to the ledger and pushed.
What survives now is the first six and the last four, the convention every other secret
in that ledger is already recorded under.

The cost is real: an identifier that is merely long and hyphenated is elided too, so a
uuid in a quoted passage now reads `<36 chars: 5fec40…9a78f>`. That is a passage harder
to read. It is the right way round — this report is quoted into a file that reaches
origin, and a value it prints cannot be taken back, while a uuid it hides is one nobody
was ruling on.

### Never cut a run, and never quote from inside one

Both failures print a number that is not the length of anything. A window sliced 240
either side of a hit that sits in a 500-character base64 run is 500 characters of that
run and nothing else, and the mask then describes the *window* —
`<500 chars: AE+pXd…JSVD>`, with no words around it and a length that is the display's
own, not the run's. Measured 2026-08-26, on a held transcript nobody could rule on from
it, which is the one thing this section exists to make possible.

So the bounds are snapped outward to whole runs, and the shaping happens once over the
result. What decides the question is never inside the gibberish anyway — it is the
command that produced it, the JSON key it is the value of, the sentence that introduces
it.

Neither edge of the window may land inside a run either. A run cut by the edge is
described with the length of the piece that survived the cut, which is a number that is
not the length of anything and reads exactly like the real one. Measured 2026-08-30: a
64-character hash quoted 240 characters from the mark came out as `<45 chars: ...>`.

### Where gitleaks' finding sits

Without a span for gitleaks' findings nothing is marked when gitleaks is the objector,
which is most of the time — it reads shapes the floor does not — and the passage is then
74 columns of JSON with the thing being ruled on somewhere in it, every long value alike
behind the mask. Measured 2026-08-30: of four held transcripts the one anybody could rule
on was the one the floor caught.

Its columns are off by one on every line but the first — the newline that ended the
previous line is counted, so `StartColumn` is one past where the match begins. Measured
against the installed gitleaks, on a synthetic file and on a held transcript. It is a
quirk of a build, not a promise, so nothing rests on it: the offset is a first guess and
the match is then anchored on the part `--redact` did not blank. `Match` keeps the
keyword and the quotes and replaces only the value, so `token: '` is a literal that can
be looked for — and a column disagreeing with it is a version spelling this differently,
which must read as "do not mark" rather than as a mark on the wrong bytes. A highlight
over the wrong characters is worse than none: it is read as the objection.

### One passage per place

Not one per objection and not one per line. A transcript line is a whole JSON record:
keyed by the line alone, four findings on it collapsed to one and the other three were
never quoted; keyed by each finding, two of them forty characters apart printed as two
passages of nearly the same text, each missing the other's mark. So a passage is taken,
and every objection that falls inside its window is marked in it and struck off the list.

And not the same paragraph twice. A record carries a tool's output twice — once in the
message content and once under `toolUseResult` — so two objections ten thousand
characters apart on one line quote text that is identical word for word, and two of the
three passages said nothing the first had not. The place is different and what is there
is not, and it is what is there that is being ruled on.

Positions come from all three objectors. The pattern floor knows where it matched;
gitleaks reports a line and a column and reads shapes the floor does not; the verbatim
layer knows where the real credential sat and describes no shape at all, so when it is
the only one objecting the other two have nothing. Taking positions from only the first
left this section empty in the common case, which is the case it was built for — and
taking them from the first two left it empty for exactly the files the verbatim layer was
added to catch.

### Marks, and where they are placed

Marked with two characters that cannot occur in a transcript and rendered at the very
end, after the wrapping. Escape codes inserted before `textwrap` are counted as width and
the lines come out short by exactly their length — invisibly, since the text still looks
wrapped.

Marked in the raw slice and outside the run, never inside it: a mark between two base64
characters would split the run in half and the two pieces would be described as two
shorter values. Outside it, the lookbehind still sees what it saw. Right to left, so
placing one does not move the next one's bounds, and an overlapping mark is dropped
rather than nested: two pairs crossing each other render as neither.

ANSI only when someone is watching. `just run` redirects the report into a session log,
and escape codes in a file are noise on the day it is read — so the log gets guillemets,
which say the same thing and survive a `cat`. `NO_COLOR` is honoured for the same reason
it exists. The whole report goes to stderr, so that is the descriptor tested, and it is
decided in the shell rather than in the reader, which cannot tell: its own stdout is a
command substitution whatever the terminal is doing.

### What gitleaks objected to, not merely that it did

`--redact` blanks the value in gitleaks' `Match` and keeps everything around it, so
`token: 'REDACTED'` is a whole account of the finding: the field name is what decides
whether this is a credential or a column of blockchain data, and it is the one thing the
mask in the passage cannot show — a 64-character hex value is described there as
`<64 chars: ...>` whatever it is the value of.

`Match` is printed instead of `Description`, which is the rule id said a second way, and
findings are counted like the pattern floor's, because four findings on one line printed
as four identical lines naming neither the field nor the column. Measured 2026-08-30, on
three held transcripts nobody could rule on.

### And neither may have anything to say

The verbatim layer objects to shapes no rule describes — that is what it is for — so
both the floor and gitleaks can be silent while a file is held. An empty heading there
read as "nothing was found", which is the opposite of what had happened.


## The skip

### It agrees with git's own object id

The gate decides what reaches the archive, and a transcript already on `sessions` byte
for byte has reached it — and reached origin with it. So reading that one again cannot
hold anything back; it can only cost. It cost 7.9 of the 9.2 seconds `--held` took on
2026-08-26, on every single `just status`, because 503 of the 506 transcripts in the
volume were already there unchanged.

`archived.py` settles a file two ways. A git object name is the sha1 of
`blob <length>\0<contents>`, so the archive already records the bytes of everything it
holds and the pruner keeps no second copy of anything. It also means `git hash-object` is
an independent implementation of the same number, which is what `just verify` compares
this against: a pruner that computed something slightly different would drop transcripts
nothing had ever read, silently, and they would never be scanned or archived. See
docs/verify.md.

The three that could not settle that way were exactly the redacted ones — the archive
holds the rewritten copy and the volume the original, so their bytes can never match.
Those settle on their ledger entry instead: a `redact` ruling keyed on the sha256 of
exactly these bytes, whose archive path is present, means the rewrite already there is
the rewrite this run would produce, under a gate the fingerprint says has not moved.
Without that they were re-read, re-redacted and re-proved on every collection for ever —
and the run said so, three lines about rewriting transcripts above a line saying nothing
had changed. Both true, and together a description of the machinery rather than of what
happened, which was nothing.

The rulings map is keyed path first and hash second, the opposite of the ledger's own
order. Two transcripts with identical bytes is not far-fetched here — a probe session is a
handful of lines and several are collected at once — and a map keyed on the hash keeps one
of them and silently drops the other's ruling. `just verify` found that, on a fixture
where two files happened to match.

`archived.py` partitions on the tab `ls-tree` puts before the path and nothing else:
splitting on whitespace would lose a path with a space in it, and losing it means the file
is scanned again, which is the harmless direction only by luck. A path that is not in the
listing, or is there under a different object, or has no ruling, is simply not printed — an
unreadable or absent archive, an unreadable ledger and a missing ruling all prune nothing,
which is the direction a mistake here has to fall.

Listing and removal are two steps, never one: `archived.py` removing files as it walked
would leave a half-pruned staging directory behind if it died partway, and those files would
be neither read nor archived. Printing first means a failure prunes nothing.

### What this would otherwise give up

A rule added today fires on transcripts collected months ago, and that is not
hypothetical: `1f916_sk_` went in on 2026-08-26 because one secret was caught in one
transcript and missed in another. Skipping the archived ones for ever would mean the new
rule never meets them. So the skip is allowed only while the gate is the same gate — and
when it is not, the next run reads everything again, once.

### What "the same gate" is made of

Every file in `host/archive/` — the six stages, the six Python programs, `archived.py`,
`archive-layout.py` and the gitleaks config — found rather than listed, because a list of
the ones that decide the gate stops covering the file added beside it and says nothing when
it does; the gitleaks *binary*, hashed rather than asked for its version, because Ubuntu's
build answers `gitleaks version` with "version is set by build process" and an upgrade
would go unnoticed; and
the secrets the volume holds, which change whenever the vault gains an entry or a key is
rotated — the layer that compares against those is the only one covering a shape nobody has
written down, and a new secret is a new shape. The secrets are hashed and never printed:
that is the one input that is the secrets themselves, and the fingerprint is written to a
file.

The fingerprint is host-side under `XDG_CACHE_HOME` and deliberately not on `sessions`: the
gitleaks binary is a fact about this machine, and a branch that is pushed would carry it to
one where it is false. A missing, unreadable or stale fingerprint reads everything, which is
the direction a mistake here has to fall — the cost of being wrong that way is nine seconds.

It is per agent, like the lock: it hashes *this* volume's secrets, so a directory two agents
shared would have each invalidating the other's on every run — never wrong, never once
useful.

It is recorded only by a run that read every transcript, and only once that run has got past
`detect` without dying. What the file claims is "everything now in the archive has been
through this gate", and a run that skipped part of the archive cannot claim it. A cache
directory that cannot be written costs nine seconds a run and nothing else, so it is not an
error.

### What the run says about it

"Clean" over 506 transcripts and "Clean" over the three of them anything looked at are
different sentences, and only one of them is true after a skip. So the read count is said
where the verdict is, and "as this run would archive them" is used rather than "unchanged": a
settled redaction is archived rewritten, so its bytes are deliberately not what the volume
holds. What is true of both kinds is that reading them again would produce what is already
there.

Nothing left to read is its own sentence, and the scanning heading is not printed above it. A
run that says "scanning", then "reading 0", then "clean" has described three things that did
not happen; what happened is that the archive is already up to date, and that is one line.
"Clean" is a claim about what was read, so a run that read nothing does not make it — saying
it twice in two vocabularies is how a report starts describing itself rather than the world.


## The commit

### The worktree, and why the commit is never made in the archive checkout

The transcripts live on `sessions`, an orphan branch, and the commit is made in a throwaway
worktree checked out on it — never in the archive's own checkout. That checkout is the
operator's: it may be on any branch and it may be dirty, and neither is this script's
business. Committing wherever HEAD happened to point is how transcripts end up on the tooling
branch, or on the mirror, where the next mirror run reads them as a rewritten history and
dutifully tags and resets them away.

A worktree left behind is not cosmetic: `worktree add` refuses the branch on the next run, so
every later collection fails. The one case the collection refuses outright is `sessions`
already checked out somewhere; git names that worktree in its own message, and forcing a
second checkout of one branch — or moving the ref under it — is how the other tree silently
starts reporting the new transcripts as deletions.

Files are placed one by one by the same map the pruner read, rather than by mirroring the
staging tree: the archive's layout is not the volume's. A held transcript was removed from
staging and is simply not there to copy, which is how it stays out.

A missing archive checkout stops the run loudly rather than cloning one. The URL would then
be written down a second time, next to the one in the clone's own origin, and the pair would
drift. A missing archive also costs nothing durable — the volume still holds every transcript
and the next collection re-copies them — so stopping is cheaper than a second archive
appearing somewhere unnoticed. Docker is checked before the volume probe, because a stopped
daemon makes that probe fail with a message saying the volume does not exist, which reads as
the agent's world having been lost rather than a service being off.

### Counting a collection's size

The count is taken after staging, from the index, because that is the only place the number is
exact. `status --porcelain` collapses an untracked directory into one entry, so a collection
that brought seven transcripts in two new session directories committed itself as
"(2 file(s) changed)" — measured on 2026-08-23, commit `31f2d96` of the archive. The count is
the only record of a collection's size once the files are indistinguishable from the rest, so
an undercount is a record that misinforms rather than a cosmetic slip.

`--no-renames`, because the default pairs a deletion with an addition of the same content and
prints one line for the two. Two transcripts with identical bytes is not far-fetched here.

The number of rewritten transcripts is counted from the staged diff, so it names what actually
moved into *this* commit. A redaction is re-derived whenever its transcript is read, which on a
full re-read is every one of them — and the count of rewrites was printed for all of it, above
a line saying nothing had changed. Two true sentences that contradict each other describe the
machinery; what the operator is owed is what happened, which was nothing. It is on its own line
and never folded into the clean count: a redacted transcript is not a transcript found to be
nothing, and one number for both would misinform about the only two outcomes the ledger exists
to tell apart.

Approvals and redactions are both counted when a ledger entry is written, even when one is
zero: "Recorded 3 approval(s)" alone reads as a run that had no redaction in it, and that is
the half worth being sure about.

### The push

`--set-upstream`, because the first collection into a fresh archive creates the branch here and
it has no upstream to push to yet.

"No change since the last collection" is not an exit when `--push`, deliberately: a commit made
by an earlier run whose push then failed — network down, origin refusing — would otherwise sit
unpushed until some later collection happened to have something new to say, and a backup that is
only attempted when there is something new is not one. Falling through re-offers it. The cost is
one no-op push on a collection with nothing to send.

A failed push is named rather than left to `set -e`. A push that fails after the commit
succeeded leaves the transcripts in the local archive and nowhere else, and the caller's message
— written for a run that archived nothing — would report that as nothing archived. It is also
the last chance to print what the gate held back, which exiting there used to skip. The message
does not say "committed but not pushed": this run may have had nothing new to commit and be
re-offering an older one, and what is true either way is where the transcripts are and where
they are not.


## Shell traps this file records

Several comments in the collection's stages exist only because a shell construct failed
silently. They are kept at their lines.

`note_flagged` ends with an explicit `return 0`. Ending on `[ -n "$1" ] &&` makes the function
return 1 when there is nothing to add, and under `set -e` that kills the script where it stands
— silently, after printing "Scanning for credentials ...". It only ever ran with something
flagged until the pattern stopped matching prose, and then every clean collection died. The
`read_note` block is an `if` for the same reason.

`|| true` on each grep in `detect` and in the report loop is load-bearing: grep exits 1 when it
matches nothing, which is the normal case, and under `set -o pipefail` that would kill the run —
in the report loop, right after printing the heading and before any of the guidance. It happens
whenever gitleaks is the one objecting, which is the common case.

`--held` returns before the worktree is created, and `just status` calls it every time it is
asked, so the cleanup variables are declared up front and the trap can name whatever path the run
died on.

The `gitleaks not installed` hint carries no version numbers on purpose: a number written into a
message ages silently and then misinforms.

The needler and the checker are executed with `__name__` set to `"needler"`, so the module's own
stdout block does not run on import. Needles are filtered for emptiness twice, because an empty
pattern line makes grep match every line of every file — which would hold the entire archive back
and read exactly like a catastrophic leak. Nothing is printed at all when there is nothing to
compare, for the same reason: a pattern file of one empty line is not an empty pattern file.

### The subagent legend was a race

`just sessions` decided whether to print its `+N marks subagents` line with `printf '%s\n'
"$shown" | grep -q 'msg  +' && …`, and on 2026-09-06 that printed the legend **once in six runs**
over the same 580 sessions. `grep -q` exits on the first match — row 61 here — and the `printf`
still feeding it then dies of SIGPIPE, which under `set -o pipefail` becomes the pipeline's
status, so the `&&` does not fire. Whether printf finishes its 50KB write before grep quits is
the race, and nothing about the output says which way it went.

It grew in with the archive rather than being wrong from the start: while the whole listing
fitted in one write there was no window to lose. Matched with a `case` on the variable now, which
starts no process and cannot lose. It was found by `just records --prove`, which diffs the
command against a renderer over the session records and had no reason to be intermittent.


## The count without the collection

`just status` asks the gate for the held count rather than carrying its own copy of the scan: two
implementations of one rule drift, and the one that drifts is the one nobody runs by hand.
`--held` stops before staging anything — no worktree, no commit — so it is safe to run beside a
live session, and it reads the volume read-only like everything above it.

It prints one machine-shaped line rather than leaving the caller to take the last line of the
output: above it are "Extracting ...", "Found N transcript(s)." and, when gitleaks is missing, a
nine-line installation hint. A caller taking the tail would take the hint.

Nothing to collect is a failure for a collection and an answer for a count: `--held` says
`waiting-on-review: 0`, because a caller that read a non-zero exit as "could not tell" would
report a fresh volume as a broken gate.

`just collect` declares no options of its own. `--approve <hash> <why>` and `--redact <hash> <why>`
take two values each and repeat, which a declared option cannot express, so everything reaches
`collect.sh` as it was typed — and a note is a sentence, which is why it travels as
`"$@"` and never as interpolated text.


## The status snapshot

`status-collect.py` gathers what only this host knows — whether a container is up, what the
crontab holds, what the account has spent, what the collection gate is holding back — and
`publish-status.sh` carries it to `status`, an orphan branch of the archive, in a throwaway
worktree, the same way `collect.sh` writes `sessions`. The dashboard's other half —
sessions, issues, articles, the archive itself — is already on GitHub and is read there by the
workflow that renders the page. Nothing is gathered twice.

`status-collect.py` is the only gatherer. `just status` renders what it prints and does not go
looking on its own; the publisher sends the same bytes to the archive.

### Nothing missing is zero

Every section carries its own `error`, and a section that could not be read says so rather than
reporting an empty count. A gate that did not answer is not "no limits"; a pending count that could
not be taken is not "none waiting". A page that renders silence as good news is worse than a page
that is down, because you believe it.

The collector exits zero even when sections failed, and deliberately: the failures are the payload.
A non-zero exit would stop the publisher, and the page would keep showing yesterday's snapshot with
no sign that anything had gone wrong. So what the publisher tests is whether there is JSON at all,
which is the only failure that leaves nothing to publish.

`run()` never raises, for the same reason: a collector that dies on the first thing that is not
answering produces no JSON at all, which on the page is indistinguishable from a host that is
switched off — and those two want opposite reactions from whoever is reading.

Docker is asked first and everything that needs it reads that answer. Not for tidiness: without it,
three sections would each spend their own timeout discovering the same silence, and the collector
would take minutes to say the one thing that was wrong.

### It asks the one implementation of each rule

The session facts come from `host/lib/session-lock.sh`, sourced through `bash -c` and never
reimplemented: the container name is one string that everything filtering on it must spell
identically, and a typo in a copy of it does not fail, it answers "nothing is running". One bash
invocation and not five, because five would sample the world five times — a session that ends
between the second and the third produces a report of a running session with no start time, which is
a state that never existed. See docs/sessions.md.

The budget comes from `claude-usage --env`, in the dialect that boundary file already speaks, so
putting the budget on a web page changes nothing about what stands a session down; both stdout and
stderr are captured because the gate splits numbers from the one line it writes when it cannot tell.
See docs/budget.md. The schedule comes from `just schedule --state`, which exists for exactly this —
what counts as paused is a `#PAUSED ` prefix that recipe writes, and a second reader of the crontab
would go on believing the old spelling; see docs/schedule.md. The deployment comes from `just deploy
--state`, the one place the branch name, the tag names and the path of the deployed checkout are
decided; see docs/release.md. The held count comes from `collect.sh --held`.

`session-stats.py`'s lines are carried through verbatim as strings — the cost, and since 2026-08-28
which model answered, which is the page's only witness to a downgrade. It has no machine dialect and
does not need one for this: parsing prose into numbers to print them as prose again is a decoder that
can be wrong, in front of a renderer that cannot be. It is asked with `--since`, so a session that has
not written its first line yet says so rather than reporting the previous session's numbers under the
heading of this one.

The image section reads the Dockerfile rather than a built image. The Dockerfile is what the next build
will use, which is the honest answer to "what is the agent running": an image built before the last edit
is a stale image, and that is worth seeing on the page rather than being told the digest of something
that no longer exists. An unpinned base is reported as an error because it is a fact about the boundary,
not a parse failure. See docs/image.md.

Model-scoped weekly limits are carried as prose and marked, because they are deliberately not gated;
`RENEWED=1` is surfaced rather than swallowed, because a page that never shows a renewal is a page that
cannot show the day they stop. `idle_minutes` of 999999 is the lock library's "no record since this
machine last forgot" and is not a duration, so it is carried through as null with a `forgotten` flag
beside it — otherwise the renderer prints 16666 hours.

The argument namespace is called `opts` and not `args`: the `session-stats` invocation below it already
binds `args` to its argument list, and the collision cost a run that produced no JSON at all — which the
publisher reads as "nothing to publish".

### The heartbeat does not read the budget

The usage endpoint rate-limited the account on 2026-08-25 and every unattended run stood down for three
hours. This collector was a third of the traffic, because the page's heartbeat asked for a fresh reading
every ten minutes whether or not anything had happened.

So `--no-budget` is the heartbeat's default and the publisher carries the previous reading forward with
the age of the *reading* rather than of the carry. `as_of` survives every carry: the first one stamps it,
the rest leave it alone — re-stamping would make a reading from an hour ago look ten minutes old, which is
the lie the timestamp exists to prevent. A budget that is twenty minutes old, labelled twenty minutes old,
is worth more than one that cost the session that could not start.

The reading is now taken where it is decided — at a session's start, by `just run` — and once more when the
session ends, which is `publish-status.sh --now`.

### The floor, and why publishing is cheap to call

`just run` calls the publisher every time cron wakes it — on `* * * * *` that is once a minute — and all
but one call in ten returns before doing any work at all. The stamp is checked first, ahead of the
collection, because collecting costs a container start for the budget gate: a floor tested after the
expensive part is not a floor. `--now` skips it, and that is what a session end uses, because the page
saying "a session is running" ten minutes after it stopped is the one staleness anybody would actually
notice.

The stamp is written through a function because it lives in a directory that may not exist yet and a
redirection does not create one: a stamp that silently fails to land reads as "never published", so the
floor stops holding and every run publishes again. A stamp from the future means the clock moved;
publishing once and moving on is the answer that does not wedge until real time catches up, which is the
same reading `session-lock.sh` takes of its own record. The stamp moves even when the snapshot is
byte-identical, so the floor is measured from attempts rather than from commits.

A non-blocking lock keeps two publishers apart. Cron can fire the next `just run` while this one is still
collecting — the gate takes a few seconds — and two publishers would race between reading the branch and
pushing over it; the second one has nothing to add that the first is not already carrying.

The publisher fetches and fast-forwards before pushing. Behind origin is normal and not a conflict: this is
the only writer, and a clone that has not fetched simply has an older tip. Failure there is not fatal —
offline is a fine state to publish from, the commit is made, and the next run pushes both. A failed push is
said on stderr so cron mails it, because a status branch that stopped reaching origin is a dashboard that
goes quietly stale while the host is perfectly well.

The commit subject's words are chosen rather than spliced: "a auto session" is what a `%s` does with the
kind, and this is a commit subject that stands in the log for good.

### Why there is no workflow dispatch here

It was written and taken out. The renderer runs on a schedule; dispatching it on every publish would be a
GitHub Actions run every ten minutes, about 4300 minutes a month against a free private allowance of 2000 —
so the page would stop updating near the end of every month, in the quiet way a spent quota does. The
schedule is the freshness knob and it is in the workflow, where it can be read.

`dispatch-mirror.sh` records the same arithmetic reaching the opposite answer, and the difference is only
that this one would have dispatched every ten minutes.


## The config branch

`just deploy` backs this installation's own three files — `image/config/vault-exempt.txt`,
`image/config/secret-shapes.txt`, `image/config/community.txt` — up to `config`, an orphan branch
of the archive, once the deploy has succeeded. They are untracked by design, so
nothing else keeps a copy of them, and what they hold is rules that were decided
once and would have to be reconstructed from memory. `just setup --restore`
reads them back. See docs/configuration.md#the-three-files-that-are-yours.

`host/release/config-backup.sh` is `publish-status.sh`'s shape, for its reasons:
a throwaway worktree so nothing is checked out over the archive's own working
tree, the three branch cases in the same order — local, origin-only, not yet
created — a `cleanup` trap, because a worktree left behind makes every later
backup fail on the same path, a fetch and fast-forward before the push since
this is the branch's only writer, and a non-blocking lock.

**On the deploy and not on a timer.** A deploy is when a change to those files
takes effect: before it, the branch would hold something nobody is running, and
a periodic backup would carry an edit that was still being thought about. It
runs after the image, the crontab and the schedule are all back in order, and a
failure there is a line on stderr rather than an exit code — the deploy is done,
and reporting it as failed would be the wrong answer to a very different
question. Nothing is committed when nothing changed, which is most deploys.

**`.env` is never carried.** It holds `BWS_ACCESS_TOKEN`, the key to every other
secret this installation has, and the archive is a repository like any other.
The three files hold rules and no values.

## The listing

`just sessions` prints the archived sessions newest first; `just read` opens one, by its number here or by
its own id. Both build the table through `archive_rows` in `host/lib/archive.sh`, which is the one place it
is built: the number a listing shows and the number `read` takes are then the same handle by construction
rather than by two orderings agreeing.

Both only read. `sessions` is written by `just collect --push` and by nothing else; the branch is read with
`git show`, never checked out, so the archive clone stays on whatever branch it is on. `need_archive` uses
`rev-parse` rather than a test on `.git`, which is a directory in a clone and a file in a linked worktree —
`collect.sh` checks it the same way and for the same reason. The refusal sentence lives in
`host/lib/archive.sh` for the recipes that only read; `collect` and `publish-status` carry their own,
because theirs is reached deep inside a run that has already extracted transcripts and the sentence belongs
where the work stops.

The local branch is preferred over `origin/sessions`: `just collect` runs on this host and commits locally,
so the local one is the one that is ahead.

### A subagent is not a session

A sub-agent writes a transcript of its own beside its session, as
`<session-id>--agent-<agent-id>.jsonl`, and it is not a session: listed as one it is a row with no title
that nothing accounts for, and its output would be counted twice — once as itself, once inside the session
that spawned it. So the two lists are separated, and the session and whatever it spawned go through
`session-meta.jq` together: their requests and their output belong to it, and the reduce tells them apart by
`isSidechain`.

`+N` marks a session that spawned subagents, in its own column rather than appended to the title. Nothing
else on the row says they exist: the messages and tokens are cumulated into the session's, so a session that
did half its reading through an agent looks exactly like one that did it itself. The legend is printed only
when one is on screen.

### Newest first, and what a number means

Newest first on the local date and clock the row carries: the session you want is nearly always the last one
that ran. The price is that a number is a handle for the moment you listed and not a name — the next
collection pushes everything down by one — which is why a read prints the uuid.

Rows are numbered before anything is dropped. The number is a handle into the whole list, so `just read 137`
has to mean the same thing whether or not 137 was on screen; a row numbered within its own page would
renumber every time the page changed, which is a handle that lies.

### Where the clock and the path part company

The row shows the local day the session started, and the archive files the file under its UTC day and always
will, so the two part company either side of midnight. The count of rows where they differ is read off the
path rather than carried as a second field: the path is the archive's own answer, and it is the one printed
beside a session when you read it.

`--day` matches as a substring, so `--day 08-26` and `--day 2026-08-26` both work — one of the two is what
anybody types and guessing which would be wrong half the time.

The footnotes each name something you would otherwise go on not knowing: a transcript nothing could date
(counted rather than dropped in silence, since it would sit at the top of the list with no day against it), a
collection that never left this machine, and a day on screen that is not the day in the path.

Paging happens only when someone is watching and only when there is more than a screenful: piping this into
grep or a file must not hand the output to `less`, and neither must a list of six. `page` is 20 because that
is what fits above the prompt on an ordinary terminal with the header and the footnotes.

### What `session-meta.jq` measures

One streaming pass per transcript — `reduce inputs` rather than `-s`, so a long session is never held in
memory whole: these grow without bound and the list must stay cheap enough to run reflexively.

The date and the time are local and everything the transcript stores stays UTC: a time read by a person is
read against the clock in the room, and a time the agent is given, or a path the archive files a session
under, is not. `[0:19]` is taken before the parse because `fromdateiso8601` rejects the fractional seconds a
transcript carries; `try`/`catch` falls back to the raw UTC slice, since a row that will not render is worse
than one an hour out.

`aiTitle` is Claude Code's own summary of the session and the only human-readable label there is;
`entrypoint` separates the unattended runs (`sdk-cli`, from `claude -p`) from a session the operator opened
(`cli`). Turns exist only where someone took them: an unattended run is headless and has none, and there the
elapsed time *is* the working time — printing it twice under two names would be the lie, not the omission.

Three traps, all silent, all measured and written up in `host/session/session-stats.py` (see
docs/sessions.md):

- Assistant records are streaming snapshots. Several carry one `requestId` and a usage that *grows* across
  them, so they are keyed by `requestId` and the last one wins. Counting records instead inflates both the
  request count and the output by more than two.
- A sub-agent is cumulated — its requests and its output are the session's — but its *context* is not, and
  that is the one number that must not be: every agent has a context of its own and adding them together
  names nothing that ever existed. `isSidechain` is what tells the two apart, in whichever file the record
  arrived from.
- Cache reads are left out on purpose. They are the same context re-read once per request, which reads as
  catastrophe and says only turns by size. They stay in the transcript, so a cost can still be worked out
  later.

The archive's own dashboard workflow keeps its own copy of this file beside `render.py`: that action runs in
the archive checkout and cannot reach this tree. The measurement is written here rather than shared with
`host/session/session-stats.py` because that one reads the live volume through a container and this reads a
blob in git.


## The mirror

The mirror is a copy of the agent's own memory repository, kept in the archive at
`refs/archive/<agent>` by a workflow there. `just mirror` reads its health; `dispatch-mirror.sh` asks it to
run when a session ends.

Everything `mirror.sh` does reads. The two records the archive holds have exactly one writer each — `just
collect --push` for `sessions`, the mirror workflow for `refs/archive/<agent>` — and a second writer on a
record whose whole value is that it has one would be the end of it. Both are read through `git show` and
`git for-each-ref`, never checked out.

### A ref, not a branch

GitHub starts workflow runs from the pushed ref, and this ref carries the agent's tree — including the
workflow files it writes in its own repository. On a branch or a tag one of those saying `on: push` would
execute in the archive, with the archive's secrets. Only `refs/heads/*` and `refs/tags/*` trigger, so a ref
outside both is one that can be stored and never run.

The cost lands on the reader: it is not browsable on github.com, which lists branches and tags and nothing
else. `just mirror` is how you read it.

The archive namespace is asked for explicitly on every fetch. A clone's default refspec is
`+refs/heads/*:refs/remotes/origin/*`, so `refs/archive/*` arrives only when named — and everything in the
report would otherwise say "the mirror has never run" on a perfectly healthy mirror. A status read off stale
refs is worse than none, so the fetch is the first thing and a failure says so rather than being swallowed.

The tip's commit date is the *agent's* activity, not the mirror's health: the ref only moves when the agent
pushed something, so a week of silence is a quiet agent, not a broken mirror. The workflow section is what
reports health.

### Rewind marks

A mark under `refs/archive/rewound/` means the upstream history was rewritten and the tip we held was
preserved before the ref was reset onto the new history. That is the one thing this archive exists to catch.

They are plain refs and not annotated tags: a tag lives in `refs/tags/`, and that namespace triggers
workflows on push for the same reason a branch does. A plain ref anchors the objects just as well —
reachability does not care what a ref is called. What a tag's message used to carry is derived rather than
stored: `held` is the mark's own sha and `replaced by` is the current tip, so there is nothing left to fall
out of step with the refs themselves.

Every read of a mark peels with `^{}`. A mark is normally a commit, but one made by hand is an annotated tag
object — and without the peel, `held` would print the tag object's sha, a real sha of the wrong object, in a
field nobody would think to doubt. `<ref>..<mark>` is exactly the commits the rewrite dropped: reachable from
the preserved tip, not from the ref now.

"No marks" is deliberately not reported as "upstream never rewrote anything". Marks record what a *run* saw,
and a rewrite between two runs leaves none — which is what the comparison against the source is for.

### Health, and the state field

`state` is the field that matters most and the one nothing else reveals: GitHub disables a schedule after 60
days of repository inactivity, and a disabled workflow fails by never running, which looks exactly like an
agent with nothing to say.

`gh` writes an error body to *stdout*, so `2>/dev/null` hides only half of a failure and the other half is
captured as if it were the answer. The exit status is the only thing worth testing.

The mirror is scheduled hourly and GitHub drops scheduled runs under load, so a missed hour is normal and six
in a row is not: past that runs are being skipped or failing, whatever the last conclusion was.

### Against the source

The mirror can be healthy and still be behind, so `just mirror` asks the forge what upstream actually holds
right now. `diverged` is the interesting answer — a rewrite has happened that no run has seen yet, and the
next run is what preserves it.

Two failures of that call are not noise but the loudest signals the recipe has. "No common ancestor" means the
forge is saying the two histories share no root at all — a replacement rather than a rewrite, which is what
re-seeding a repository looks like; the mechanism handles it identically, and this is the window in which
nothing has recorded it yet. "Not Found" means the mirrored tip is no longer known upstream: a tip upstream
cannot find is itself the signal, it was rewritten away and garbage-collected, and only our copy holds it now.

Slugs are derived, never written down twice. The archive's comes from the remote; the source's from the
workflow file, which is what actually decides what gets mirrored. Three `sed` substitutions rather than one
capture: ERE has no lazy quantifier, so the tempting `([^/]+/[^/]+?)(\.git)?$` leaves the `.git` on — and the
slug then 404s in a way that reads as "no access".

### Asking the mirror to run

The mirror is scheduled `19 * * * *`, and GitHub runs schedules on a best-effort basis. Measured 2026-08-27,
the last five runs were 03:22, 22:18, 19:19, 17:17 and 15:53 — gaps of five hours, three, two. That cadence is
the mirror's fidelity knob and its only one: a rewrite upstream can only be preserved back to the last run, so
a commit that appeared and was rewritten away inside a dropped gap was never seen and is gone. A session end is
the moment the memory actually moved — `push-on-exit` has just pushed it, see docs/backup.md — so it is the
moment worth asking on, and the only one this host knows about that GitHub does not.

The cooldown counts *every* run rather than only the ones dispatched from here. The schedule still fires; if
this only remembered its own dispatches, a session ten minutes after a scheduled run would start a second one
for nothing. Counting whatever ran last — cron, dispatch, someone pressing the button — is what keeps the total
at about one an hour instead of one an hour plus one a session. That matters because the archive is private and
Actions minutes there come out of a free monthly allowance.

An unset or empty cooldown dispatches every time, deliberately. This is a cost knob and not a guard, which is
the opposite of `ACCOUNT_BUDGET_*` (see docs/budget.md): there an unreadable threshold must refuse, because the
thing it protects is the operator's week and spending it is the irreversible direction. Here the irreversible
direction is a mirror that did *not* run, and an extra run costs a minute of a free allowance. So every reading
this cannot make — no value, a value that is not a number, no answer from `gh run list` — falls towards running
the mirror and says so out loud.

In-progress runs count, which is what we want: a mirror that started a minute ago and is still going has run. A
dispatch takes a few seconds to appear in `gh run list`, so a cooldown of one or two minutes would sometimes
miss the run it just asked for; nothing guards against that, because the value this is for is an hour. A
negative age — GitHub's clock ahead of this one — reads as "ran just now" and skips, which is the safe direction
here: a skipped dispatch costs an hour of fidelity the schedule still covers, and no clock skew makes a mirror
wrong.

`gh workflow run`'s own stdout is held back: it says "Created workflow_dispatch event for $WORKFLOW at main",
which is the script's own line with more words.


## The archive's setup

`just archive-setup` runs on the host with the operator's own credentials. Nothing about it is the container's,
and the agent is never told any of it. It is idempotent, and it touches four things: the archive clone at
`AGENT_ARCHIVE`; that repository's Actions token, which defaults to read-only; a fresh read-only deploy key on
the agent's repository; and that key's private half, stored on the archive as `<PREFIX>_SOURCE_KEY`.

The clone lives inside the project and is gitignored, like `deployed/`: a demonstration that can be cloned and
run must arrange nothing outside its own directory. `AGENT_ARCHIVE` stays overridable for a sibling layout, and
an installation that already has one keeps it. The two records live on refs the default refspec never fetches —
one orphan branch and one ref outside `refs/heads/*` — so they are asked for by name once at setup, and `just
sessions` and `just mirror` have something to read.

### A deploy key, and who owns it

A deploy key rather than a token: it is read-only, it is scoped to that one repository, it cannot act as any
account, and it does not expire. The raw API is used rather than `gh repo deploy-key`, because it takes
`read_only` as an explicit argument instead of a default and its output does not shift between gh versions. Keys
are immutable, so rotation is delete-then-add, and only keys matching the title are removed: anything else on
that repository is not ours to remove.

That step needs *admin* on the agent's repository, which a collaborator does not have. On this installation it
never will: the agent's account is reachable only through a browser, in a private session, so the API path
cannot run here at all and adding the key by hand is not a fallback but the normal path. Setup prints the key,
says nothing has changed yet, and waits.

### The key goes on before the secret goes in

The public half is installed and **proved to read** before the private half replaces the secret the mirror is
running on. A run that cannot finish therefore changes nothing, and the mirror stays on the key it has.

It was written the other way round until 2026-09-06, and the cost was measured rather than imagined. On
2026-09-03 at 17:30Z `just setup-archive` was run as part of going live with a new runner. It wrote the new
private key to the archive, then found it could not install the matching public half — no admin — printed *"The
secret is already set; only this half is left"*, and **exited 0**. Every mirror run from 18:41 that day failed
`Permission denied (publickey)`: 58 consecutive failures, three days, 245 commits of the agent's memory not
mirrored. Nothing said so. `just mirror-status` was run two commands later and looked healthy, because the ref
was still current at that moment; it only went stale from the next hourly run. The `ls-remote` check that would
have caught it existed already — inside `if [ "$deployed" = true ]`, the one branch that did not need it.

Three things changed as a result: the order above; the check runs on every path; and **nothing is deleted from
here**. Rotation used to be delete-then-add, because keys are immutable — which destroys the running credential
first and cannot run at all without admin. Superseded keys are named at the end for the operator to remove once
the next run is green.

`ssh -T` against github always exits 1 for a deploy key, so it proves nothing. A `ls-remote` does: it is exactly
what the workflow runs.

### The workflow token cannot be the Actions token

An Actions token may never push a commit that creates or updates a file under `.github/workflows/`. There is no
permission that allows it: `workflows` is not a key in a workflow's `permissions:` block, and the push is
rejected outright — "refusing to allow a GitHub App to create or update workflow". Measured 2026-08-26, with a
control push that showed the restriction follows the *file* and not the ref, so moving the mirror out of
`refs/heads/*` does not avoid it. The day the agent added a workflow to its own repository, every mirror run
failed from that moment.

It cannot be minted from the API either — fine-grained tokens are a UI-only flow — so setup asks for one rather
than creating it.

The two credentials this workflow holds point opposite ways and belong to opposite accounts. The deploy key
*reads* the agent's repository and is the agent's, because a deploy key needs admin there. The token *writes* the
archive and is the operator's, because the agent has no access there — and must not: a token that writes this
repository is a token that writes the place every other secret is kept. That is also why it is scoped to one
repository and not "All repositories".

The setup prompt warns about the avatar before you start: the deploy key step asks you to log in as the account
that owns the source, and if you are still signed in as it, the archive owner will not be in the Resource owner
list and the archive will not be in the repository list. That reads as "the repository is missing" and is really
"you are the wrong person".

A workflow cannot request more than the repository grants: with the default left at "read",
`permissions: contents: write` is ignored and the push fails with 403 at the very end of an otherwise successful
run. So setup raises the repository's default workflow permission itself.

The expiry is read with `gh api -i`, because it is a response header and nothing else reports it; `-i` and `--jq`
do not combine, since `-i` puts the headers into the body `--jq` is handed, so it is two calls each asking one
thing. No expiry header means a classic token rather than the fine-grained one asked for, and almost certainly
far broader than one repository.

Whether the token may push a *workflow* file is the half no read can prove, and it is the half this exists for. A
token with Contents and without Workflows passes every check and fails only at the first run after the agent
touches a workflow file — which can be months of looking fine. Running the mirror once by hand is what settles it,
which is why it is step 2 of "Left to do".

`gh secret set` reads standard input when `--body` is absent, and `--body -` would store the literal string `-`.

### A quoting trap in three files

No apostrophe may appear in a `${var:?word}` message. Inside `${var:?word}` bash opens a single quote even within
double quotes, and the script then fails to parse at its last line with an error naming neither the line nor the
quote. `setup.sh`, `dispatch-mirror.sh` and the messages beside them are written that way.
