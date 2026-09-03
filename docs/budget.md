# Budget

## What it is, and what to set

The agent spends the same Claude allowance the operator does. Left alone on a
schedule it would take the week, and the failure arrives as your own work
being throttled on a Thursday afternoon. The budget guard is what stops
that: before every unattended session it reads the account's own rate limits
and refuses the session while the account is above a line you set.

Claude's allowance comes in two windows: a **5-hour session window** and a
**7-day total**. For each, two percentages in `.env` describe the line:

| variable | what it is |
| --- | --- |
| `ACCOUNT_BUDGET_SESSION_START` | how much of the 5-hour window the agent may use right after the window resets |
| `ACCOUNT_BUDGET_SESSION_CAP` | how much it may have used by the end of that window |
| `ACCOUNT_BUDGET_WEEKLY_START` | the same, for the 7-day total, at the weekly reset |
| `ACCOUNT_BUDGET_WEEKLY_CAP` | the same, at the end of the week |

The allowed line **climbs from `START` at the reset to `CAP` just before the
next one**, and a session starts only while the account's actual usage sits
under that line:

    allowed = START + (CAP − START) × fraction of the window elapsed

So a weekly cap of 60 does not mean the agent may burn 60% on Monday: on
Monday morning the line is near `START`, and it reaches 60 only on Sunday
night. Read as a pace, this works on a shared account: the agent fills
whatever gap your own use leaves under the line, and `100 − CAP` is always
yours. `START` is what keeps the first minute after a reset from refusing
everything — a pure ramp from 0 allows nothing at the instant of the reset.

The line is on the **total** the account has used, not on the agent's share,
deliberately: a budget on the agent's own consumption could stay inside its
half while the account hit 100%, and the person locked out would be you.

`.env.example` ships the four filled — `20→50` for the session window,
`10→60` for the week — and they are only in force when
**`ACCOUNT_BUDGET_GUARD=true`**, exactly that word. Off, nothing on the host
refuses a session on budget; the host still reads the usage and the session is
still told the numbers, for information, against an even pace (`5→100`)
whatever the percentages say. **Turn it on only while one account is behind both** the host's
login and the container's token: the endpoint reports the account, not the
credential, so on a separate account for the agent the reading would be a
statement about your quota, not its own.

Two more knobs: `ACCOUNT_BUDGET_CACHE_MINUTES` (5 unless set) is how long a
reading may be reused, because the usage endpoint allows five requests per
five minutes for the whole account and a cron line that wakes every minute
would spend that on its own; and `just run --ignore-budget` starts one
session past the guard without disarming it.

What you see: `just status` prints both windows as `used`, `allowed now` and
the ratio between them; a session is handed the same numbers as
`ACCOUNT_USAGE_SESSION` and `ACCOUNT_USAGE_WEEKLY`. A guard that refuses
exits 75, the same code as a skipped cooldown, and says so on a terminal
only. Unset percentages are **not** "no limit": the guard refuses to answer,
and a refusal to answer is a session that does not start — a guard installed
and quietly doing nothing is the failure this repository is built against.

## How it is built

`image/claude-usage.py` reports what the account has spent, read from its own
rate limits: `GET https://api.anthropic.com/api/oauth/usage`, an HTTP read that
costs no inference. It reports, and whether the report refuses anything belongs
to whoever reads its exit status — exit 0 to go, 75 to stand down, 2 when it
cannot tell, and 2 is a stand-down too at the caller.

There are two such readers, wanting opposite things.

- On the **host**, `host/lib/session-env.sh` reads the status and stands a
  session down on it. That is the budget guard, and it cannot fail open: the
  caller reads an exit status rather than consulting a hook, so a gate that is
  missing, unreadable or broken makes `docker compose run` fail and the session
  does not start. That is the opposite of `image/bash-guard.py`, which fails
  open because a `PreToolUse` hook that dies is simply never consulted — which
  is why this one needs no "was it reached" probe of the kind the guard needs.
  It is armed by `ACCOUNT_BUDGET_GUARD` in `.env`.
- In the **container**, `--advisory`, where it cannot refuse anything: exit 0
  whatever it finds, and no numbers at all rather than the word "unknown" when
  it cannot tell. That is for the agent to see how fast it is spending, and for
  the day it runs on an account of its own, where the host's reading would be a
  statement about somebody else's quota. Failing open there is its defined
  behaviour, not a defect.

The same file both ways, deliberately: a second copy of the arithmetic is the
copy that drifts, and it drifts silently because both answers look like
numbers. It is baked into the image, root-owned and outside the volume, for the
same reason `push-on-exit.sh` and `bash-guard.py` are.

**The rule.** Each gated window has two configured percentages, a start and a
cap, and the allowance interpolates between them across the window:

    elapsed = 1 - (resets_at - now) / window_length
    allowed = start + (cap - start) * elapsed
    go      = used <= allowed

So a weekly cap of 60 does not mean 60% may be spent on Monday: the allowance
climbs from `start` at the reset to `cap` just before the next one, and a
session starts only while the account sits under that line. The start
percentage is what stops the first minute of every window from refusing
everything — at elapsed 0 a pure ramp allows nothing at all, which would make
the gate a coin toss on when cron happened to fire.

**What is gated and what is not.** `session` (the 5-hour window) and
`weekly_all` (the 7-day one), and nothing else. The payload also carries
`weekly_scoped` entries — a per-model weekly limit, Fable's among them — and
those must not gate: burning the Fable-scoped limit costs nothing to a session
running another model, and such a session does not consume it either, so gating
on it would be wrong in both directions. Everything a scoped limit measures is
already inside `weekly_all`. They are reported, never enforced.

**The window lengths are not in the payload.** It gives `resets_at` and no
duration, so 5h and 7d are constants in `GATED`. A constant that is wrong
computes a wrong elapsed fraction and reports it in exactly the words a right
one uses. Half of that is detectable: a `resets_at` further out than the
assumed length proves the length wrong, and `elapsed_fraction` refuses rather
than averaging over it. A window that grew *shorter* is invisible, and is the
reason this is re-probed after every Claude Code upgrade rather than trusted.


## The name changed on 2026-08-25

It was called `usage-gate.py`. The rename to `claude-usage.py` is the whole
distinction above made visible in the filename: the file reports, and only its
readers gate. A name saying "gate" makes the container's advisory read look
like a broken one.


## `user:profile`, and why the guard runs on the host

Reading usage needs a login carrying the `user:profile` scope, and only the
interactive `claude login` grants one. `claude setup-token` issues an
**inference** credential: it runs a session perfectly well — measured, `claude
-p` returns — and it cannot read usage at all. Measured 2026-08-25, the
endpoint answers

    403 — OAuth token does not meet scope requirement user:profile

`CLAUDE_CODE_OAUTH_TOKEN` was preferred over the credentials file for one
afternoon, on the reasoning that Claude Code prefers it and the two must not
disagree. Then a real one was issued and the 403 above arrived: preferring it
did not make the two agree, it made the script unable to answer while the
session ran fine, and every wake-up stood down. There is no version of "prefer
the env token" that works — usage comes from `~/.claude/.credentials.json` or
from nowhere. `ENV_TOKEN` is kept as a name only so the comment has something
to sit under, and `--selftest` holds a case asserting that nothing is ever sent
under it.

The host has such a login, kept fresh by the person using it, which is why
`host/lib/session-env.sh` runs the guarding read there. It reads the **same
number** the container would: today one account is behind both, confirmed by
`accountUuid`, and the usage endpoint reports the *account* rather than the
credential. If that ever stops being true the guard should be turned off there,
which is what `ACCOUNT_BUDGET_GUARD` is for — arming it is honest only while
one account is behind both.


## Exactly `true` arms the guard

Nothing else, including a plausible `yes`. The tolerant list this replaced
could not be kept in step: compose passes the raw value into every container,
so a host that armed on `yes` told the session `yes`, and the session then
needed the same list to read it. Two spellings of one vocabulary, and the day
they parted the container would have said `false` while the host stood a
session down.

One comparison instead, made the same way on both sides, so there is nothing to
keep in step. A value that is neither empty nor `true` is off — and `just
verify` says so out loud, because that is the case that would otherwise be
silent.


## The endpoint allows five requests per five minutes

Measured 2026-08-28. The sixth request inside five minutes answers

    HTTP 429, Retry-After: 300
    {"type": "rate_limit_error",
     "message": "Rate limited. Please try again later."}

from the edge rather than the origin — that refusal carries no
`anthropic-organization-id` and no `server-timing`, both of which a 200 from
the same endpoint does. So it is a limit on requests on the way in, not a
quota, and it is five per five minutes however much inference the account has
bought.

`* * * * * just run --cooldown 15` reads once a minute whenever it is outside
its cooldown, which spends that allowance exactly and leaves nothing for the
other readers on the same account: `status-collect.py`'s container read, a
session's own advisory read, and every Claude Code session the operator has
open, all of which poll this endpoint for their own limit display. On
2026-08-28 the run log held **38 consecutive minutes** of `cannot tell — HTTP
429`, and a cannot-tell stands the session down: under contention the guard's
failure was no sessions at all.

**The penalty is not self-sustaining**, measured the same day: knocking once a
minute all the way through a 429 leaves `Retry-After` counting down against
real time — 254, 194, 134, 74, 14 — and the window clears at 300s regardless.
That is why nothing reads `Retry-After` and holds off. Staying under the
allowance makes a second mechanism unnecessary, and the redundant one is always
the one that drifts.

**Five minutes by default, ruled by the operator on 2026-08-28**, with
`ACCOUNT_BUDGET_CACHE_MINUTES` to move it. Usage moves only while a session
runs, and the lock refuses a second session anyway, so a reading this old
differs from a live one by a fraction of a percent of allowance — and the guard
is a soft limit already. Five takes this from 60 reads an hour to 12, which
leaves the rest of the allowance for everyone else.

**Only the utilisation goes stale**, which is what makes five minutes cheap.
The allowance is recomputed from the current clock against the `resets_at` in
the cached payload, so the ramp keeps climbing between reads and only the
percentage used is up to five minutes old.

The cache file holds the payload and nothing else — percentages and reset
instants, never a token. In the container it sits in the volume where the agent
can write it, and that is safe because the container's read is `--advisory` and
decides nothing. The reading that gates is the host's, and the host's cache is
out of the agent's reach.


## A 429 was read as the wrong token

Measured 2026-08-25: a read under the vault's token answered `cannot tell: the
usage endpoint answered HTTP 429` while the credentials file, same account,
same second, answered 200 — and nothing in that sentence pointed at either
credential. `fetch_usage` gained a `source` argument naming which credential
was used, and it is in every failure message because there are two and a
message that does not say is unreadable.

**That was read as the wrong token producing a 429. It was not.** Measured
2026-08-28: an invalid token answers 401 — `OAuth access token is invalid` —
and never 429. The 429 was the endpoint's request limit, which counts the
account rather than the credential; two reads in one second are simply the
first and the second. Naming the source is still worth doing, and what it
proves is narrower than it looked: which credential was tried, never why it
failed.


## Where the cache file lives

`cache_home` honours `$XDG_CACHE_HOME` when it is absolute and falls back to
`~/.cache` otherwise. **Ruled 2026-08-29.**

The path was a fixed `~/.cache` until 2026-08-29, on the ground that one
variable per thing worth configuring is enough: how long a reading may be
reused is worth configuring and where the file sits is not — and
`XDG_CACHE_HOME` had been honoured here for an afternoon before that, buying a
relocation nobody had asked for. **That record stands, and what it was about
was a knob of ours.** This is not one: it is the environment's own answer to
the question, and the justfile has been asking it all along — `cache_dir()` is
just's own function and it honours `XDG_CACHE_HOME`, measured. So on a machine
that sets the variable the runner's stamps went to `$XDG_CACHE_HOME/<agent>/`
while this went to `$HOME/.cache`: two halves of one cache disagreeing about
where the cache is, silently, and only on the machines nobody tests on.

**It is the host this is for**, and that is the whole of the reasoning. The
host is a machine with conventions that are not ours, and honouring them there
is the point. The container is ours end to end: it sets no `XDG_CACHE_HOME` and
does not need to, because the fallback already puts the file exactly where we
would have pointed it. Nothing goes in compose to say so — a variable set to
the value it would have taken anyway is a second place to keep in step, for
nothing.

**The vault cache stays fixed**, and that is not an inconsistency left behind.
`image/vault.sh` and `image/bash-guard.py` have to name one directory or rule
10 stops covering a fetched secret, and `host/archive/read-volume.sh`
reads it a third time — as `/vol/.cache/vault`, from the host, through a
container that never sees the agent's environment and could not follow the
variable if it wanted to. An XDG-aware vault would leave that scan reading an
empty directory and reporting nothing wrong, which is the whole failure mode
the scan exists to prevent. See `docs/vault.md#fixtures-have-their-own-cache-directory`.

The empty-string case is the load-bearing half of `cache_home`'s test:
`os.path.join("", name)` yields a **relative** path, so the reading would land
wherever the process happened to start — the checkout for a guard run by hand,
`$HOME` for one run by cron — and never be found again by the next run that
looked. Every read would miss, every run would refetch, and the only symptom is
429s. `--selftest` holds a case for it.

**The file is named `runner-claude-usage.json` because we write it.** It was
`claude-usage.json` until 2026-08-28, which in the container put it directly
beside `claude-cli-nodejs` — Claude Code's own directory — and on the host
beside that and `claude-statusline` as well: in both places it read as a file
the tool keeps about itself rather than one of ours about the tool. A cache
nobody recognises as theirs is a cache nobody thinks to delete on the day it is
the stale thing that has gone wrong, and a wrong reading here reads exactly
like a right one.

**It sits loose in the cache root, deliberately not under the per-agent
directory** the runner's stamps and logs moved into on 2026-08-28. What it
holds is the *account's* utilisation and not this agent's — the endpoint
reports the account, not the credential, the same fact that makes
`ACCOUNT_BUDGET_GUARD` honest only while one account is behind both. Filing it
per agent would assert something untrue, and would give two agents on one host
a separate five-minute reading of one number.


## An idle window has no reset, and that is not a failure to read it

Measured 2026-08-29: with no 5-hour window open the endpoint reports

    {"kind": "session", "percent": 0, "resets_at": null, "is_active": false}

with `weekly_all` beside it perfectly well formed. Nothing has been spent, so
no window has opened and there is nothing to reset. Refusing on the absent
timestamp blanked the whole reading — one window that cannot be read refuses
them all — and **stood 240 sessions down in the run log**, every one of them at
the moment the account was most obviously affordable.

`evaluate` now reads it as the empty window it says it is, exactly as it reads
a window whose reset has already passed: that one closed, and the percentage
still reported belongs to it, so counting it would hold a session out over
spending that has already been forgiven.

**Only at zero.** A percentage with no window to place it in is genuinely
unplaceable, and assuming a window for it is the one direction here that could
let spending through. `--selftest` holds both cases.


## The advisory start is 5, not 0

On the advisory path every window means the whole allowance, reached evenly
across the window — `ADVISORY_BUDGET`, whatever `.env` sets: nothing refuses
there, and a line nobody enforces is not an answer to "am I spending too
quickly". The ramp then turns `ratio` into
**burn rate against an even pace**: used against what an even burn would have
reached by now, where 100 is on pace and 200 is twice as fast. That is the
number worth having when the question is "am I spending too quickly", which is
the only question this path answers.

A pure 0-to-100 ramp allows nothing at the instant of a reset, so any usage at
all divides by about zero and the ratio saturates at 999 — a false alarm on
every window boundary. Modelled across a window, burning 4% of the window in
its first moments reads:

    START=0 → 999      START=2 → 191      START=5 → 79      START=10 → 40

5 keeps the alarm where it belongs — 50% of the window burnt in its first 1%
still reads 840 — while an ordinary opening session reads calm. What it costs
is fidelity early: an even pace reads 51 at 5% elapsed rather than 100, and 87
by a quarter of the way through. That understates rather than overstates, which
is the safe direction: early in a window there genuinely is headroom, and there
is no rate to measure over no elapsed time. `--selftest` asserts both that the
start is above zero and that no elapsed fraction lets an even pace saturate.


## Unset refuses on one path and defaults on the other

`budget_from_env` refuses an unset percentage unless nothing is being gated. A
default that never blocks is a gate installed and doing nothing, and it reads
from outside exactly like one that is working — so the refusal stays where a
decision is made, and the default applies only on the advisory path, where
there is no decision to make and no configuration to have got wrong.
Half-configured is refused on both paths: one percentage set and the other
missing is a mistake, not a request for defaults.

`ACCOUNT_BUDGET_CACHE_MINUTES` behaves the **opposite** way, and the asymmetry
needs saying out loud because the two share a prefix as well as a file —
nothing about `ACCOUNT_BUDGET_CACHE_MINUTES` beside `ACCOUNT_BUDGET_WEEKLY_CAP`
says which of them stands a session down when it is empty. A budget is a guard;
this is not — it decides how often the endpoint is asked, and a checkout that
has never heard of it must still start sessions. What cannot be *believed* is
still refused either way: `0` turns the cache off and is a real answer; a word,
a negative, or an hour and a half are not, and a wrong TTL reports in the same
numbers a right one does. The unit is in the name because the one wrong value
that reads as perfectly reasonable is `300` — seconds typed where minutes were
meant, which would serve a five-hour-old reading and gate on it —
and `CACHE_MINUTES_CEILING` catches it anyway.

The prefix is globbed by `host/lib/session-env.sh` and by `entrypoint.sh` over
what this tool **prints**, so `ACCOUNT_BUDGET_CACHE_MINUTES` must never be
echoed on the `--env` path the way `_START` and `_CAP` are, or the host's TTL
would arrive in the container as a variable compose had already answered. It is
not printed today; that is deliberate, not an omission.


## The expiry check comes before the cache

This call is also what renews the container's access token on the days nothing
is scheduled — `host/lib/session-env.sh` says so in as many words — and a cache
consulted before the expiry would serve a reading happily while the token
behind it aged out. The symptom would arrive about eight days later as a
refresh token nothing can renew, with `claude login` inside `just shell` the
only cure. `--selftest` holds a case for it, because nothing else would notice.

The renewal proves the new tokens against the usage endpoint *before* writing
them: the refresh may rotate the refresh token, so the new one has to be stored
or the next renewal fails, but storing a set that turns out not to work would
lock the container out of its own account. The proof is the usage read itself,
which is needed anyway. A 401 on the proof means the tokens just issued are
genuinely no good and the ones on disk may still work — keep them. Anything
else is the network, and a rotation discarded there is a login nobody can
recover, because the refresh token that was on disk has been spent — so the
file is replaced even though the proof did not finish, and the caller is told
it could not be proved.


## The grant goes to api.anthropic.com, not platform.claude.com

`platform.claude.com` is where Claude Code's own interactive login posts this
grant. That host is behind an edge that answers a plain client `403 error code:
1010` — a browser-integrity refusal, before the request reaches any OAuth logic
at all — and the only way past it is a `User-Agent` claiming to be the CLI.
`api.anthropic.com` carries the identical grant with no such check, is the same
host the usage read already uses, and is what the Anthropic SDK's own
user-OAuth provider posts to. Measured both ways against a deliberately invalid
token, so neither answer cost a real one: platform 403s, api answers
`invalid_grant`.

`CLIENT_ID` is Claude Code's own OAuth client id, read out of the pinned binary
rather than guessed. A refresh posted under another one is refused by the
server, which is the good failure; the bad one would be a silent success
against something that is not Anthropic. The `anthropic-beta:
oauth-2025-04-20` header is what the SDK sends on this grant, measured as
unnecessary today and kept because a request shaped like the official one is
the one least likely to meet a new rule at the edge.


## The host forwards by prefix, not by name

`host/lib/session-env.sh` forwards every `ACCOUNT_USAGE_*` and
`ACCOUNT_BUDGET_*` line the tool printed, already spelled as `-e NAME=value`.
What the variables are called and what they hold is `claude-usage.py`'s
business, and it is the same file the container runs for itself — so naming
them there would be a second place the shape lives.

`ACCOUNT_USAGE_SCOPED` did exactly that: the tool printed it, the host listed
`SESSION` and `WEEKLY`, and a session started by the host saw one variable
fewer than the same session started without it.

`ACCOUNT_USAGE_SCOPED` is also printed as **one line with its entries joined**,
because these become environment variables and an environment cannot hold a
name twice. It used to print the key once per scoped limit — a list,
faithfully, and numbering them would have invented an order the endpoint does
not promise. But the consumer exports what it reads, so the second line
replaced the first and the earlier limits vanished. One scoped limit exists
today, which is why nothing showed it. It is printed even when empty, so a
reader never has to tell "no scoped limits" from "this source does not report
them".

**`unknown` is dropped rather than forwarded.** The guard prints it when it
could not read, and passing it on would tell the container "the host answered"
— which suppresses the advisory read that might have succeeded where the host
did not. Only a real reading is worth forwarding; anything else leaves the
variable absent, which is the cue the entrypoint reads: the host could not read,
or the agent runs on an account of its own.

**The host reads whether or not the guard is armed.** Off, it reads with
`--advisory`, which exits 0 whatever it finds, and the session is told the
numbers all the same. The container's own read is the fallback, not the rule:
a setup-token cannot read usage, so a session that depended on it would have no
numbers on every installation that keeps the token in the vault.

**The budget actually used travels with the numbers**, under the names it is
configured with, and is not an echo of the input: the advisory path uses 5-100
whatever is set, and a reader that found `budget=5-100` inside
`ACCOUNT_USAGE_SESSION` beside an empty `ACCOUNT_BUDGET_SESSION_START` would
have two answers to one question. It is printed only on the path that reached a
verdict, so usage and budget are absent together and never half-present.

`READING_AGE` is deliberately **not** an `ACCOUNT_*` name: how old the host's
reading was is the host's business, and the session is already told that
everything it is given is a snapshot.

The session is told `ACCOUNT_BUDGET_GUARD` normalised to exactly `true` or
`false`, never absent and never empty — and told it even when the guard is
armed and the run bypassed it. `--ignore-budget` does not disarm the guard, it
ignores the answer, so the numbers are still the real ones: a ratio over 100
beside `true` is a session that started because someone said so, and that is
worth being able to read rather than having to infer from silence. `ratio` is
used over allowance-as-a-percentage because it says how close the door is,
where the raw utilisation says nothing without the allowance beside it.


## The selftest reads no live credential

`--selftest` proves the arithmetic against synthetic inputs, with no
credential, no network and no container — which is what makes it runnable at
build time, where a gate that computes badly stops the build rather than
shipping quiet. It counts its checks rather than writing the number down: a
number typed in is a second copy of how many there are, and the copy is the one
that goes stale.

`CREDENTIALS` is redirected for the whole stubbed block, at a path that cannot
exist. **A selftest that fell through to the real credentials file would read a
live token — and the first draft of this did exactly that, and printed it in a
failure message.** It runs at build time, where there is no such file, so
nothing would ever have caught it there. The credentials the stubbed cases
write are `selftest-placeholder` and deliberately not a token shape: gitleaks
reads this repository, and a plausible one would be a finding on every scan for
as long as the file exists.

The cache cases fail silently in both directions, so both directions have a
case: a cache never used spends the endpoint's five-per-five-minutes exactly as
before and the 429s come back; a cache consulted too early stops the access
token being renewed and says nothing about it for the eight days the refresh
token has left. Both read as working. The cases pass an explicit TTL rather
than the ambient environment, because a host with the TTL set to 0 would turn
every one of them green for the wrong reason.
