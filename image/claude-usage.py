#!/usr/bin/env python3
"""What the account has spent, read from its own rate limits.

  GET https://api.anthropic.com/api/oauth/usage

is the whole of the data, and it costs no inference — an HTTP read, not a
model call.

It reports. Whether the report refuses anything belongs to whoever reads the
exit status, and there are two such readers wanting opposite things.

  On the HOST, host/lib/session-env.sh reads the status and stands a session
  down on it. That is the budget guard, and it is what stops the agent
  spending the quota the operator needs for their own work. It runs there
  because reading usage needs a login with the `user:profile` scope, and only
  the interactive `claude login` grants one.

  In the CONTAINER, --advisory, where it CANNOT refuse anything: exit 0
  whatever it finds, and no numbers at all rather than the word "unknown"
  when it cannot tell. That is for the agent to see how fast it is spending,
  and for the day it runs on an account of its own — where the host's reading
  would be a statement about somebody else's quota.

The same file both ways, deliberately. A second copy of the arithmetic is the
copy that drifts, and it drifts silently because both answers look like
numbers. Baked into the image, root-owned and outside the volume, for the same
reason `push-on-exit.sh` and `bash-guard.py` are: what the agent could edit is
what the agent decides for itself.

The reading is cached: the endpoint allows five requests per five minutes and a
per-minute schedule asks for sixty an hour, and a gate that cannot read stands
the session down, so an allowance spent on polling is sessions not run.

The rule. Each gated window has two configured percentages, a start and a cap,
and the allowance interpolates between them across the window:

    elapsed  = 1 - (resets_at - now) / window_length
    allowed  = start + (cap - start) * elapsed
    go       = used <= allowed

So a weekly cap of 60 does not mean 60% may be spent on Monday: the allowance
climbs from `start` at the reset to `cap` just before the next one, and a
session starts only while the account sits under that line. The start
percentage is what stops the first minute of every window from refusing
everything — at elapsed 0 a pure ramp allows nothing at all, which would
make the gate a coin toss on when cron happened to fire.

What is gated: `session` (the 5-hour window) and `weekly_all` (the 7-day one),
and nothing else. The payload's `weekly_scoped` entries — a per-model weekly
limit, Fable's among them — are reported, never enforced: burning the
Fable-scoped limit costs nothing to a session running another model, and such a
session does not consume it either, so gating on it would be wrong in both
directions. Everything a scoped limit measures is already inside `weekly_all`.

The window lengths are not in the payload. It gives `resets_at` and no
duration, so 5h and 7d are constants here — and a constant that is wrong
computes a wrong elapsed fraction and reports it in exactly the words a right
one uses. Half of that is detectable: a `resets_at` further out than the
assumed length proves the length wrong, and is refused rather than averaged
over. A window that grew shorter is invisible, and is the reason this is
re-probed after every Claude Code upgrade rather than trusted.

Failing. Exit 0 to go, 75 to stand down, 2 when it cannot tell — and 2 is a
stand-down too, at the caller. The caller reads an exit status rather than
consulting a hook, so a gate that is missing, unreadable or broken makes
`docker compose run` fail and the session does not start. That is the
opposite of `bash-guard.py`, which fails open because a PreToolUse hook that
dies is simply never consulted; this one cannot die quietly, which is why it
needs no "was it reached" probe of the kind the guard needs.

The records behind all of this are in docs/budget.md.
"""

import json
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta

CREDENTIALS = os.path.expanduser("~/.claude/.credentials.json")

# The reading is cached because the endpoint's allowance — five requests per
# five minutes, counted per account on the way in — is smaller than the cadence
# that reads it, and it is shared with every other reader of the same account.
# Nothing here reads `Retry-After` and holds off: staying under the allowance
# makes a second mechanism unnecessary, and the redundant one is always the one
# that drifts.
# see docs/budget.md#the-endpoint-allows-five-requests-per-five-minutes
#
# Only the utilisation goes stale, which is what makes a few minutes cheap: the
# allowance is recomputed from the current clock against the `resets_at` in the
# cached payload, so the ramp keeps climbing between reads and only the
# percentage used is old.
#
# The file holds the payload and nothing else — percentages and reset instants,
# never a token. In the container it sits in the volume where the agent can
# write it, and that is safe because the container's read is `--advisory` and
# decides nothing. The reading that gates is the host's, out of the agent's
# reach.
#
# XDG_CACHE_HOME when it is usable, ~/.cache otherwise — see cache_home. Not a
# knob of ours but the environment's own answer, and the justfile has been
# honouring it all along, so a fixed path here would put two halves of one
# cache in different places on any machine that sets the variable. The vault
# cache stays fixed for the opposite reason — three readers have to name one
# directory or rule 10 stops covering a fetched secret.
# see docs/budget.md#where-the-cache-file-lives
#
# Loose in the cache root, deliberately not under the per-agent directory the
# runner's stamps and logs use: what this holds is the ACCOUNT's utilisation
# and not this agent's, so filing it per agent would assert something untrue
# and give two agents on one host a separate reading of one number.
#
# `runner-` because we write it: unprefixed it sits beside Claude Code's own
# directories and reads as a file the tool keeps about itself, and a cache
# nobody recognises as theirs is a cache nobody thinks to delete on the day it
# is the stale thing that has gone wrong.


def cache_home(environ=None):
    """$XDG_CACHE_HOME when it is usable, ~/.cache otherwise."""
    environ = os.environ if environ is None else environ
    # The spec's two rejections fall out of one test: empty means unset, a
    # relative value is invalid, and isabs covers both. Rejecting the empty
    # string is the load-bearing half — os.path.join("", name) yields a
    # RELATIVE path, so the reading would land wherever the process happened to
    # start and never be found again: every read a miss, every run a refetch,
    # and the only symptom 429s.
    xdg = environ.get("XDG_CACHE_HOME", "")
    return xdg if os.path.isabs(xdg) else os.path.expanduser("~/.cache")


CACHE = os.path.join(cache_home(), "runner-claude-usage.json")

# The unit is in the name, deliberately. The one wrong value that reads as
# perfectly reasonable is `300` — seconds, typed where minutes were meant —
# and it would serve a five-hour-old reading and gate on it. The name makes
# that unlikely and CACHE_MINUTES_CEILING catches it anyway.
#
# It shares a prefix with the four gated thresholds and is not one, and two
# things follow that the eye will not supply. Unset behaves the OPPOSITE way
# here: see cache_minutes. And the prefix is globbed, by session-env.sh and by
# entrypoint.sh, over what this tool PRINTS — so this name must never be echoed
# on the --env path the way _START and _CAP are, or the host's TTL would arrive
# in the container as a variable compose had already answered. It is not
# printed today; that is deliberate, not an omission.
# see docs/budget.md#unset-refuses-on-one-path-and-defaults-on-the-other
CACHE_MINUTES = "ACCOUNT_BUDGET_CACHE_MINUTES"
CACHE_MINUTES_DEFAULT = 5.0
CACHE_MINUTES_CEILING = 60.0

# CLAUDE_CODE_OAUTH_TOKEN is deliberately not read here, and the name is kept
# only so this comment has something to sit under. `claude setup-token` issues
# an INFERENCE credential: it runs a session perfectly well and cannot read
# usage at all, because reading usage needs a scope only the interactive
# `claude login` grants. Preferring it leaves this unable to answer while the
# session runs fine, and every wake-up stands down. Usage comes from
# ~/.claude/.credentials.json or from nowhere.
# see docs/budget.md#userprofile-and-why-the-guard-runs-on-the-host
ENV_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN"

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

# Claude Code's own OAuth client id, read out of the pinned binary rather
# than guessed. A refresh posted under another one is refused by the server,
# which is the good failure; the bad one would be a silent success against
# something that is not Anthropic.
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

# NOT platform.claude.com, which is where Claude Code's own interactive login
# posts this grant: that host sits behind an edge that refuses a plain client
# before the request reaches any OAuth logic. api.anthropic.com carries the
# identical grant with no such check, is the same host the usage read already
# uses, and is what the Anthropic SDK's own user-OAuth provider posts to.
# see docs/budget.md#the-grant-goes-to-apianthropiccom-not-platformclaudecom
TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"

# What the SDK sends on this grant. Unnecessary today, and kept because a
# request shaped like the official one is the one least likely to meet a new
# rule at the edge.
OAUTH_BETA = "oauth-2025-04-20"

# Refresh this long before the access token actually expires. A token that
# dies between this check and the session it admits would have the session
# refresh it anyway; the margin is only here so the common case is one
# request rather than a 401 and a retry.
REFRESH_MARGIN = timedelta(minutes=15)

HTTP_TIMEOUT = 20

# kind -> (window length, name of the pair of environment variables)
GATED = {
    "session": (timedelta(hours=5), "SESSION"),
    "weekly_all": (timedelta(days=7), "WEEKLY"),
}

GO, STAND_DOWN, CANNOT_TELL = 0, 75, 2


class CannotTell(Exception):
    """The gate has no answer. Never a reason to let a session through."""


# --------------------------------------------------------------------------
# The arithmetic. Pure, so --selftest can prove it without a credential, a
# network or a container — which is what makes it provable at build time.
# --------------------------------------------------------------------------


def elapsed_fraction(resets_at, window, now):
    """How far into its window a limit is, 0 at the reset and 1 just before
    the next one.

    A `resets_at` beyond the window length means the length assumed here is
    wrong, and the fraction computed from it would be negative — silently
    generous, exactly once per wrong constant and never noticed. Refused
    instead.
    """
    remaining = resets_at - now
    if remaining > window:
        raise CannotTell(
            "%s until reset, but the window is assumed to be %s — the assumed "
            "length is wrong" % (remaining, window)
        )
    fraction = 1.0 - remaining.total_seconds() / window.total_seconds()
    return min(1.0, max(0.0, fraction))


def allowance(start, cap, fraction):
    return start + (cap - start) * fraction


def ratio_of_allowance(used, allowed):
    """Used as a percentage of what is allowed right now — the number that
    says how close the door is, where the raw utilisation says nothing
    without the allowance beside it.

    Capped at 999 rather than left unbounded: an allowance of zero is a
    legitimate configuration, and a division by it is not.
    """
    if allowed <= 0:
        return 0 if used <= 0 else 999
    return min(999, int(round(used / allowed * 100)))


def evaluate(limit, start, cap, window, now):
    """One limit against its budget. Returns a dict; raises CannotTell."""
    resets_at = limit.get("resets_at")
    if resets_at:
        resets_at = parse_instant(resets_at)

    used = limit.get("percent")
    if used is None:
        raise CannotTell("no percent")
    used = float(used)

    # An idle window has no reset, and that is not a failure to read it: with
    # nothing spent, no window has opened and the reading is the empty window it
    # says it is. Refusing on the absent timestamp blanks the whole reading,
    # because one window that cannot be read refuses them all.
    # see docs/budget.md#an-idle-window-has-no-reset-and-that-is-not-a-failure-to-read-it
    #
    # Only at zero: a percentage with no window to place it in is genuinely
    # unplaceable, and assuming a window for it is the one direction here that
    # could let spending through.
    if resets_at is None:
        if used > 0:
            raise CannotTell(
                "%g%% used and no resets_at, so there is no window to place it in" % used
            )
        fraction = 0.0
    # A reset already past means the window closed and nothing has opened a
    # new one. The percentage still reported belongs to the window that
    # ended, so reading it as current would hold a session out over spending
    # that has already been forgiven.
    elif resets_at <= now:
        used, fraction = 0.0, 0.0
    else:
        fraction = elapsed_fraction(resets_at, window, now)

    allowed = allowance(start, cap, fraction)
    return {
        "used": used,
        "allowed": allowed,
        "ratio": ratio_of_allowance(used, allowed),
        "start": start,
        "cap": cap,
        "window": window,
        "resets_at": resets_at,
        "go": used <= allowed,
    }


def parse_instant(text):
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as exc:
        raise CannotTell("unreadable timestamp %r: %s" % (text, exc))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    return moment.astimezone(UTC)


# What an unconfigured window means when nothing is being refused: the whole
# allowance, reached evenly across the window.
#
# The ramp turns `ratio` into burn rate against an even pace — used against
# what an even burn would have reached by now — where 100 is on pace and 200
# is twice as fast, which is the only question this path answers.
#
# The start is 5 and not 0, which is what a start is for: a pure 0-to-100 ramp
# allows nothing at the instant of a reset, so any usage at all divides by
# about zero and the ratio saturates at 999 — a false alarm on every window
# boundary. What 5 costs is fidelity early, and understating there is the safe
# direction.
# see docs/budget.md#the-advisory-start-is-5-not-0
ADVISORY_BUDGET = (5.0, 100.0)


def budget_from_env(name, environ, advisory=False):
    """The two percentages for one window, or CannotTell.

    Unset is refused unless nothing is being gated. A default that never
    blocks is a gate installed and doing nothing, and it reads from outside
    exactly like one that is working — so the refusal stays where a decision is
    made. The advisory path takes the even pace whatever is configured: with
    nothing refusing, the only question is "am I spending too quickly", and a
    line nobody enforces is not an answer to it.
    """
    if advisory:
        return ADVISORY_BUDGET

    values = []
    for half in ("START", "CAP"):
        key = "ACCOUNT_BUDGET_%s_%s" % (name, half)
        raw = (environ.get(key) or "").strip()
        if not raw:
            raise CannotTell("%s is not set" % key)
        try:
            value = float(raw)
        except ValueError:
            raise CannotTell("%s is %r, which is not a number" % (key, raw))
        if not 0 <= value <= 100:
            raise CannotTell("%s is %s, outside 0-100" % (key, raw))
        values.append(value)
    start, cap = values
    if start > cap:
        raise CannotTell(
            "ACCOUNT_BUDGET_%s_START (%g) is above _CAP (%g), which would "
            "make the allowance shrink as the window runs" % (name, start, cap)
        )
    return start, cap


def cache_minutes(environ):
    """How long a reading may be reused, in minutes.

    Unset is the default here, and unset REFUSES two functions up in
    budget_from_env. The asymmetry needs saying out loud, because the two share
    a prefix as well as a file: nothing about ACCOUNT_BUDGET_CACHE_MINUTES
    beside ACCOUNT_BUDGET_WEEKLY_CAP says which of them stands a session down
    when it is empty. A budget is a guard, and a guard that defaults to
    permissive is one installed and doing nothing. This is not a guard: it
    decides how often the endpoint is asked, and a checkout that has never
    heard of it must still start sessions.

    What cannot be believed is still refused, exactly as a budget is. `0` turns
    the cache off and is a real answer; a word, a negative, or an hour and a
    half are not, and a wrong TTL reports in the same numbers a right one does.
    """
    raw = (environ.get(CACHE_MINUTES) or "").strip()
    if not raw:
        return CACHE_MINUTES_DEFAULT
    try:
        value = float(raw)
    except ValueError:
        raise CannotTell("%s is %r, which is not a number of minutes" % (CACHE_MINUTES, raw))
    if not 0 <= value <= CACHE_MINUTES_CEILING:
        raise CannotTell(
            "%s is %g, outside 0-%g minutes — 0 turns the cache off, and "
            "above the ceiling is a reading too old to gate on (300 here is "
            "seconds typed where minutes were meant)"
            % (CACHE_MINUTES, value, CACHE_MINUTES_CEILING)
        )
    return value


# --------------------------------------------------------------------------
# Credentials and the endpoint
# --------------------------------------------------------------------------


def load_credentials():
    try:
        with open(CREDENTIALS) as handle:
            whole = json.load(handle)
    except FileNotFoundError:
        raise CannotTell("no credentials at %s — nothing is logged in" % CREDENTIALS)
    except (OSError, ValueError) as exc:
        raise CannotTell("cannot read %s: %s" % (CREDENTIALS, exc))
    oauth = whole.get("claudeAiOauth")
    if not isinstance(oauth, dict) or not oauth.get("accessToken"):
        raise CannotTell("%s carries no OAuth access token" % CREDENTIALS)
    return whole, oauth


def store_credentials(whole):
    """Replace the credentials file in one step.

    Written beside the original and renamed over it: a half-written
    credentials file is a logged-out container, and the only fix for that is
    a human at `just shell` running `claude login`. 0600 on the temporary
    file, not on the rename — a mode set afterwards is a window.
    """
    directory = os.path.dirname(CREDENTIALS)
    temporary = os.path.join(directory, ".credentials.json.gate-%d" % os.getpid())
    handle = os.open(temporary, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(handle, "w") as stream:
            json.dump(whole, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, CREDENTIALS)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def cache_load(now, ttl):
    """The last reading if it is younger than `ttl`, and how old it is.

    Anything unreadable is a miss and never an error. A cache is here to save
    a request, so a corrupt one must cost a request rather than an answer —
    the alternative is a gate that stops answering because a file it did not
    need got truncated.
    """
    try:
        with open(CACHE) as handle:
            held = json.load(handle)
        stamped = datetime.fromtimestamp(held["read_at"], UTC)
        usage = held["usage"]
    except (OSError, ValueError, KeyError, TypeError, OverflowError):
        return None, None
    age = now - stamped
    # A stamp in the future is a clock that moved, not a reading from later.
    # A zero ttl lands here too: nothing is ever young enough, which is what
    # turning the cache off has to mean.
    if age < timedelta(0) or age >= ttl:
        return None, None
    return usage, age


def cache_store(usage, now, ttl):
    """Keep the reading, and never fail on it: an unwritable cache is only a
    gate that reads the endpoint every time.

    Written beside and renamed over, like the credentials file. `just chat`
    and a cron wake-up can both be in here in the same second — the session
    lock is taken after this, not before — and a half-written file would be
    read as a corrupt one by whichever got there next.
    """
    # Off means off: with a zero ttl nothing would ever read this back, and a
    # file of account usage left behind by a cache someone switched off is a
    # small surprise waiting for whoever finds it.
    if ttl <= timedelta(0):
        return
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        temporary = "%s.%d" % (CACHE, os.getpid())
        with open(temporary, "w") as handle:
            json.dump({"read_at": now.timestamp(), "usage": usage}, handle)
        os.replace(temporary, CACHE)
    except (OSError, ValueError, TypeError):
        pass


def fetch_usage(access_token, source="the stored credential"):
    """The usage payload, or CannotTell. Returns None on 401 so the caller
    can refresh — a 401 is the one failure that has a cure here.

    `source` names which credential was used, and it is in every failure
    message because there are two and a message that does not say is
    unreadable. What it proves is narrow: which credential was tried, never why
    it failed — an invalid token answers 401, and a 429 is the endpoint's
    per-account request limit whichever credential asked.
    see docs/budget.md#a-429-was-read-as-the-wrong-token
    """
    request = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": "Bearer %s" % access_token,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return None
        # The status travels with the exception so the caller can tell an
        # authentication refusal from a service that is genuinely unwell,
        # without reading the sentence back.
        why = CannotTell("the usage endpoint answered HTTP %d, using %s" % (exc.code, source))
        why.status = exc.code
        raise why
    except (urllib.error.URLError, ValueError, OSError) as exc:
        raise CannotTell("cannot reach the usage endpoint, using %s: %s" % (source, exc))


def refresh(whole, oauth):
    """Renew the access token, prove the new one works, and only then write.

    That ordering is the whole safety of this. The refresh may rotate the
    refresh token, so the new one has to be stored or the next renewal fails
    — but storing a set of tokens that turn out not to work would lock the
    container out of its own account. So the proof is the usage read itself:
    it is needed anyway, and a set of tokens that answers it is a set worth
    keeping. Nothing is written on a refresh whose result cannot be used.

    Returns the usage payload, since the proof already fetched it.
    """
    body = {
        "grant_type": "refresh_token",
        "refresh_token": oauth.get("refreshToken"),
        "client_id": CLIENT_ID,
    }
    if not body["refresh_token"]:
        raise CannotTell(
            "the access token needs renewing and there is no refresh token — "
            "run `claude login` inside `just shell`"
        )
    scopes = oauth.get("scopes")
    if isinstance(scopes, list) and scopes:
        body["scope"] = " ".join(scopes)

    request = urllib.request.Request(
        TOKEN_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", "anthropic-beta": OAUTH_BETA},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            renewed = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # 400 with invalid_grant is the refresh token itself having expired,
        # which nothing automatic can cure: it lasts about eight days, and a
        # schedule held longer than that outlives it.
        detail = "HTTP %d" % exc.code
        if exc.code in (400, 401):
            detail += " — the refresh token has expired; run `claude login` inside `just shell`"
        elif exc.code == 403:
            detail += (
                " — refused before reaching the grant, which is an edge rule and not the token"
            )
        raise CannotTell("token renewal refused: %s" % detail)
    except (urllib.error.URLError, ValueError, OSError) as exc:
        raise CannotTell("cannot reach the token endpoint: %s" % exc)

    access_token = renewed.get("access_token")
    expires_in = renewed.get("expires_in")
    if not access_token or not isinstance(expires_in, (int, float)):
        raise CannotTell("token renewal answered without a usable access token")

    # The proof, and the one place where failing to write is worse than
    # writing. A 401 means the tokens just issued are genuinely no good, and
    # the ones on disk may still work — keep them. Anything else is the
    # network, and a rotation discarded there is a login nobody can recover:
    # the refresh token that was on disk has been spent, so the file must be
    # replaced even though the proof did not finish.
    try:
        usage = fetch_usage(access_token, source="the token just renewed")
    except CannotTell as why:
        unproven = why
        usage = None
    else:
        unproven = None
        if usage is None:
            raise CannotTell("the renewed access token was refused; nothing was written")

    now_ms = int(datetime.now(UTC).timestamp() * 1000)
    oauth["accessToken"] = access_token
    oauth["expiresAt"] = now_ms + int(expires_in * 1000)
    # Absent means unchanged, which is what Claude Code assumes too. Writing
    # a null here would log the container out at the next renewal.
    if renewed.get("refresh_token"):
        oauth["refreshToken"] = renewed["refresh_token"]
    refresh_expires_in = renewed.get("refresh_token_expires_in")
    if isinstance(refresh_expires_in, (int, float)):
        oauth["refreshTokenExpiresAt"] = now_ms + int(refresh_expires_in * 1000)
    store_credentials(whole)
    if unproven is not None:
        raise CannotTell("the token was renewed and stored, but could not be proved: %s" % unproven)
    return usage


def read_usage(force_refresh=False, environ=None):
    """The usage payload, whether the token was renewed, and how old the
    reading is — None when it was made just now.

    The expiry check comes first, ahead of the cache, and that ordering is what
    keeps the login alive: this call is also what renews the container's access
    token on the days nothing is scheduled, and a cache consulted before the
    expiry would serve a reading happily while the token behind it aged out.
    --selftest holds a case for it, because nothing else would notice.
    see docs/budget.md#the-expiry-check-comes-before-the-cache
    """
    # Read before the credentials, so a TTL nobody can parse refuses without
    # having touched a token — the same order budget_from_env is asked in.
    ttl = timedelta(minutes=cache_minutes(os.environ if environ is None else environ))
    whole, oauth = load_credentials()
    now = datetime.now(UTC)

    expires_at = oauth.get("expiresAt")
    stale = force_refresh
    if not stale and isinstance(expires_at, (int, float)):
        expiry = datetime.fromtimestamp(expires_at / 1000, UTC)
        stale = expiry - now < REFRESH_MARGIN

    if stale:
        usage = refresh(whole, oauth)
        cache_store(usage, now, ttl)
        return usage, True, None

    cached, age = cache_load(now, ttl)
    if cached is not None:
        return cached, False, age

    usage = fetch_usage(oauth["accessToken"], source=CREDENTIALS)
    if usage is None:
        # The stored expiry said the token was good and the server disagreed.
        # It has been wrong before on a credential written by another
        # process; the cure is the same either way.
        usage = refresh(whole, oauth)
        cache_store(usage, now, ttl)
        return usage, True, None
    cache_store(usage, now, ttl)
    return usage, False, None


def limits_of(usage):
    limits = usage.get("limits")
    if not isinstance(limits, list) or not limits:
        raise CannotTell(
            "the usage response carries no `limits` array — its shape has "
            "changed and this gate is reading nothing"
        )
    return limits


# --------------------------------------------------------------------------
# What the callers get
# --------------------------------------------------------------------------


def instant(moment):
    # Rounded to the nearest second, not truncated: the endpoint recomputes
    # `resets_at` per call and it jitters either side of the second, so
    # truncation prints two instants for one reset in consecutive readings —
    # a difference that reads as a moved deadline.
    moment += timedelta(microseconds=500000)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def reset_text(moment):
    # An idle window has no reset to name. `none` rather than a plausible
    # instant computed from the window length: both readers of this line — a
    # person and a session — are better served by the absence than by a
    # timestamp nothing reported.
    return instant(moment) if moment else "none"


def window_name(window):
    hours = int(window.total_seconds() // 3600)
    return "%dd" % (hours // 24) if hours % 24 == 0 else "%dh" % hours


def age_text(age):
    seconds = int(age.total_seconds())
    return "%dm%02ds" % (seconds // 60, seconds % 60)


def exhausted(results):
    """The gated windows with nothing left at all, whatever the budget says.

    A separate question from `go`, and the only one that does not depend on
    the configured percentages: `go` asks whether the agent is inside the
    share of the account it was given, and this asks whether the account can
    answer a request at all. A session started against a window at 100% ends
    on the limit rather than on its own work, which is what this exists to
    stop happening on a schedule.

    Reported, never enforced here, like everything else in this file: the
    caller decides. It is deliberately not tied to ACCOUNT_BUDGET_GUARD —
    the guard shares out an allowance, and a window with none left is not an
    allowance question.  see docs/budget.md#nothing-left-is-not-a-budget

    `used` has already been zeroed for a window whose reset is past, so a
    closed window is never reported here.
    """
    return [kind for kind in sorted(results) if results[kind]["used"] >= 100]


def as_env(result):
    return "used=%.1f allowed=%.1f ratio=%d budget=%g-%g window=%s resets=%s" % (
        result["used"],
        result["allowed"],
        result["ratio"],
        result["start"],
        result["cap"],
        window_name(result["window"]),
        reset_text(result["resets_at"]),
    )


def as_text(label, result):
    return (
        "%-12s %.1f%% used, %.1f%% allowed now — %d%% of the allowance "
        "(budget %g→%g across %s, resets %s)"
        % (
            label + ":",
            result["used"],
            result["allowed"],
            result["ratio"],
            result["start"],
            result["cap"],
            window_name(result["window"]),
            reset_text(result["resets_at"]),
        )
    )


def assess(environ, now, force_refresh=False, advisory=False):
    """Every gated window, evaluated. Raises CannotTell if any of it cannot
    be — a gate with one blind eye is not a gate."""
    budgets = {
        kind: budget_from_env(name, environ, advisory=advisory) for kind, (_, name) in GATED.items()
    }
    usage, renewed, age = read_usage(force_refresh=force_refresh, environ=environ)
    limits = limits_of(usage)

    results, scoped = {}, []
    for limit in limits:
        kind = limit.get("kind")
        if kind in GATED:
            window, _ = GATED[kind]
            start, cap = budgets[kind]
            results[kind] = evaluate(limit, start, cap, window, now)
        elif limit.get("percent") is not None:
            scope = (limit.get("scope") or {}).get("model") or {}
            scoped.append(
                "%s (%s, not gated) %g%% used"
                % (scope.get("display_name") or kind, limit.get("group") or "?", limit["percent"])
            )

    for kind in GATED:
        if kind not in results:
            raise CannotTell(
                "the usage response carries no `%s` limit — its shape has "
                "changed and that window is ungated" % kind
            )
    return results, scoped, renewed, age


# --------------------------------------------------------------------------
# --selftest: the arithmetic, against inputs chosen to be wrong in the ways
# it could be wrong. Run at build time, so a gate that computes badly stops
# the build rather than shipping quiet.
# --------------------------------------------------------------------------


def selftest():
    now = datetime(2026, 8, 24, 12, 0, 0, tzinfo=UTC)
    week = timedelta(days=7)
    five = timedelta(hours=5)
    failures, ran = [], []

    def check(name, got, want):
        ran.append(name)
        if got != want:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    def near(name, got, want):
        ran.append(name)
        if abs(got - want) > 1e-6:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    def refuses(name, thunk):
        ran.append(name)
        try:
            thunk()
        except CannotTell:
            return
        failures.append("%s: accepted what it should refuse" % name)

    # The ramp itself, at both ends and in the middle.
    near("fraction at reset", elapsed_fraction(now + week, week, now), 0.0)
    near("fraction at end", elapsed_fraction(now, week, now), 1.0)
    near("fraction halfway", elapsed_fraction(now + week / 2, week, now), 0.5)
    near("allowance at start", allowance(10, 60, 0.0), 10)
    near("allowance at end", allowance(10, 60, 1.0), 60)
    near("allowance halfway", allowance(10, 60, 0.5), 35)

    # The start percentage is the whole point of having one: at the first
    # minute of a window a pure ramp allows nothing, and every session would
    # stand down on whatever the previous window left behind.
    near("start floors the ramp", allowance(20, 50, 0.0), 20)

    # A reset further out than the window means the assumed length is wrong.
    refuses(
        "a reset beyond the window", lambda: elapsed_fraction(now + timedelta(days=9), week, now)
    )

    # Clamping, so a clock skew of a second either way is not a negative
    # allowance or one above the cap.
    near("fraction clamps low", elapsed_fraction(now + week + timedelta(seconds=0), week, now), 0.0)
    near("fraction clamps high", elapsed_fraction(now - timedelta(days=1), week, now), 1.0)

    check("ratio", ratio_of_allowance(15, 20), 75)
    check("ratio of nothing allowed", ratio_of_allowance(15, 0), 999)
    check("ratio of nothing used", ratio_of_allowance(0, 0), 0)

    # A window whose reset has passed is a window that has closed: the
    # percentage still reported belongs to it and must not hold anything out.
    closed = evaluate(
        {"percent": 90, "resets_at": instant(now - timedelta(minutes=1))}, 20, 50, five, now
    )
    check("closed window is not counted", (closed["used"], closed["go"]), (0.0, True))

    # An idle window is empty, not unreadable: the endpoint drops `resets_at`
    # when no window is open, and refusing on that stands every session down
    # against an account that has spent nothing.
    idle = evaluate({"percent": 0, "resets_at": None}, 20, 50, five, now)
    check(
        "an idle window is empty and goes",
        (idle["used"], idle["allowed"], idle["go"]),
        (0.0, 20.0, True),
    )
    check("an idle window names no reset", reset_text(idle["resets_at"]), "none")

    # Nothing left, which is not the same question as over budget. A window at
    # 100% is reported whatever the percentages say, and a window under it is
    # not reported even when the budget has already refused it.
    full = evaluate({"percent": 100, "resets_at": instant(now + five)}, 20, 50, five, now)
    over = evaluate({"percent": 80, "resets_at": instant(now + five)}, 20, 50, five, now)
    check("nothing left is reported", exhausted({"session": full}), ["session"])
    check("over budget is not nothing left", exhausted({"session": over}), [])
    check("over budget is still refused", over["go"], False)
    check(
        "both windows are named, in order",
        exhausted({"weekly_all": full, "session": full}),
        ["session", "weekly_all"],
    )
    # A closed window reports 0% used, so it can never be read as exhausted —
    # which is what stops a spent window holding sessions out past its reset.
    check("a closed window has nothing left to report", exhausted({"session": closed}), [])
    # Only at zero: a percentage with nowhere to place it is unplaceable, and
    # a window assumed for it is the one direction that lets spending past.
    refuses(
        "a percentage with no window",
        lambda: evaluate({"percent": 30, "resets_at": None}, 20, 50, five, now),
    )

    # The verdict, either side of the line, on the same numbers.
    live = {"percent": 15, "resets_at": instant(now + timedelta(days=5, hours=14))}
    check("under the line goes", evaluate(live, 10, 60, week, now)["go"], True)
    check("over the line stands down", evaluate(live, 0, 0, week, now)["go"], False)

    # Configuration that cannot be believed is not a permissive default.
    for bad in (
        {},
        {"ACCOUNT_BUDGET_X_START": "10"},
        {"ACCOUNT_BUDGET_X_START": "nope", "ACCOUNT_BUDGET_X_CAP": "60"},
        {"ACCOUNT_BUDGET_X_START": "10", "ACCOUNT_BUDGET_X_CAP": "600"},
        {"ACCOUNT_BUDGET_X_START": "70", "ACCOUNT_BUDGET_X_CAP": "60"},
    ):
        refuses("the budget %r" % bad, lambda bad=bad: budget_from_env("X", bad))
    # Half-configured is refused on the gating path: one percentage set and
    # the other missing is a mistake, not a request for defaults, and silently
    # completing it would hide the typo. The advisory path reads none of it.
    check(
        "advisory, both unset, defaults", budget_from_env("X", {}, advisory=True), ADVISORY_BUDGET
    )
    # The start must stay off zero. A zero start saturates the ratio at every
    # window boundary, which is a false alarm exactly when a fresh session is
    # most likely to be reading it.
    ran.append("the advisory start is not zero")
    if ADVISORY_BUDGET[0] <= 0:
        failures.append(
            "the advisory start is %g: a reset would saturate the ratio" % ADVISORY_BUDGET[0]
        )
    # No elapsed fraction may saturate an even burn. 999 means "no idea", and
    # an even pace is precisely the case that must never read that way.
    ran.append("an even pace never saturates")
    for tenth in range(0, 11):
        f = tenth / 10.0
        got = ratio_of_allowance(100 * f, allowance(*ADVISORY_BUDGET, f))
        if got >= 999:
            failures.append("an even pace at %.0f%% elapsed reads %d" % (f * 100, got))
    refuses(
        "gating, half set, refused",
        lambda: budget_from_env("X", {"ACCOUNT_BUDGET_X_START": "10"}, advisory=False),
    )
    refuses("gating, unset, still refused", lambda: budget_from_env("X", {}, advisory=False))
    check(
        "advisory ignores what IS set",
        budget_from_env(
            "X", {"ACCOUNT_BUDGET_X_START": "10", "ACCOUNT_BUDGET_X_CAP": "60"}, advisory=True
        ),
        ADVISORY_BUDGET,
    )
    check(
        "a good budget reads",
        budget_from_env("X", {"ACCOUNT_BUDGET_X_START": "10", "ACCOUNT_BUDGET_X_CAP": "60"}),
        (10.0, 60.0),
    )

    # Where the cache lives. Wrong, it fails in total silence: every read
    # misses, every run refetches, and the numbers printed stay perfectly
    # correct right up to the 429s. The empty case is the one worth the line —
    # it is the only value that yields a RELATIVE path.
    home_cache = os.path.expanduser("~/.cache")
    check("the cache root defaults when unset", cache_home({}), home_cache)
    check("the cache root defaults when empty", cache_home({"XDG_CACHE_HOME": ""}), home_cache)
    check(
        "a relative XDG_CACHE_HOME is refused, not joined",
        cache_home({"XDG_CACHE_HOME": "relative/cache"}),
        home_cache,
    )
    check(
        "an absolute XDG_CACHE_HOME is honoured",
        cache_home({"XDG_CACHE_HOME": "/elsewhere/cache"}),
        "/elsewhere/cache",
    )

    # The cache TTL. Unset is the default here and a refusal two functions up,
    # so the case says which is which; everything unbelievable is refused
    # either way, because a wrong TTL reads in the same numbers a right one
    # does.
    check("the ttl defaults when unset", cache_minutes({}), CACHE_MINUTES_DEFAULT)
    check(
        "the ttl defaults when empty", cache_minutes({CACHE_MINUTES: "  "}), CACHE_MINUTES_DEFAULT
    )
    check("a ttl of zero is a real answer", cache_minutes({CACHE_MINUTES: "0"}), 0.0)
    check("a ttl reads", cache_minutes({CACHE_MINUTES: "12"}), 12.0)
    for bad in ("nope", "-1", "300", "1e9"):
        refuses("the ttl %r" % bad, lambda bad=bad: cache_minutes({CACHE_MINUTES: bad}))

    # The credential preference, which is the one thing here that reads
    # exactly right when it is wrong: a gate that ignored the variable would
    # fall back to the file, find a perfectly good one, and report a verdict
    # about a credential the session is not using. Stubbed rather than live —
    # what is under test is which token is chosen, and that needs no network.
    #
    # CREDENTIALS is redirected for the whole block, at a path that cannot
    # exist, because a selftest that fell through to the REAL file would read a
    # live token and could print it in a failure message.
    # see docs/budget.md#the-selftest-reads-no-live-credential
    global fetch_usage, CREDENTIALS, CACHE, refresh
    real_fetch, real_credentials, seen = fetch_usage, CREDENTIALS, []
    real_cache, real_refresh = CACHE, refresh

    def stub(token, source="the stored credential"):
        seen.append(token)
        return {"five_hour": {}, "seven_day": {}}

    try:
        fetch_usage = stub
        CREDENTIALS = "/nonexistent/selftest/.credentials.json"

        # CLAUDE_CODE_OAUTH_TOKEN must be ignored: it is an inference
        # credential and the usage endpoint answers 403 to it, so preferring it
        # stands every session down while `claude -p` works. With the variable
        # set and no credentials file, the refusal must name the FILE and
        # nothing must have been sent.
        refuses(
            "the env token is not a usage credential",
            lambda: read_usage(environ={ENV_TOKEN: "sk-ant-oat01-whatever"}),
        )
        check("and nothing was sent under it", seen, [])
        try:
            read_usage(environ={ENV_TOKEN: "sk-ant-oat01-whatever"})
        except CannotTell as why:
            ran.append("the refusal names the credentials file")
            if "credentials" not in str(why):
                failures.append("the refusal does not name the credentials file: %s" % why)
    finally:
        fetch_usage, CREDENTIALS = real_fetch, real_credentials

    # The cache fails silently in both directions, so both directions have a
    # case: never used, the 429s come back; consulted too early, the access
    # token stops being renewed and nothing says so for the eight days the
    # refresh token has left. Both read as working. Stubbed and pointed at a
    # temporary directory, since what is under test is which calls happen.
    holder = tempfile.mkdtemp(prefix="claude-usage-selftest-")
    try:
        CREDENTIALS = os.path.join(holder, ".credentials.json")
        CACHE = os.path.join(holder, "usage.json")
        fetch_usage = stub
        renewals = []

        def refresh_stub(whole, oauth):
            renewals.append(True)
            return {"limits": []}

        refresh = refresh_stub
        # Against the real clock, not the frozen `now` above: read_usage asks
        # the system what time it is, and a credential expiring in the frozen
        # clock's terms would be renewed on every call here.
        real_now = datetime.now(UTC)

        def credentials_expiring_in(delta):
            with open(CREDENTIALS, "w") as handle:
                json.dump(
                    {
                        "claudeAiOauth": {
                            # Not a token shape, deliberately. gitleaks reads this
                            # repository and a plausible one here is a finding on
                            # every scan for as long as the file exists.
                            "accessToken": "selftest-placeholder",
                            "refreshToken": "selftest-placeholder",
                            "expiresAt": int((real_now + delta).timestamp() * 1000),
                        }
                    },
                    handle,
                )

        def clear_cache():
            try:
                os.remove(CACHE)
            except OSError:
                pass

        def stamped_cache(read_at):
            with open(CACHE, "w") as handle:
                json.dump({"read_at": read_at.timestamp(), "usage": {"limits": []}}, handle)

        # An explicit TTL rather than the ambient environment: a host with it
        # set to 0 would turn every case below green for the wrong reason.
        five, off = {CACHE_MINUTES: "5"}, {CACHE_MINUTES: "0"}
        credentials_expiring_in(timedelta(hours=8))
        del seen[:]
        read_usage(environ=five)
        check("a cold cache reads the endpoint", len(seen), 1)
        _, _, age = read_usage(environ=five)
        check("a warm cache does not read again", len(seen), 1)
        ran.append("a cached reading knows it is one")
        if age is None:
            failures.append(
                "a cached reading reported no age, so a stale one "
                "would print in the same words as a fresh one"
            )

        # Written by hand rather than waited for, both ways round. A stamp in
        # the future is a clock that moved, not a reading from later.
        stamped_cache(real_now - timedelta(minutes=6))
        del seen[:]
        read_usage(environ=five)
        check("an expired cache reads again", len(seen), 1)

        stamped_cache(real_now + timedelta(hours=1))
        del seen[:]
        read_usage(environ=five)
        check("a future stamp is not a fresh reading", len(seen), 1)

        with open(CACHE, "w") as handle:
            handle.write("{ this is not json")
        del seen[:]
        read_usage(environ=five)
        check("a corrupt cache costs a request, not an answer", len(seen), 1)

        # ACCOUNT_BUDGET_CACHE_MINUTES=0 means off, and off has to mean both
        # halves: nothing read back, and nothing left on disk either.
        credentials_expiring_in(timedelta(hours=8))
        clear_cache()
        del seen[:]
        read_usage(environ=off)
        read_usage(environ=off)
        check("a zero ttl caches nothing", len(seen), 2)
        ran.append("a zero ttl leaves no file behind")
        if os.path.exists(CACHE):
            failures.append("a zero ttl wrote a cache file it will never read")

        # A reading kept under one TTL must not be served under a shorter one.
        clear_cache()
        del seen[:]
        read_usage(environ={CACHE_MINUTES: "30"})
        stamped_cache(real_now - timedelta(minutes=10))
        read_usage(environ={CACHE_MINUTES: "30"})
        check("30 minutes keeps a ten-minute-old reading", len(seen), 1)
        read_usage(environ=five)
        check("5 minutes does not", len(seen), 2)

        # The one that matters: a warm cache must not shortcut the renewal.
        # This call is what keeps the login alive on the days nothing is
        # scheduled, and nothing else in the system would report its absence.
        credentials_expiring_in(timedelta(hours=8))
        del seen[:]
        read_usage()
        credentials_expiring_in(REFRESH_MARGIN / 2)
        read_usage()
        check("an expiring token renews past a warm cache", len(renewals), 1)
    finally:
        fetch_usage, CREDENTIALS = real_fetch, real_credentials
        CACHE, refresh = real_cache, real_refresh
        shutil.rmtree(holder, ignore_errors=True)

    for failure in failures:
        print("FAIL %s" % failure, file=sys.stderr)
    if failures:
        return 1
    # Counted rather than written down. A number typed here is a second copy
    # of how many checks there are, and the copy is the one that goes stale.
    print("claude-usage: %d checks pass" % len(ran))
    return 0


# --------------------------------------------------------------------------


def main(argv):
    as_environment = "--env" in argv[1:]
    force_refresh = "--refresh" in argv[1:]
    # --advisory is not a gate. It answers "how fast am I spending", for a
    # session to be told, and never "may this session start" — so it cannot
    # stand anything down: over budget and could-not-tell both exit 0, and
    # could-not-tell prints no numbers rather than inventing them.
    #
    # It exists because the two questions have different credentials behind
    # them. The gate runs on the HOST against a login that reads usage; this
    # runs in the container, where the login may belong to another account, or
    # be an inference-only token, or not exist. All three are fine for an
    # indication and none of them is fine for a decision.
    advisory = "--advisory" in argv[1:]
    if "--selftest" in argv[1:]:
        return selftest()
    known = ("--env", "--refresh", "--selftest", "--advisory")
    unknown = [a for a in argv[1:] if a not in known]
    if unknown:
        print(
            "Usage: claude-usage.py [--env] [--refresh] [--advisory] [--selftest]", file=sys.stderr
        )
        return CANNOT_TELL

    try:
        results, scoped, renewed, age = assess(
            os.environ, datetime.now(UTC), force_refresh, advisory=advisory
        )
    except CannotTell as why:
        # stderr, always, and not only on a terminal: over budget is routine
        # and silent, a gate that cannot read is not. Cron mails stderr, so
        # this is the line that arrives on the day the mechanism dies.
        print("claude-usage: cannot tell — %s" % why, file=sys.stderr)
        # Advisory: say nothing on stdout and succeed. A caller that exports
        # what this prints must end up with no ACCOUNT_USAGE_* at all rather
        # than with the word "unknown", because "unknown" is a value a session
        # would have to interpret, and there is nothing to interpret — the
        # question simply was not answered.
        if advisory:
            return GO
        if as_environment:
            for _, name in GATED.values():
                print("ACCOUNT_USAGE_%s=unknown" % name)
            print("VERDICT=cannot tell: %s" % why)
        return CANNOT_TELL

    blocked = [kind for kind, result in results.items() if not result["go"]]
    spent = exhausted(results)
    if blocked:
        verdict = "over budget: " + "; ".join(
            "%s %.1f%% used against %.1f%% allowed"
            % (kind, results[kind]["used"], results[kind]["allowed"])
            for kind in blocked
        )
    else:
        verdict = "within budget: " + "; ".join(
            "%s at %d%% of its allowance" % (kind, results[kind]["ratio"])
            for kind in sorted(results)
        )

    if as_environment:
        for kind, (_, name) in GATED.items():
            print("ACCOUNT_USAGE_%s=%s" % (name, as_env(results[kind])))
        # The budget actually used, under the names it is configured with, and
        # not an echo of the input: the advisory path uses 5-100 whatever is
        # set, and a reader finding `budget=5-100` beside
        # ACCOUNT_BUDGET_SESSION_START=20 would have two answers to one
        # question.
        #
        # Printed only on the path that reached a verdict, like everything
        # else here, so usage and budget are absent together and never
        # half-present.
        for kind, (_, name) in GATED.items():
            print("ACCOUNT_BUDGET_%s_START=%g" % (name, results[kind]["start"]))
            print("ACCOUNT_BUDGET_%s_CAP=%g" % (name, results[kind]["cap"]))
        # One line, entries joined, because these become environment variables
        # and an environment cannot hold a name twice: one line per scoped
        # limit means the consumer exports the last and loses the rest. The
        # value stays the prose the text mode prints, carried whole — a decoder
        # here would be a thing that can be wrong in front of a renderer that
        # cannot.
        # see docs/budget.md#the-host-forwards-by-prefix-not-by-name
        #
        # Printed even when empty, so the variable exists on both paths and a
        # reader never has to tell "no scoped limits" from "this source does
        # not report them".
        print("ACCOUNT_USAGE_SCOPED=%s" % "; ".join(scoped))
        # Printed on every path that reached a verdict, empty included, so a
        # reader tells "nothing is exhausted" from "there was no reading" —
        # the cannot-tell path above prints no line at all, because there the
        # honest answer is that the question was not reached.
        print("EXHAUSTED=%s" % ",".join(spent))
        if renewed:
            print("RENEWED=1")
        # Deliberately not an ACCOUNT_* name: session-env.sh forwards this
        # tool's ACCOUNT_USAGE_* and ACCOUNT_BUDGET_* into the container by
        # prefix, and how old the HOST's reading was is the host's business —
        # the session is already told that everything it is given is a
        # snapshot. Printed only when there is an age to print, like RENEWED.
        if age is not None:
            print("READING_AGE=%d" % int(age.total_seconds()))
        print("VERDICT=%s" % verdict)
    else:
        for kind in GATED:
            print(as_text(kind, results[kind]))
        for line in scoped:
            print("  also: %s" % line)
        # Said on the advisory path too, unlike the verdict below: a window
        # with nothing left is a fact about the account, true whoever asked.
        if spent:
            print("  nothing left in: %s" % ", ".join(spent))
        if renewed:
            print("  (the access token was renewed)")
        # Said out loud, because a cached reading must not print in the same
        # words a live one does.
        if age is not None:
            print("  (from a cached reading %s old)" % age_text(age))
        # A verdict is a gate's word. Nothing refuses on the advisory path, so
        # "over budget" there is false, and the numbers above are the answer.
        if not advisory:
            print(verdict[0].upper() + verdict[1:])

    # Over budget is a fact to report and not a refusal, on this path.
    if advisory:
        return GO
    return GO if not blocked else STAND_DOWN


if __name__ == "__main__":
    sys.exit(main(sys.argv))
