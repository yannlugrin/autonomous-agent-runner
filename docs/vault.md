# Vault

## What it is, and what to set

The agent needs credentials — a token for its own GitHub account, its ssh key,
the Claude login it runs on, whatever an API it is given wants — and none of
them may sit in this repository, in `.env`, or in the image. The vault is
Bitwarden Secrets Manager, reached from inside the container through one
wrapper, `/usr/local/bin/vault`. Its point is that **a new secret costs you a
paste and nothing else**: no new variable, no rebuild, no restart.

All five are `.env` values:

| handle | what it does |
| --- | --- |
| `BWS_ACCESS_TOKEN` | the machine-account token. It **opens** the vault and is not one of the secrets in it. Bitwarden shows it once and never again; a lost one is re-issued, not recovered. Unset is not a failure — the vault is simply not configured, and `vault` says so in those words |
| `BWS_SERVER_URL` | which Bitwarden server issued it. Empty is the US one; the EU is `https://vault.bitwarden.eu`, and an EU token on the US default is refused as `invalid_client`, which reads exactly like a bad token |
| `BWS_VAULT_READABLE_PROJECT` | the **read-only** project, `<agent>-provisioned` unless set. What you hand the agent |
| `BWS_VAULT_PROJECT` | the **writable** project, `<agent>-acquired` unless set. What the agent acquires for itself |
| `BWS_VAULT_TEST_PROJECT` | `<agent>-test` unless set: the fixture project, which `--test` on any command makes the *only* visible one |

`<agent>` in those three defaults is `AGENT_USER` — `AGENT_NAME` lowercased,
spaces closed up — so creating the three projects under that name is all the
naming there is to do. A free Bitwarden account is capped at three projects,
and these are the three. One machine-account access token opens them, scoped
read on the first and read and write on the second. Creating those projects
and issuing that token happen once, in Bitwarden's own UI, before the first
build; `README.md`'s *Before you start* is where that sits in the order.

**To give the agent a secret:** put it in the **provisioned** project, from
Bitwarden's own web UI, under any name you like, with the "what it is for" in
the secret's note. Nothing here is rebuilt or restarted for it. Then tell the
agent that name — `just chat "there is now a <name> in the vault, it is for
…"` — which is the one channel its own rules treat as direction. From inside,
`vault list` shows every secret it can read as name, `rw` or `ro`, and note;
`vault get <name>` fetches it, caches it, and prints the **path** to it;
`vault get <name> --value` prints the value, which reaches the transcript and
is therefore the discouraged form. Three names are
fixed by code rather than chosen: `claude-oauth-token` is what a session runs
on, `github-ssh-key` is the private key the entrypoint restores on an empty
home instead of generating a new one nobody has seen, and `vault gh-login
<name>` is how `gh` is authenticated — README uses `github-token-own-account`
for that one, and the entrypoint's greeting suggests the same.

**The rule.** `bws` itself is denied, by the `PreToolUse` guard and by the
managed deny list, which name the same act. So `vault` is the only route — and
that matters because every fetch and every store lands in `~/.cache/vault`
first, which is what gives the commit check a file to compare a commit
**verbatim** against, and what the transcript scan knows to redact. A
credential that went through `vault` is compared exactly; one that did not is
compared only by shape.

**Writing reaches only the acquired project.** The agent can store a token it
obtained for itself, and replace one it stored before, and cannot overwrite one
you provisioned — asking you is the way to change one of those. `vault put`
requires a `--note`, because a key alone is a guess and the guess is made
months later by someone who no longer remembers, and it reads the value from
**stdin**, so it never touches a command line or a transcript. There is no
delete verb: `vault clear` only removes cached files, and nothing in the vault
is ever deleted from in here.

**What it does not claim.** `BWS_ACCESS_TOKEN` is in the wrapper's own
environment, and there is no way to hold it out of reach: the container is
unprivileged with `no-new-privileges`, so nothing in `vault.sh` can read a file
a session cannot. A session that hand-rolls the Bitwarden API with `curl` goes
past all of this. The deny turns that from the obvious thing to type into a
deliberate detour — it is not a wall, and the agent is owed the true version
rather than a claim that it is one.

## How it is built

The agent's secrets live in Bitwarden Secrets Manager, and `image/vault.sh` is
the only route to them: `bws` itself is denied, by the `PreToolUse` guard and
by the managed deny list, which name the same act. Three projects are in play
— a read-only `-provisioned` one the operator fills, a writable `-acquired`
one the agent stores into, and a `-test` scratch project that `--test` makes
the only visible one. Every fetch and every store lands in `~/.cache/vault`
first, which is what gives `image/bash-guard.py`'s rule 10 a file to compare a
commit against. `image/config/vault-exempt.txt` names the vault entries that are not
credentials; it is untracked, and `just setup` makes it from
`image/config/vault-exempt.example.txt` — see
[configuration](configuration.md#the-three-files-that-are-yours). `image/vault-env.sh` is the one place this container's Claude
login is decided, and both a session and anything started with
`--entrypoint` exec through it.

"Not configured" is a distinct state and is said out loud: with no
`BWS_ACCESS_TOKEN` in the environment, `vault` refuses with a message naming
`.env` as the operator's to set, rather than behaving as though the vault
were empty.


## What the wrapper does not do

`BWS_ACCESS_TOKEN` is in the wrapper's own environment and there is no way to
hold it out of reach: the container is unprivileged with `no-new-privileges`,
so nothing in `vault.sh` can read a file a session cannot. A session that
hand-rolls the Bitwarden API with `curl` goes past this file and everything
above it. The deny turns that from the obvious thing to type into a
deliberate detour. It is not a wall, and the agent is owed the true version
rather than a claim that it is one.

`image/vault-env.sh` makes the same admission about the value it exports:
`CLAUDE_CODE_OAUTH_TOKEN` in a process's environment is readable by
everything downstream of it. **The operator ruled on 2026-08-25 that this is
acceptable** — a session that can read a secret can already write a script and
run it, so the token is not a secret from the session and nothing pretends
otherwise.


## A key is not unique

Bitwarden lets two secrets share a name. Measured 2026-08-25: two rows called
`dup-probe` in one project, and `first` over an unordered list then picks one
of them silently. Reading an arbitrary one of two credentials is the worst
available behaviour — it works, until the day it returns the other, and
nothing in between says which it gave you.

So `fetch` counts the matches before it reads one, and refuses above one.
`put` asks the same question in two directions: whether *any* row of that name
sits in a project it may not write (a namesake in the read-only project would
otherwise be quietly edited or refused depending on which row came back
first), and whether more than one sits in the writable one. `vault list` marks
a shared name outright, because two identical names in a column of names is
exactly the thing an eye slides over.


## A truncated note read like a complete one

`vault list` capped each note at 120 characters. Measured 2026-08-25: a note
ended mid-word with nothing saying it had been cut. The cap looked like
tidiness and was data loss — and this list is the only place a note is ever
read, since `get` prints a path or a value, `put` writes one, and `bws` is
denied, so what the cut dropped had no other route. The note is now flattened
to one line and not cut; it is the last column, so a long one makes a long
line and nothing else.


## `get` prints the path, and was read as printing the secret

The name says "get" and the behaviour says "path". Measured: a session asked
to run `vault get` **refused**, on the belief that it prints the secret — and
then offered `vault get k | gh auth login --with-token`, which would have
piped the filename in as the token.

The path goes to stdout so `"$(vault get k)"` keeps capturing it alone, and
the sentence that stops it being misread goes to stderr, where the transcript
still records it. `--value` exists for when the value really is wanted on
stdout and says in the usage text that the transcript is archived.

The mirror of this is `put`, which reads the value from stdin and refuses it
as an argument: a command line is recorded in the transcript exactly as
typed, so `vault put k s3cr3t` would archive the secret in the act of storing
it.


## The gh token: what it is for, and what bounds it

The runner needs no GitHub token. git reaches GitHub over the agent's ssh
key, the backup pushes over it, and the archive is written from the host with
the operator's own login. The token is for the agent's *work*: reading the
API — issues, pull requests, comments, its own repositories and the ones it
follows — and writing where its correspondence lives. It belongs to the
agent's own account, is stored in `<agent>-provisioned` under
`github-token-own-account`, and reaches `gh` through `vault gh-login`, on a
pipe, never on a command line, a transcript or the volume.

**What to grant it.** A fine-grained token scoped to the repositories the
agent works in, with issues and pull requests read and write, contents read
(write comes over ssh), and metadata; or a classic token with `repo`. The
runner does not narrow it: what the token *may* do is the account's
boundary, and what a session *does* with it is bounded from here — `gh
auth` verbs that would read the token back out or repoint it are denied by
the guard, and every `gh api` call that would write asks, which unattended
is a refusal. A token that expires is preferred, and its expiry is a date to
keep: `just verify`'s `session login` verdict reports the Claude credential,
not this one, and the first symptom of an expired gh token is a session
that cannot read an issue it was asked to answer.

## `gh-login` and `gh-secret` exist because the spelled-out form is refused

`cat "$(vault get k)" | gh auth login --with-token` is a compound with a
substitution in it. It matches no single permission pattern, so it falls to
auto mode's classifier — measured, and refused. One allowed command does what
three could not, and it also means `gh auth` stays denied to the session in
every spelling, login included: the capability is in the wrapper, and the
credential crosses neither a command line, a stdout, nor a transcript.

`gh-secret` is the same reasoning with one word changed. A workflow needs its
credential in GitHub's own Actions store, and both obvious spellings fail
differently: `gh secret set NAME --body "$(cat "$(vault get k)")"` writes the
credential onto a command line the transcript records verbatim, and
`gh secret set NAME < "$(vault path k)"` is a substitution and falls to the
classifier — **measured refused on 2026-08-26, twice, deterministically
(#43)**. `Bash(vault:*)` already allows the wrapper, so this needed no new
permission rule, no guard rule and no change to the boundary.

**What it grants, said plainly.** Any vault secret a session can read can be
copied into an Actions secret, where a workflow can use it — so a credential
can leave this container's blast radius for GitHub's runners. **Ruled
acceptable by the operator on 2026-08-26**: a session that can read a secret
can already send it anywhere, in a container with open egress and a Python
interpreter, so this is not an escalation of reach. It is the same value in a
place the operator owns, can see in the repository's settings, and can rotate
or delete.

`--test` fetches the fixture and stops before the write. A scratch value
written into a real repository's Actions store is a real write, and a
rehearsal that can do that is one nobody dares run.


## A leading hyphen defeated `bws`

`bws` is clap, and a value that **begins with a hyphen** is read as a flag.
Every PEM begins `-----BEGIN`, so the wrapper could not store a private key in
its standard form at all. Measured 2026-08-25:

    error: unexpected argument '-----BEGIN PRIVATE KEY-----' found

and it is the leading hyphen alone — multi-line stores fine, 119 bytes stores
fine, `-abc` does not. The cure is the `--value=` / `--note=` form with the
equals sign, and `--` before the positionals: both make the parser take the
rest literally.


## A guess printed as a diagnosis

`put`'s failure message used to assert a write-scope problem outright. It was
wrong the one time it mattered: the cause was the leading hyphen above, write
access worked, and the guess sent a session to the operator with a scope
question they would have had to investigate.

Two things followed. `bws_said` now captures what `bws` itself said and prints
it, rather than a wrapper's guess in its place — `2>/dev/null` had been on
both write branches, throwing the real words away. And passing them through
verbatim is not safe either: a clap parse error **quotes the argument it
rejected**, so the failure that started this would have printed the private
key into a transcript in the act of reporting that it could not store it. The
value is redacted out by name, which is possible only because it is in a
variable at that point.

The same shape appears in `list`: `secrets_json` and `projects_json` are
captured and their status checked before `jq` sees them, because `die` inside
a command substitution exits the subshell only — the script carried on with an
empty string, `jq` complained that `--argjson` was not JSON, and the wrapper
printed "could not read the secret list" over the top of the real reason.


## Replacing a secret, and where that was ruled

Replacing an existing key was refused outright at first. That was one
mechanism too many: the read-only project is already what protects a secret
from being rewritten, and a second rule saying the same thing only got in the
way of the ordinary case — a credential that was rotated and needs its new
value stored under the name everything already refers to.

**The operator's ruling, 2026-08-24:** what should not change goes in the
read-only project, and moving a key there is a thing to ask them for.
Replacement is allowed, and only inside the writable project.

There is no version history on this plan, so a replacement is final. That is
the cost of the ruling, and `put` says "replaced" rather than "stored" so a
transcript records which of the two occurred.


## `put` did not follow the cache

Until 2026-08-25 only `get` wrote the cache. Two things were wrong while that
was true. `vault path k` went on naming a file holding the **previous** value,
silently, so a rotated credential could be handed out superseded. And the
claim that rule 10 covers a fetched secret because it lands in a file was true
of `get` and never of `put` — a secret this container generated and stored was
caught by shape alone, exactly the case the verbatim layer exists for.

`cache_write` is now the one place a value reaches disk, and both branches of
`put` call it after reporting the store: the store has already happened and is
worth reporting even if the cache write then fails.


## Fixtures have their own cache directory

The cache is keyed by name, so one directory for both modes meant a fixture
and a real secret of the same name shared a file: `vault get k --test`
overwrote the cached real `k`, and whatever was handed `$(vault path k)`
afterwards got the fixture — the mix-up `--test` exists to prevent, arriving
by the back door. Fixtures now live under `$CACHE/test`, which also keeps them
out of rule 10: the guard reads the cache root and skips anything that is not
a file, so it compares commits against the real secrets and not against test
values.

`clear` has no `--test`, and refuses it rather than reinterpreting it. Under
the rule the flag follows everywhere else — the scratch project *instead of*
the others — `clear --test` would mean "delete every cached key that is not a
fixture", which is every real credential in the cache. The plain command
already removes fixtures, because a fixture is by definition in neither real
project.


## The restored private key was one byte short

`fetch` writes with `printf '%s'`, and `VALUE` comes back from a command
substitution, which strips trailing newlines anyway — so the cached copy of a
private key is one byte short of what OpenSSH accepts. Measured 2026-08-25:
the 386-byte form is rejected with `error in libcrypto`, which reads as a
corrupt or wrong key and sends you checking the vault rather than the byte
count. `ssh-restore` normalises the newline once, where the file is written.

The key is also written and **proved** beside the real one before being moved
into place. A restore that overwrote a working key with something the vault
could not parse would take a container that merely had no login and turn it
into one that cannot reach its own repository — and the entrypoint calls this
before it knows whether the value is a key at all.


## The ssh greeting is the second line

`ssh -T git@github.com` exits **1 on success** — GitHub answers and then
refuses the shell — so the status says nothing and the greeting says
everything. Reading the status would report every successful restore as a
failure.

Measured 2026-08-25: on a home this fresh, `known_hosts` is empty, so
`Warning: Permanently added 'github.com'` is line 1 under the `accept-new`
policy and the greeting is line 2. Reading line 1 reported every first restore
as unrecognised, which is the one run where a false alarm costs the most. The
greeting is now selected out of the output with `grep -m1 '^Hi '` rather than
taken as its first line.

**Exit 3 is "restored, and GitHub refused it"**, and it exists so the
entrypoint can tell that apart from "nothing was restored" (1) without
grepping the output. The two want opposite things: nothing restored means
generate a key, and a restored key GitHub refuses must be **kept** —
generating over it trades one identity the account does not know for another
and loses the fingerprint that says the vault copy is stale. It is raised only
when GitHub *answered* `Permission denied`; `ssh -T` cannot distinguish a
refused key from an unreachable host by exit status, so an unreachable host
stays exit 0 and the clone that follows reports it itself.


## An identifier held five transcripts

The vault decides what a secret is, because the keys are not known to the
image — that is what a vault the operator can add to without touching the
image means. The cost is that anything stored there is treated as a secret by
both checks, and an identifier stored beside a token holds transcripts and
refuses commits for no reason. **Five transcripts were held on a Cloudflare
account id on 2026-08-26.**

`image/config/vault-exempt.txt` is the answer: one line per entry that is an
identifier rather than a credential, with a required note in the same spelling
`vault put` and `just collect --approve` require one. It is untracked — it names
an installation's own secrets — and `image/config/vault-exempt.example.txt` is the
committed header beside it; see
[configuration](configuration.md#the-three-files-that-are-yours).

**What it does and does not switch off.** It removes the entry from the
verbatim comparison only — the layer that says "this *is* the byte string the
vault is holding". Every shape rule still runs over the same text on both
sides, so a key rotated into something with a credential's shape — a `ghp_`,
an `sk-ant-`, a PEM body — is caught anyway. An exemption cannot make a real
token invisible; it can only stop an identifier being mistaken for one.

**Why it is not the vault's own note.** The note would be the obvious place
and is the wrong one: a key the agent may write is a key whose note the agent
may write, and then the confined agent decides which of its own secrets the
checks ignore. The file is in the operator's repository, which the agent reads
and never writes — the same reason the guard and the backup live there.

It is read by two things that cannot see each other: `image/bash-guard.py`
from the copy baked into the image, and `host/archive/read-volume.sh`
from this file in the checkout. One list, because two would drift and the one
that drifted would be the one nobody edited.


## Where the container's Claude login comes from

`image/vault-env.sh` exists rather than four lines at the end of
`entrypoint.sh` because two different jobs were fused in that script:
bootstrap — git identity, the ssh key, the clone, the trust dialog — and "what
credentials does this container run with". Only the first has side effects,
and only the first can fail in a way that should stop a session.

The budget gate needs the second and must not have the first. It is started as
`docker compose run --entrypoint …`, from the host, to decide whether a
session may begin — so running it through `entrypoint.sh` would have `just
status`, a read, **clone a repository**, and would report a bootstrap failure
as "the gate could not tell". The bypass was right; what was wrong is that the
credentials went with the bootstrap.

**Measured 2026-08-25:** Claude Code prefers `CLAUDE_CODE_OAUTH_TOKEN` over
`~/.claude/.credentials.json`, and so does `claude-usage` — a gate reading the
file while the session read the variable answered "within budget" for a
session that then 401'd. Both paths now exec through `vault-env.sh`, so there
is exactly one place that knows where this container's Claude login comes
from and the two cannot disagree.

The value never touches a file on the way in: `vault get --value` prints it
and the script captures it. The alternative — the path form, then `cat` —
reads a file in the volume, which the agent can write, and the gate is baked
into the image precisely so that what it reads is not something the agent
chooses.

The vault name `claude-oauth-token` is hardcoded, for the reason the ssh key's
name is: a name that can be changed in `.env` is a name that can silently come
to point at nothing, and the symptom would be a container quietly running on
the credential this exists to replace. A vault that cannot be reached is
silent and falls back to the credentials file in the volume — a vault that is
down must not be a container that cannot start, and the budget gate is what
says loudly whether the credential that remains is usable.

An already-set `CLAUDE_CODE_OAUTH_TOKEN` wins and nothing overwrites it, which
is what lets a probe pass a deliberate value — `just verify` does.


## Why the credentials file is not kept in the vault

The ssh key is restored from the vault and the Claude login is not, and the
reason is measured rather than a preference.

**A restored `~/.claude/.credentials.json` is enough for a headless session.**
Measured 2026-08-25 in `just test-container`: `claude -p` ran on a home holding
that file and nothing else — no onboarding, no theme, no trust dialog, no
`.claude.json` at all. The interactive first-run questions do not exist on the
`-p` path, and the one dialog `just chat` would meet is pre-accepted by the
entrypoint.

**Three of its seven fields are load-bearing, each for a different reader**, so
there is no single key to keep — it is the whole `claudeAiOauth` object or
nothing. Measured the same day by restoring cut-down versions of it into a
fresh container:

| field | who needs it |
| --- | --- |
| `accessToken` | `claude-usage.py` refuses to load the file without one |
| `scopes` | **Claude Code reports `loggedIn: false` without it** — dropping this alone is the whole difference between a session that runs and one that says "Please run /login" |
| `refreshToken` | the only thing that revives a stored copy whose access token has expired, which is every restore |
| `expiresAt`, `refreshTokenExpiresAt`, `subscriptionType`, `rateLimitTier` | nothing — `accessToken` and `scopes` alone is a working login |

**And the copy goes stale, which is what decides it.** The refresh token
**rotates on every renewal** — measured by hashing it either side of one
`claude-usage.py --refresh` — while `refreshTokenExpiresAt` stays anchored to
the original grant: it moved by 469 milliseconds across a rotation, which is
the rounding you get when a server counts down to a fixed date. So the window
does not extend with use, and switching the machine off does not pause it. A
copy in the vault is a snapshot with hours of life, and keeping it current
would need something that re-stores it after every rotation — a second
mechanism whose silent failure is a backup that is not there. That is the
failure this repository exists to avoid, so the vault copy is not the route.

**The lifetime is not a constant either.** Two logins to the same account were
observed 7 days and 26 days from expiry at the same moment, so read it off the
credential rather than assuming a number. Nothing available here removes that
ceiling: no token this account can issue reads usage without the interactive
login behind it, which is why `claude-oauth-token` — a setup-token, which has
no refresh and no wall clock — is what the vault holds for the container, and
why the guarding usage read runs on the host. See docs/budget.md.


## `claude -p` and the 401, re-measured

The paragraph above used to end by saying the 401 was silent. On **2.1.238**
`claude -p` exited 0 when it could not authenticate, so nothing downstream
noticed. On **2.1.250** it exits 1 — measured **2026-09-01** with a
deliberately invalid token:

    docker run --rm -e CLAUDE_CODE_OAUTH_TOKEN=<invalid> \
        --entrypoint claude-session <image> -p 'Reply with the single word: ok.'
    Failed to authenticate. API Error: 401 OAuth access token is invalid.
    EXIT=1

So a dead token in the vault now ends `just run` on a status its EXIT trap
alerts on, and the operator gets a toast one session later rather than never.

**The old reading is kept because it is what a reader of this file believed
for a week.** The exit status of a version is not a property of the tool, and
this is one to re-measure after every upgrade rather than to trust.
