#!/usr/bin/env python3
"""PreToolUse guard for Bash: gate commands that permission rules cannot express.

Template. Copy into a project as `.claude/hooks/bash_guard.py`, then edit only
the REGISTRY section near the bottom. Everything above it is meant to travel
between projects unchanged.

THIS COPY is the agent's, vendored from the `tools` repository's specify assets
and baked to `/usr/local/bin/bash-guard.py` — in the image, not in the agent's
repository and not in the volume, for the same reason `push-on-exit.sh` is: a
guard the agent could blank would stop guarding with no symptom.

Two things diverge from the template, and a refresh means re-copying it and
re-applying both. The REGISTRY and its CASES, by decision: the git tool keeps
only the template's `commit -m` grant, `gh` and `bws` are added, and docker is
dropped — re-applying means DELETING the template's git denies again, which
is the divergence that looks like an omission rather than a change. And
`under()` in the engine, by necessity: it called a pathlib method that does not
exist on this image's python. Each says so where it sits, and the record is in
docs/boundary.md#the-guards-divergences-from-the-template.

Everything else in this file, this docstring included, is the template's and
describes the template — where it says `.claude/hooks/` or names docker, read
it as the general case, not as this image.

Permission patterns match a command prefix. That cannot express "a force push
however it is spelled" (`git push origin --force`), nor "safe only when a flag
is set" (`ansible-playbook site.yml --syntax-check`), because the deciding
token can sit anywhere and Claude tends to put it last.

Everything here is decided on *parsed* argv, one subcommand at a time. Matching
the raw line with regexes is unsound in both directions: `git commit -m 'fix
the --amend bug'` is not an amend, and in `ansible-playbook --syntax-check
a.yml && ansible-playbook deploy.yml` the safe half must not vouch for the
other. Only tokenizing resolves quoting; only splitting separates invocations.

A line can also hide a command inside another one. Assignments bind to what
runs next (`GIT_SSH_COMMAND=… git fetch`), wrappers run something else (`sudo
git push --force`), a shell's `-c` argument is a command line in its own right,
and a substitution or subshell is another command again — `echo $(git push
--force)`, and equally `git commit -m "$(git push --force)"`, where the quoting
hides it from the tokenizer entirely. Each is walked through to the command
underneath, and every command position found is judged — so gating a wrapper
never hides what it wraps.

Decisions: **deny** what has no authorized use, **ask** for anything that
writes outward or destroys work, stay silent otherwise. Silence is not approval
— it hands the call back to the permission rules and the current permission
mode, and what that mode then does with an unmatched command (prompt,
auto-approve, judge by classifier) is a property of the installed version,
probed at instantiation, never assumed from this docstring. There is also one
**allow**, which is the exception the next section is about.


WHERE THE GUARD GRANTS
----------------------

Almost nowhere, and the constraint is worth stating before the exception.

A hook's `"allow"` skips the interactive prompt — and measurement says it also
lifts two things the documentation does not mention: the bash safety
heuristics, and the **working-directory sandbox**. `touch ../escaped.txt`,
blocked outright when merely permitted by a rule, runs when a hook allows it.
So granting is not "approving a prompt on the operator's behalf"; it is
switching off the boundary that keeps a mistake inside the project. What it
cannot do is override a `deny` or `ask` rule from settings — those still hold,
which is why they, not this file, are the right place for anything that must
never happen.

That rules out the tempting general form, "if every command in the line is
silent, allow it". `touch "$(cat evil.txt)"` has nothing gated in it, and the
substitution's output becomes a path, which the guard never sees because it
does not exist until after the decision.

What remains is a grant keyed to a *shape whose output cannot direct a write*.
`git commit -m "$(…)"` qualifies: whatever comes back is a commit message.
That earns the one `Rule("allow", …)` in the registry, hedged three ways — it
ranks below deny and ask, it is withheld if anything else in the line has an
opinion, and `allow_globals` withholds it if any global option was used.

The reason it is worth having at all: Claude Code prompts on *any* line
containing a substitution, no permission rule can lift that, and the system
prompt pushes Claude toward writing them. Without the grant that prompt is
unavoidable and constant, which is how operators end up in a looser
permission mode — where
the sandbox is gone for everything, not just for one proven shape.

Before adding a second one, satisfy yourself that no expansion of the granted
command can become a path or a command. If it can, the answer is silence.


HOW A VERDICT IS REACHED
------------------------

Each command in a line is judged on its own, and the strongest verdict in the
line wins: deny, then ask, then allow, then silence. Within one invocation:

* a **Rule** that matches contributes its verdict — deny, ask or allow — and
  rules are consulted whether or not the tool declares grants;
* a **Grant** that matches contributes nothing: it is the absence of an
  objection, which is what silence means here;
* if nothing else applied, **`gated_verdict`** is contributed — the tool's
  answer for an invocation nothing matched;
* if that leaves nothing, the guard stays silent and the permission rules and
  the current mode decide.

`gated_verdict` set holds whether or not the tool declares grants, which is how
"everything here is the operator's" is said — a tool with no grants and
`gated_verdict="deny"` refuses every invocation, with its reason. Left unset it
derives: silent for a tool with no grants, `ask` for one that declares grants
and was not granted. So the common shapes need nothing: git and docker declare
rules and stay silent elsewhere; a deploy tool declares grants and asks
elsewhere; and a project that has decided unproven means refused says
`gated_verdict="deny"` once.

Two cases follow from that and are worth stating, because both look like holes
and neither is:

*Rules but no grants, and no rule matched* — silence. That is the safe-by-
default model working: the acts worth naming are named, everything else falls
through to the permission rules. git and docker are this shape.

*Neither rules nor grants* — silence, always. Such an entry exists for a
different job: it declares `nested`, so the guard can walk through it to the
command it runs, or it names aliases. Every shell wrapper is this shape.

`--liveness` checks the pair rather than the shape: a `gated_verdict` that is
not a real verdict, or one set with no `gated_reason` — a refusal that says
nothing is worse than none, since the reader cannot tell a rule from a bug.

A worked example, because the interaction is the part that misleads. With
`gated_verdict="deny"` and a grant on "any operand is a read verb", a deny
*rule* for write verbs looks redundant — a write-only command matches no grant
and is denied already, and `osmp server list && osmp server delete x` is
denied on its second invocation, since each is judged alone. It is not
redundant for one case: an operand that is a read verb without being a verb.

    openstack server delete list        # a server named "list"

The grant sees `list`, holds, and the command goes silent. Only a rule reading
"a write verb sits in this command" catches it. That is the whole of what such
a rule buys once judging is per-invocation, and it is worth its line where the
tool reaches real infrastructure.


CHOOSING A RULE KIND
--------------------

Put the enumeration on whichever side of the tool is finite, and let the
residue land on the safe default.

*Safe by default, with a listable set of dangerous acts* — git, docker, most
CLIs you read with. Declare `rules`. They are checked **existentially**: if any
subcommand in the line is a named act, the line is gated; everything unnamed
falls through silently, which is right because most of it is harmless.

*Dangerous by default, with a small safe set* — ansible-playbook, terraform,
kubectl, deploy scripts. Declare `grants`. They are checked **universally**:
every invocation must match a proven-safe shape, closed-world, and anything
else asks. A flag you never considered can then only move a verdict toward the
prompt, never away from it.

Getting this backwards is expensive both ways. Grants for git would mean
enumerating hundreds of safe subcommands, prompting on every one you forgot.
Rules for ansible would give you nowhere to put "unless --syntax-check", since
rules only fire — they never exempt.

A tool may declare both. Rules then hold regardless of the grants: a rule can
deny an act that a grant would otherwise have waved through.


WHAT MUST LAND IN settings.json
-------------------------------

This guard gates, and grants in exactly one place (see WHERE THE GUARD GRANTS).
It cannot loosen a `deny` or `ask` rule, so those remain yours alone. Pair it
accordingly:

1.  **Allow the tool broadly; let the guard claw back.** For every rule- or
    grant-bearing tool, add a broad allow — `Bash(git:*)`, and one line per
    such tool the project adds. Never for the SHELL_WRAPPERS layer: a broad
    allow on a command-runner is a broad allow on everything it runs when
    the guard is dead. Prefix rules respect word boundaries, so `Bash(git:*)` does
    not leak to `git-crypt`. This is the whole point: broad allow plus a narrow
    hook is what replaces a long, brittle allow list. A gated tool with no
    allow line is pointless — it would prompt on everything anyway, and its
    grants would never be reached.

2.  **Never write an `ask` rule for a tool the guard gates.** Rules are
    evaluated deny → ask → allow, and a matching `ask` prompts *even when a
    hook returns "allow"*. An `ask Bash(ansible-playbook:*)` therefore makes
    every carve-out impossible, including the guard's. That mistake is the
    reason this file exists — express the exception here, in a `Grant`.

3.  **Do not restate the guard's asks in settings.** A prefix rule is strictly
    weaker: `Bash(git push:*)` misses `git -C dir push`, which the guard
    catches. Two sources of truth, one of them wrong.

4.  **Do keep a short `deny` backstop for the unrecoverable acts.** A hook that
    crashes — a syntax error from an edit, a lost `+x`, a missing python3 —
    fails *open*: Claude Code logs the failure and proceeds to the permission
    rules. The guard's own try/except cannot catch that, because the module
    never loaded. Denies are prefix-weak (they miss `git push origin --force`),
    but they cost nothing and they cover the losses you cannot undo.

    This need is created by step 1. Under a narrow allow list a dead guard only
    costs extra prompts; under `Bash(git:*)` it costs an unprompted
    `git push --force`. The broad allow and the deny list are a package.

5.  **Mind the permission mode.** In a mode that prompts on unmatched
    commands, the guard's silence is backed by a prompt; in a mode that
    suppresses or delegates that prompt, the guard's asks may be the only
    gate left — which is exactly when the grants carry real weight. The
    mode list and each mode's actual unmatched-command behavior belong to
    the installed version: probe and record them, never take them from
    this docstring.

A minimal pairing for the default registry, which carries git and docker.
Add one allow line per tool the project puts in the registry:

    "permissions": {
      "allow": [
        "Bash(git:*)",
        "Bash(docker:*)"
      ],
      "deny": [
        "Bash(git push --force:*)",
        "Bash(git push -f:*)",
        "Bash(git filter-branch:*)",
        "Bash(git reflog expire:*)"
      ]
    },
    "hooks": {
      "PreToolUse": [
        { "matcher": "Bash",
          "hooks": [ { "type": "command",
                       "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/bash_guard.py" } ] }
      ]
    }


CHANGING THE RULES
------------------

The registry is not ordinary code. It is the boundary the operator relies on,
so it does not move on the assistant's own judgement.

*The GIT tool is ground rules.* It is the same in every project by design, and
it encodes losses that are permanent or expensive to undo. Do not add, weaken
or remove a git rule to get past a prompt in front of you. Changing it needs a
reason specific to the project and stated out loud — "this repo has no remote,
so pushing cannot happen" is one; "the prompt was in my way" is not. If a git
rule fires and you believe it should not have, that is a case to report, not a
rule to edit.

*Every rule change is the operator's call.* Adding, modifying or deleting any
Rule, Grant, known_flag or tool — propose it, say what it would newly allow or
newly gate, and wait for the operator to agree. The one exception is creating
this file from the template at the start of a project: the operator reviews the
whole registry in a single pass then, so the initial set does not need to be
approved rule by rule.

*A surprise becomes a test.* When the operator reports that the guard did the
wrong thing — prompted on something harmless, stayed silent on something it
should have caught — the fix is not complete until CASES contains the exact
command they reported, asserting the corrected verdict. A rule change with no
reproduction case is a regression waiting to happen, and the report is the only
evidence of what the rule was actually for.


WHAT THIS DOES NOT SEE
----------------------

The guard reads a command line; it does not run a shell. These are known and
accepted, listed so nobody mistakes silence for coverage.

*Substitution, which is covered, and is named here only to say so.* An
unquoted `$(…)`,
`<(…)` or `(…)` is split into its own tokens by the lexer and walked like any
other command; a quoted one — `-m "$(git push --force)"` — never reaches that
splitting, so it is read off the raw line instead, counting parentheses and
tracking single quotes. Double quotes and backticks run, so they are judged;
single quotes do not, so they are left alone. All of it is asserted in
ENGINE_CASES.

*A runner we do not recognise.* `myrunner git push --force` is silent, because
the first word is neither a registered tool, a known wrapper, nor a shell. The
fix is to add the runner to SHELL_WRAPPERS — deliberately, rather than by
guessing; guessing was tried, and a tool's name is also an ordinary word and an
ordinary directory. A known wrapper we cannot see past is a different case,
with a real signal behind it, and always asks.

*Program text in another language.* A shell's `-c` argument is re-examined;
`python3 -c` and `node -e` are not, since reading their argument as shell would
be guesswork.

*An argument made only of separator characters.* `git commit -m "&&"` splits
where the quoted `&&` sits, because posix tokenizing has already dropped the
quotes and the token is indistinguishable from the operator. It takes a
message that is *only* punctuation, so it has not seemed worth abandoning posix
mode over — but it is real.

*Handoff option arity is approximate.* `Nested.value_opts` covers the common
options; an unknown value-taking one makes the walk lose the command being run,
which asks. That direction is deliberate: a handoff we cannot follow is
unproven, not safe. The reverse — declaring a bare flag as value-taking — is
the one that loses something, since it skips a token too many and can step over
the command itself.


KEEPING IT HONEST
-----------------

This file is written at 88 columns and keeps them wherever it is vendored. A
project whose lint is narrower exempts the width rule for this path alone —
every other rule still applies — because reflowing it makes each refresh a
diff against your reformatting rather than against the template, and because
the formatter's answer here is worse: a nine-word set becomes eleven lines and
the comment explaining each dataclass field strands after a closing paren.
(With pre-commit, the exemption also needs `force-exclude`, since filenames
are passed explicitly.)

Because a broken guard fails open silently, it has to be gated twice, and the
two gates ask different questions.

`--liveness` asks *is this guard alive*: the file is executable, the registry
builds, every declared rule and grant is well-formed, and a payload on stdin
still comes back as a verdict. It runs no behaviour cases, so it stays a lint.
Wire it into whatever the project runs before a commit — that is where the
silent deaths happen: a syntax error from an edit, a lost `+x`, a rename.

`--selftest` asks *does this guard decide correctly*: liveness first, then
every case in CASES and ENGINE_CASES, then coverage — a rule or grant no case
reaches fails it. Wire that into the project's test entry point. Add a case
for every rule you add; that is the only place the intent is written down in
an executable form, and the coverage check is what makes it mandatory rather
than advisory.

Neither answers *is this guard reached*. A path in `settings.json` that names
a file which is not this one leaves valid JSON, a settings file that loads, a
green lint — and a guard that never runs. Nothing here can see that, so the
project checks the pointer itself (its governance well-formedness family is
the place) and probes it live: a command this guard refuses must come back
refused *by it*, naming the rule. If it merely prompts, the hook is not
reaching the tool call and only the deny backstop is left.

A project harness may also prove what CASES cannot. Cases are strings written
by hand; a harness can derive them — every playbook under an exempt directory
must be silent, every one outside it gated, so a file added tomorrow is judged
tomorrow without anyone remembering. Derive what only the project can derive,
and leave the rest here: a case about how a command line is read belongs in
ENGINE_CASES, one about a tool's verdicts in CASES, and duplicating either in
a harness means two places to update and one of them silently wrong.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import cast

# =========================== engine ========================================
# Portable. Nothing below the REGISTRY banner should need to change here.

HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")
INTERPRETER = re.compile(r"\b(ba|z|k|da)?sh\b|\bpython3?\b|\bperl\b|\bruby\b|\bnode\b")
SCRIPT_RUNNERS = {"python", "python3", "py", "sh", "bash", "zsh", "ruby", "perl", "node"}

# Shells whose `-c` argument is another command line, and so is re-examined.
# Deliberately not python or node: their `-c` is program text in another
# language, and reading it as shell would be guesswork.
#
# DIVERGES FROM THE TEMPLATE. Words the shell reads as syntax rather than as a
# command: a segment beginning with one of them is still running whatever
# follows it, and without them the walk stops at argv[0] — which is neither a
# registered tool nor a wrapper — and goes silent. Skipping is safe in a way
# guessing was not: it removes syntax the shell itself discards, rather than
# asking about a line it cannot identify.
# see docs/boundary.md#the-guard-reads-parsed-argv
SHELL_KEYWORDS = {
    "{",
    "}",
    "(",
    ")",
    "!",
    "if",
    "then",
    "elif",
    "else",
    "fi",
    "while",
    "until",
    "for",
    "select",
    "do",
    "done",
    "case",
    "esac",
    "in",
}

SHELL_RUNNERS = {"sh", "bash", "zsh", "dash", "ksh"}

# Builtins that join their arguments and run the result as a command line.
# They cannot be handled as wrappers: stepping over `eval` reaches the next
# *token*, which for `eval "git push --force"` is the whole command as one
# quoted string — a token that names no tool, so the line would go silent.
EVAL_RUNNERS = {"eval"}
DASH_C = re.compile(r"^-[a-zA-Z]*c$")  # -c, -lc, -ec …
MAX_DEPTH = 3  # `sh -c 'sh -c …'` must terminate


# Claude Code's documented separator set is `&&`, `||`, `;`, `|`, `|&`, `&` and
# newlines. Testing the characters rather than the whole token covers all of
# them and the runs shlex groups into one token besides — `\n\n\n` from blank
# lines, `;;`, `&&&`.
#
# The newline is load-bearing, not an afterthought: without it a multiline
# command string parses as one invocation whose subcommand is the first line's,
# and nothing after that first command can be judged.
SEPARATOR_CHARS = {"&", "|", ";", "\n"}

# Everything the lexer treats as punctuation, and so groups into its own token.
# Parentheses are in here because they open and close a command.
PUNCTUATION_CHARS = set("();<>|&\n")

# Every redirection operator, longest spelling first so `&>>` is not read as
# `&>` and `<<<` is not read as `<<`. Spelled out rather than matched as a run
# of `<>&` for one reason: such a run eats the `&&` in `a >b && c`.
REDIRECTION = re.compile(r"&>>|&>|<<<|<<-|<<|>>|>\||<>|>&|<&|<|>")

# Where a shell word ends: whitespace, or the punctuation that starts
# something else. `\n` is in here and is not skipped over as space — a
# redirection whose target is on the next line is not a redirection.
WORD_BREAK = set(" \t\r\n;|&<>()")

DIGITS = "0123456789"

# The shell joins a backslash-continuation into one line before splitting, so
# we must too — otherwise the escaped newline glues itself to the next token
# and `git push \<newline>--force` hides `--force` inside an operand.
CONTINUATION = re.compile(r"\\\n[ \t]*")

# `FOO=bar cmd …` sets FOO for that one command. Only assignments *before* the
# command name are environment; `git push FOO=bar` is an operand. They are
# matchable in their own right rather than merely skipped, because an
# assignment can be more dangerous than any flag — `GIT_SSH_COMMAND=…` runs an
# arbitrary program during a fetch, `GIT_DIR=…` retargets the whole operation.
#
# The name pattern is the shell's, which is why it accepts lower case: `foo=1`
# is as valid a prefix as `FOO=1`. `+=` is bash's append form and is a command
# prefix too, so it must be recognised — otherwise the token is not an
# assignment, becomes argv[0], resolves to no tool, and the whole command goes
# unexamined. Matching against known_env and Rule.env is by exact name, and so
# is case sensitive, as shell variables are.
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")

# A grant condition on a flag's value: a compiled regex, or a predicate for
# when the raw string is not what matters (a path that needs normalizing).
Matcher = re.Pattern[str] | Callable[[str], bool]

# What makes a location a glob rather than a plain directory, in `under`.
GLOB_CHARS = set("*?[")

# Whether Claude Code's own substitution heuristic will fire on this line —
# the only situation in which a grant is used rather than downgraded to
# silence. Textual on purpose: the thing being predicted is itself textual.
SUBSTITUTION = re.compile(r"\$\(|`")

# Operands and flag values of a *gated* tool must look like ordinary words.
# Anything stranger is unproven rather than safe.
VALUE_OK = re.compile(r"^[\w./=@:+-]+$")

# Set by --selftest to collect the rules and grants the cases actually reach.
# A rule no case can trigger is a rule nobody has checked, so the selftest
# fails on it — and a grant is checked the same way, for the opposite failure:
# an unreached grant means the proven-safe shape it declares has never been
# shown to resolve to silence. That direction is safe (the tool over-prompts)
# and therefore quiet, which is exactly why it needs the mechanical check.
AUDIT: set | None = None


@dataclass(frozen=True)
class Rule:
    """An act worth a verdict: this subcommand path, optionally with these flags.

    `path` is matched as a prefix of the invocation's operands, so ("push",)
    covers `git push origin main`, and ("reflog", "expire") reaches a
    second-level subcommand. `flags` is a trigger set — the rule fires when any
    one of them is present, wherever it sits — and `None` means the path alone
    is the act, no flag needed.

    `env` names environment assignments the same way, for the cases where the
    danger is in the environment rather than the command line. Conditions are
    ANDed: a rule with both fires only when a listed flag *and* a listed
    assignment are present. To gate on either alone, write two rules.

    Note the limit: `flags` and `env` test presence, never value. A rule can
    say "never --force"; it cannot say "never -i production". Value conditions
    live only in `Grant.flag_values` / `Grant.env_values`, and yield `ask`
    rather than `deny`.

    A verdict of `"allow"` is the one that grants, and it is the exception to
    everything else in this file — see WHERE THE GUARD GRANTS. It wins only
    when nothing else matched, it is withheld unless every command embedded in
    the line is silent too, and `allow_globals` bounds which of the tool's
    global options may be present. That list is closed-world like the rest: an
    unlisted global withholds the grant, because a forgotten entry must cost a
    prompt rather than give one away. `git --exec-path=/tmp/x commit` runs
    `/tmp/x/git-commit`, and `-c core.pager=…` is the same kind of hole, so the
    default of "no globals at all" is the honest starting point.
    """

    verdict: str  # "deny" | "ask" | "allow"
    path: tuple[str, ...]
    reason: str
    flags: frozenset[str] | None = None
    operands: Matcher | AnyOf | None = None  # None: the path alone is the act
    env: frozenset[str] | None = None  # None: no environment condition
    allow_globals: frozenset[str] = frozenset()  # allow rules only


@dataclass(frozen=True)
class Grant:
    """One proven-safe shape of an invocation of a gated tool.

    Every condition set here must hold for the grant to apply; a tool is silent
    when *any* of its grants applies. An empty `path` matches any subcommand,
    which is what a tool like ansible-playbook needs, having none.

    `require_any` names flags of which at least one must be *operative* — a
    token counts only if the parser saw it as a flag, so a `--syntax-check`
    swallowed as the value of `-i` does not satisfy it (see `Tool.value_flags`).
    `flag_values` additionally constrains what a flag was given, which is how
    "safe only when --target is under /tmp" would be expressed. `operands`
    constrains every operand past `path`, and requires at least one — that is
    where a tool like `rm` carries the paths it acts on, so it takes the same
    matchers as the rest.

    A matcher is a compiled regex or a predicate taking the value, in every one
    of those three positions. A regex is right when the raw string is what
    matters — a keyword, a name — and is anchored at the start, as `re.match`
    is: write `^(?:.*/)?name$` rather than relying on a search. For a path, use
    `under(...)`: a regex for `^/tmp/` says yes to `/tmp/../root`, which is a
    real traversal past the very boundary the grant exists to draw.
    """

    path: tuple[str, ...] = ()  # required leading subcommands
    require_any: frozenset[str] = frozenset()  # at least one must be operative
    flag_values: tuple[tuple[str, Matcher], ...] = ()  # flag must be given and match
    env_values: tuple[tuple[str, Matcher], ...] = ()  # assignment must be present, match
    operands: Matcher | AnyOf | None = None  # every operand past `path` must match
    allow_operands: bool = True  # False: no operands past `path`


@dataclass(frozen=True)
class Nested:
    """Where a tool stops describing itself and starts running something else.

    `sudo git push` and `docker run alpine git push` both hand off; they differ
    only in where. `path` is the subcommand that does it — empty for a plain
    wrapper, `("run",)` for docker, `("compose", "run")` for its compose form.
    `value_opts` are the tool's own options that consume the next token, and
    `operands` counts positionals it keeps for itself: `timeout 30 cmd` has
    one, `docker run … IMAGE cmd` has one.

    Getting `value_opts` or `operands` wrong costs a prompt, not silence: a
    handoff we cannot follow asks.
    """

    path: tuple[str, ...] = ()
    value_opts: frozenset[str] = frozenset()
    operands: int = 0


@dataclass(frozen=True)
class Tool:
    """How to recognize, parse and judge one command.

    `rules`
        Dangerous acts, checked existentially: any match gates the line.
        Consulted whether or not the tool is gated.

    `grants`
        Proven-safe shapes, checked universally: an invocation is silent only
        if it matches one. `None` means the tool is not gated and only `rules`
        apply; an empty tuple means gated with nothing declared safe, so every
        use asks.

    `gated_reason`
        The text shown in the permission prompt when no grant holds. It is the
        only thing read while deciding, so it should name the risk *and* the
        way to satisfy a grant ("rehearse it with --target under /tmp").
        Unused when `grants` is None.

    `known_flags`
        The closed world for a gated tool: every flag on the invocation must
        appear here, or the invocation is unproven and asks. This is not the
        tool's flag list — it is the set you have decided is safe to see, so
        leaving a flag out is how you gate it. The consequence worth keeping: a
        flag you never considered can only move a verdict toward the prompt,
        never away from it. Expect to extend this a few times early on; each
        addition should be a decision, not a reflex. Unused when not gated.

    `aliases`
        Other binary names that behave identically — `podman` for `docker`,
        `nerdctl` for both. The registry indexes the tool under each, so a
        drop-in replacement needs no second entry to keep in step.

    `nested`
        Where this tool runs another program, so the guard follows through to
        it. A wrapper is just a tool that is *only* this: `sudo` has no rules,
        it only hands off. Declaring it here rather than in a table beside the
        registry keeps a tool's option knowledge with the tool, and means
        judging the outer command never hides the inner one — both are judged,
        strongest verdict wins.

    `known_env`
        The same closed world for `FOO=bar` assignments written before the
        command. An unlisted assignment leaves a gated invocation unproven, so
        a project whose tool takes none can leave this empty and every
        assignment will prompt. Unused when the tool is not gated — a tool that
        is safe by default gates assignments through `Rule.env` instead.

    `value_flags`
        Flags that consume the following token — the tool's arity, which the
        parser cannot guess. Declaring `-i` is what makes `ansible-playbook
        deploy.yml -i --syntax-check` read as "inventory is the string
        --syntax-check", still a real deploy; undeclared, `--syntax-check`
        would look operative and the deploy would pass as a parse-only run. It
        also puts the value within reach of `Grant.flag_values`. Under-
        declaring is unsafe; over-declaring merely swallows an operand, so
        declare every value-taking flag you list in `known_flags`.

    `global_value_opts` / `global_bare_opts`
        Options accepted *before* the subcommand, stripped so that the
        subcommand path lands where `Rule.path` and `Grant.path` expect it.
        Undeclared, `git -C dir push` parses to operands ("dir", "push"), no
        rule for ("push",) matches, and the push goes ungated. `_value_` opts
        consume the next token (`-C dir`, or `--git-dir=x` in one token);
        `_bare_` opts stand alone (`--no-pager`). What separates these from
        `value_flags` is position: they are recognized only ahead of the
        subcommand, and never gate anything themselves.
    """

    name: str  # basename to match, e.g. "git" or "ansible-playbook"
    aliases: frozenset[str] = frozenset()  # other names for the same thing
    nested: tuple[Nested, ...] = ()  # where it hands off to another command
    rules: tuple[Rule, ...] = ()
    # Declaring grants makes the tool gated: dangerous unless a grant holds.
    grants: tuple[Grant, ...] | None = None
    gated_verdict: str | None = None  # verdict when nothing matched; see below
    gated_reason: str = ""  # shown in the prompt; say how to satisfy a grant
    known_flags: frozenset[str] = frozenset()  # closed world, gated tools only
    known_env: frozenset[str] = frozenset()  # closed world for assignments
    value_flags: frozenset[str] = frozenset()  # flags consuming the next token
    global_value_opts: frozenset[str] = frozenset()  # before the subcommand, take a value
    global_bare_opts: frozenset[str] = frozenset()  # before the subcommand, stand alone


@dataclass(frozen=True)
class Invocation:
    words: tuple[str, ...] = ()  # operands in order; subcommand path first
    flags: dict[str, str | None] = field(default_factory=dict)
    env: dict[str, str] = field(default_factory=dict)  # leading FOO=bar
    globals_seen: frozenset[str] = frozenset()  # stripped from before the subcommand
    malformed: bool = False  # a value flag with nothing after it


def registry(*tools: Tool) -> dict[str, Tool]:
    """Index tools by every name they answer to, over the shell wrappers.

    A project entry with the same name as a wrapper replaces it, so a tool that
    both gates and hands off must declare its own `nested` — the selftest
    checks for that rather than leaving it to be discovered.
    """
    indexed: dict[str, Tool] = {}
    for tool in (*SHELL_WRAPPERS, *tools):
        for name in (tool.name, *tool.aliases):
            indexed[name] = tool
    return indexed


MAX_NESTED_PATH = 3  # `docker compose run`


def strip_heredocs(command: str) -> str:
    """Drop heredoc bodies, which are data — a commit message quoting a gated
    command is not that command. A body fed to a *shell* stays: there the text
    really is what runs.

    A body fed to another language is dropped like any other data, on the same
    reasoning that leaves `python3 -c` alone (WHAT THIS DOES NOT SEE): reading
    Python as shell is guesswork, and it guesses wrong in the direction that
    costs a refusal — a backtick inside a Python string is not a command
    substitution, and a docstring naming a gated command is not that command.

    A kept body is only reachable because newlines separate commands: it lands
    as its own segment and is judged like any other. Without that it would
    merge into the surrounding argv and nothing could read it, so the two
    behaviours are coupled — do not weaken one without checking the other.
    """
    for match in HEREDOC.finditer(command):
        before = command[: match.start()]
        interpreter = None
        for found in INTERPRETER.finditer(before):
            interpreter = found.group(0)
        if interpreter and interpreter in SHELL_RUNNERS:
            return command
    kept: list[str] = []
    delimiter: str | None = None
    for line in command.splitlines():
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        kept.append(line)
        close = HEREDOC.search(line)
        if close:
            delimiter = close.group(1)
    return "\n".join(kept)


def strip_redirections(command: str) -> str:
    """Drop shell redirections, which are punctuation and not operands.

    The lexer hands `2>&1` back as the three tokens `2`, `>&`, `1`, and the
    two bare words then sit in argv looking exactly like operands — where
    `commit_span` reads the first as a pathspec and a grant's closed world sees
    operands nobody passed. Removing them here fixes it for every reader of an
    argv rather than for `commit_span` alone.
    See docs/boundary.md#which-repository-and-which-span.

    Done on the raw string, before the lexer, because the lexer has already
    thrown away the one thing that decides an fd digit: adjacency. `2> f`
    redirects fd 2 and `2 > f` passes `2` as an operand, and after tokenizing
    the two are the same three tokens. So digits are dropped only when they
    are a *whole* word — `echo2>x` runs `echo2`, as the shell does.

    Two things are deliberately left where they are, because the cost of
    removing them is a gated command nobody judges:

    - `<(…)` and `>(…)` run a command, and `split_substitutions` finds it by
      the `<(` token this would otherwise eat. Only the operator is skipped;
      what is inside is still scanned.
    - a target holding `$(…)` or a backtick is read off the raw line by
      `embedded_commands`, which never sees this output — so dropping the
      word here costs nothing there.

    The direction of a mistake is the usual one: a token wrongly kept is an
    operand too many, which widens a span and refuses; a token wrongly
    dropped could narrow one. That is why the operator set below is spelled
    out rather than matched as a run of `<>&`, which would swallow `&&`.
    """
    kept: list[str] = []
    index, end = 0, len(command)
    while index < end:
        char = command[index]
        if char == "\\" and index + 1 < end:  # an escaped `>` is a literal one
            kept.append(command[index : index + 2])
            index += 2
            continue
        if char in "'\"":
            close = command.find(char, index + 1)
            if close == -1:  # unbalanced: the lexer will refuse it, so leave it
                kept.append(command[index:])
                return "".join(kept)
            kept.append(command[index : close + 1])
            index = close + 1
            continue
        found = REDIRECTION.match(command, index)
        if not found:
            kept.append(char)
            index += 1
            continue
        if command[found.end() : found.end() + 1] == "(":  # process substitution
            kept.append(found.group())
            index = found.end()
            continue
        if not found.group().startswith("&"):
            text = "".join(kept)
            digits = text[len(text.rstrip(DIGITS)) :]
            if digits and (not text[: -len(digits)] or text[-len(digits) - 1] in WORD_BREAK):
                del kept[-len(digits) :]  # an fd, not the tail of a word
        index = found.end()
        while index < end and command[index] in " \t":
            index += 1
        index = word_end(command, index)
        kept.append(" ")
    return "".join(kept)


def word_end(command: str, index: int) -> int:
    """Past the shell word starting at `index`: the target of a redirection."""
    end = len(command)
    while index < end:
        char = command[index]
        if char == "\\" and index + 1 < end:
            index += 2
        elif char in "'\"":
            close = command.find(char, index + 1)
            index = end if close == -1 else close + 1
        elif char in WORD_BREAK:
            break
        else:
            index += 1
    return index


def split_commands(command: str) -> list[list[str]] | None:
    """Quote-aware split into per-subcommand argv lists. None means the line
    could not be parsed — callers must treat that as unproven, never as safe.

    Newline is made punctuation rather than whitespace so that an unquoted one
    ends a command while one inside quotes stays part of its token: a multiline
    commit message is a single argument, not two commands.
    """
    lexer = shlex.shlex(
        strip_redirections(CONTINUATION.sub(" ", command)),
        posix=True,
        punctuation_chars="();<>|&\n",
    )
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:  # unbalanced quotes
        return None
    commands: list[list[str]] = [[]]
    for token in tokens:
        if token and set(token) <= SEPARATOR_CHARS:
            commands.append([])
        else:
            commands[-1].append(token)
    return [c for c in commands if c]


def skip_own_args(argv: list[str], index: int, nested: Nested) -> int:
    """Step over a tool's own options and operands to reach what it runs."""
    while index < len(argv):  # its own options, which come first
        token = argv[index]
        if not token.startswith("-") or token == "-":
            break
        name = token.partition("=")[0]
        index += 2 if name in nested.value_opts and "=" not in token else 1

    for _ in range(nested.operands):  # then the operands it keeps for itself
        if index >= len(argv):
            break
        index += 1

    # Whatever is left is the command's, flags included: in `docker run img ls
    # -la` the `-la` is ls's, not docker's.
    return index


def shell_payload(args: list[str]) -> str | None:
    """The string a shell was asked to run: the operand after a `-c`-ish flag."""
    for index, token in enumerate(args):
        if DASH_C.match(token):
            return args[index + 1] if index + 1 < len(args) else None
    return None


def names_a_tool(argv: list[str], tools: dict[str, Tool]) -> bool:
    return any(PurePosixPath(token).name in tools for token in argv)


def split_substitutions(argv: list[str]) -> list[list[str]]:
    """Break a segment where a parenthesis opens or closes a command.

    `$(…)`, `<(…)` and a bare `(…)` subshell all run a command, and the lexer
    has already given us the parentheses as their own tokens — which also
    proves they were unquoted. So this is parsing, not guesswork: the enclosed
    words are walked like any other command, and `$(git rev-parse HEAD)` stays
    silent on its own merits rather than by exception.
    """
    pieces: list[list[str]] = [[]]
    for token in argv:
        # The lexer groups a run of punctuation into one token, so the opener
        # arrives as `(` after a separate `$`, but as `<(` in one piece.
        punctuation = bool(token) and set(token) <= PUNCTUATION_CHARS
        if punctuation and ("(" in token or ")" in token):
            if pieces[-1] and pieces[-1][-1] == "$":
                pieces[-1].pop()  # the marker, not an operand of what precedes
            pieces.append([])
        else:
            pieces[-1].append(token)
    return [piece for piece in pieces if piece]


def embedded_commands(command: str) -> list[str]:
    """Command lines hidden inside a single token: `-m "$(git push --force)"`.

    A quoted substitution survives tokenizing as one word, so `split_commands`
    never sees the parentheses and the command inside is never judged. That is
    a shape Claude reaches for constantly — a commit message built from
    `$(cat …)` — so it cannot be left unexamined.

    Read off the raw line rather than the tokens, tracking single quotes as it
    goes. Tokens are the wrong instrument twice over: posix tokenizing has
    already discarded which quote was used — and the difference decides
    everything, since the shell runs `"$(…)"` and does not run `'$(…)'` — while
    a backticked command containing a space is split across two tokens, so no
    token ever holds a complete pair.

    Parentheses are counted, so `$(a $(b))` yields the outer text and the
    recursion finds the inner one.

    A backslash escapes what follows, everywhere single quotes have not
    already made it literal — which is `word_end`'s rule. An escaped backtick
    or dollar opens nothing: the shell runs no command there, and escaping a
    backtick is the correct spelling inside double quotes, so reading one as a
    substitution refuses the careful line and lets its careless twin past.
    See docs/boundary.md#which-repository-and-which-span.
    """
    found: list[str] = []
    index, end, in_single = 0, len(command), False
    while index < end:
        char = command[index]
        if in_single:
            in_single = char != "'"
            index += 1
        elif char == "\\" and index + 1 < end:
            index += 2
        elif char == "'":
            in_single = True
            index += 1
        elif char == "`":
            close = command.find("`", index + 1)
            if close == -1:
                break
            found.append(command[index + 1 : close])
            index = close + 1
        elif command.startswith("$(", index):
            depth, scan = 1, index + 2
            while scan < end and depth:
                depth += (command[scan] == "(") - (command[scan] == ")")
                scan += 1
            if depth:
                break  # unbalanced; the line will not parse anyway
            found.append(command[index + 2 : scan - 1])
            index = scan
        else:
            index += 1
    return [inner for inner in found if inner.strip()]


def nested_at(tool: Tool, argv: list[str], index: int) -> tuple[Nested | None, int]:
    """The tool's longest handoff whose subcommand path starts at `index`.

    `index` is just past the tool's own name, so these are its subcommands:
    `docker` hands off at `run`, and at `compose run`, but not at `build`.
    """
    words = argv[index : index + MAX_NESTED_PATH]
    for nested in sorted(tool.nested, key=lambda n: len(n.path), reverse=True):
        if tuple(words[: len(nested.path)]) == nested.path:
            return nested, len(nested.path)
    return None, 0


def segment_verdicts(
    argv: list[str], tools: dict[str, Tool], depth: int = 0
) -> list[tuple[str, str]]:
    """Every verdict earned by one segment.

    A segment can hold more than one command position, because a wrapper runs
    something else: `sudo git push --force` is both a sudo and a git push. The
    walk records the wrapper's own verdict if it is registered, then keeps going
    to the command it wraps, so gating the wrapper never hides the wrapped
    command. Assignments seen along the way bind to whatever runs next.
    """
    verdicts: list[tuple[str, str]] = []
    env: dict[str, str] = {}
    index = 0
    wrapped = False  # we stepped over a wrapper, so something is being run

    while index < len(argv):
        # Syntax first, then assignments: `{ FOO=1 git push` is both, and a
        # keyword can precede an assignment as easily as follow it.
        while index < len(argv) and argv[index] in SHELL_KEYWORDS:
            index += 1
        while index < len(argv) and ASSIGNMENT.match(argv[index]):
            key, _, value = argv[index].partition("=")
            env[key.rstrip("+")] = value
            index += 1
        if index >= len(argv):
            break

        name = PurePosixPath(argv[index]).name
        tool = tools.get(name)
        if tool is not None:
            # Where this tool's own arguments end. Everything past a handoff
            # belongs to what it runs, and must not be read as the tool's own:
            # the `--syntax-check` in `docker run img ansible-playbook
            # --syntax-check x` is ansible's, and must not satisfy a grant on
            # docker.
            nested, words = nested_at(tool, argv, index + 1)
            handoff = (
                skip_own_args(argv, index + 1 + words, nested) if nested is not None else len(argv)
            )
            verdict = judge(tool, parse(tool, argv[index + 1 : handoff], env))
            if verdict:
                verdicts.append(verdict)

            if nested is None:
                return verdicts
            index = handoff
            wrapped = True
            continue

        if depth < MAX_DEPTH:
            payload = None
            if name in SHELL_RUNNERS:
                payload = shell_payload(argv[index + 1 :])
            elif name in EVAL_RUNNERS and index + 1 < len(argv):
                payload = " ".join(argv[index + 1 :])
            if payload is not None:
                verdict = decide_bash(payload, tools, depth + 1)
                if verdict:
                    verdicts.append(verdict)
                return verdicts
        if name in SCRIPT_RUNNERS and index + 1 < len(argv):
            script = tools.get(PurePosixPath(argv[index + 1]).name)
            if script is not None:
                verdict = judge(script, parse(script, argv[index + 2 :], env))
                if verdict:
                    verdicts.append(verdict)
            return verdicts

        # Nothing recognised in command position. Inside a wrapper that is
        # enough to ask: we stepped over something whose job is to run a
        # command, so one *is* being run and we lost it — most likely to an
        # option we do not know takes a value. The prompt is also how an
        # unlisted wrapper announces itself for adding to SHELL_WRAPPERS.
        #
        # Outside a wrapper this must not fire. The test below asks whether a
        # registered name appears *anywhere* in the rest, and a tool's name is
        # also an ordinary word and an ordinary directory; narrowing does not
        # help, because the signal is absent rather than weak. Unknown runners
        # are covered by listing them in SHELL_WRAPPERS, which is why that
        # list is generous.
        # see docs/boundary.md#the-guard-reads-parsed-argv
        if wrapped and names_a_tool(argv[index:], tools):
            verdicts.append(("ask", "a command this guard cannot identify is running a gated tool"))
        return verdicts
    return verdicts


def parse(tool: Tool, args: list[str], env: dict[str, str]) -> Invocation:
    """Split args into a subcommand path plus operands, and flags with values."""
    index = 0
    seen: set[str] = set()  # remembered: an allow rule cares which were used
    while index < len(args):  # global options sit before the subcommand
        name = args[index].partition("=")[0]
        if name in tool.global_value_opts:
            seen.add(name)
            index += 1 if "=" in args[index] else 2
        elif name in tool.global_bare_opts:
            seen.add(name)
            index += 1
        else:
            break

    words: list[str] = []
    flags: dict[str, str | None] = {}
    awaiting: str | None = None
    literal = False
    for token in args[index:]:
        if awaiting is not None:
            flags[awaiting] = token
            awaiting = None
        elif literal or not token.startswith("-") or token == "-":
            words.append(token)
        elif token == "--":
            flags["--"] = None
            literal = True
        else:
            name, separator, value = token.partition("=")
            if separator:
                flags[name] = value
            elif name in tool.value_flags:
                awaiting = name
            else:
                flags[name] = None
    return Invocation(tuple(words), flags, env, frozenset(seen), awaiting is not None)


class AnyOf:
    """Wraps an operand matcher to mean *at least one*, not *every*.

    The quantifier cannot live in the matcher — a matcher sees one value at a
    time — so it is carried here and unwrapped where operands are compared.
    Use it where the deciding token can sit anywhere among the operands, as a
    verb does in `openstack server list`: the position varies with the noun,
    and `security group rule list` puts it fourth.
    """

    __slots__ = ("matcher",)

    def __init__(self, matcher: Matcher) -> None:
        self.matcher = matcher


def any_of(matcher: Matcher) -> AnyOf:
    """`operands=any_of(READ_VERBS)`: one operand matching is enough."""
    return AnyOf(matcher)


def matches(matcher: Matcher, value: str) -> bool:
    if isinstance(matcher, re.Pattern):
        return matcher.match(value) is not None
    return bool(matcher(value))


def operands_match(matcher, operands: list[str]) -> bool:
    """Compare operands against a matcher, honouring `any_of`.

    Empty operands never match: a matcher on operands is a statement about
    what the command acts on, and a command acting on nothing has not proven
    it.
    """
    quantify = any if isinstance(matcher, AnyOf) else all
    matcher = matcher.matcher if isinstance(matcher, AnyOf) else matcher
    return bool(operands) and quantify(matches(matcher, o) for o in operands)


# DIVERGES FROM THE TEMPLATE, for portability. `under()` upstream calls
# `PurePosixPath.full_match`, which arrived in Python 3.13; this image's python
# is whatever the Debian base ships, and the call raises AttributeError there.
# The backport stays, and a refresh re-applies it rather than waiting for it.
# see docs/boundary.md#the-guards-divergences-from-the-template
#
# `*` and `?` stop at a separator, `**` crosses them, and `**/` may match
# nothing at all — pathlib's semantics, not fnmatch's, which is why
# fnmatch.translate is not what is used here.
def glob_regex(pattern: str) -> re.Pattern[str]:
    out: list[str] = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def under(*locations: str | re.Pattern[str]) -> Callable[[str], bool]:
    """Match a value that is a path at, or inside, any of `locations`.

    Each location may be:

    * a directory — `"/tmp"` matches it and everything below it;
    * a glob — `"/home/*/scratch"`, where `*` does not cross a `/`, so
      `/home/user/scratch` matches and `/home/a/b/scratch` does not;
    * a compiled regex, matched against the whole resolved path.

    Use this for any value that is a path, rather than matching the raw string.
    `^/tmp/` as a plain `Matcher` regex says yes to `/tmp/../etc/passwd`: the
    string starts with the prefix while the path does not live under it. That
    makes a grant hold where it should not, which is the one direction a grant
    must never fail in.

    The value is resolved *before* matching, whichever form is used — so a
    regex passed here is safe where the same regex used directly as a `Matcher`
    would not be. `..` is resolved textually and `~` is expanded. Symlinks are
    not followed: that would mean touching the filesystem from inside a hook,
    on a path that may not exist yet. A relative path resolves against nothing
    and so matches no absolute location — it asks, the safe direction.
    """

    def matcher(value: str) -> bool:
        resolved = os.path.normpath(os.path.expanduser(value))
        for location in locations:
            if isinstance(location, re.Pattern):
                if location.match(resolved):
                    return True
            elif GLOB_CHARS & set(location):
                stem = location.rstrip("/")
                if glob_regex(stem).match(resolved) or glob_regex(f"{stem}/**").match(resolved):
                    return True
            else:
                root = os.path.normpath(location)
                if resolved == root or resolved.startswith(root.rstrip("/") + "/"):
                    return True
        return False

    return matcher


def grant_holds(grant: Grant, invocation: Invocation) -> bool:
    if invocation.words[: len(grant.path)] != grant.path:
        return False
    if grant.require_any and not (grant.require_any & invocation.flags.keys()):
        return False
    for flag, matcher in grant.flag_values:
        value = invocation.flags.get(flag)
        if value is None or not matches(matcher, value):
            return False
    for name, matcher in grant.env_values:
        value = invocation.env.get(name)
        if value is None or not matches(matcher, value):
            return False
    operands = invocation.words[len(grant.path) :]
    if not grant.allow_operands and operands:
        return False
    if grant.operands is not None:
        return operands_match(grant.operands, list(operands))
    return True


def is_granted(tool: Tool, invocation: Invocation) -> bool:
    if invocation.malformed:
        return False
    if not invocation.flags.keys() <= tool.known_flags:
        return False  # an unaccounted flag: unproven
    if not invocation.env.keys() <= tool.known_env:
        return False  # an unaccounted assignment: likewise
    values = [v for v in invocation.flags.values() if v is not None]
    values += list(invocation.env.values())
    if not all(VALUE_OK.match(v) for v in [*values, *invocation.words]):
        return False
    held = False
    for grant in tool.grants or ():
        if grant_holds(grant, invocation):
            if AUDIT is not None:  # the selftest is checking which grants hold
                AUDIT.add(grant)
            held = True
    return held


def matching_rules(tool: Tool, invocation: Invocation) -> list[Rule]:
    """Every rule this invocation satisfies. Conditions are ANDed."""
    matched = []
    for rule in tool.rules:
        if invocation.words[: len(rule.path)] != rule.path:
            continue
        if rule.flags is not None and not (rule.flags & invocation.flags.keys()):
            continue
        if rule.env is not None and not (rule.env & invocation.env.keys()):
            continue
        if rule.operands is not None and not operands_match(
            rule.operands, list(invocation.words[len(rule.path) :])
        ):
            continue
        matched.append(rule)
    return matched


def cited(tool: Tool, rule: Rule | None, invocation: Invocation) -> str:
    """Name what decided, so a wrong verdict can be traced to a line of registry.

    A reason says why the guard objects; this says *what it read* to get there
    — the tool, the subcommand path, and the flag, assignment or operand that
    matched. Without it a false positive is a sentence with nothing to grep
    for, and the only way to find the rule is to read them all.
    """
    subject = " ".join((tool.name, *invocation.words[:3])).strip()
    if rule is None:
        return f"[{subject}: no proven-safe shape]"
    hits: list[str] = []
    if rule.flags:
        hits += sorted(rule.flags & invocation.flags.keys())
    if rule.env:
        hits += sorted(rule.env & invocation.env.keys())
    if rule.operands is not None:
        operands = list(invocation.words[len(rule.path) :])
        matcher = rule.operands.matcher if isinstance(rule.operands, AnyOf) else rule.operands
        hits += [o for o in operands if matches(matcher, o)]
    where = " ".join(("rule", tool.name, *rule.path)).strip()
    return f"[{where}{': ' + ', '.join(hits) if hits else ''}]"


def judge(tool: Tool, invocation: Invocation) -> tuple[str, str] | None:
    """Strongest verdict for one invocation: deny, then ask, then allow.

    Order-free within each rank, so a table cannot be broken by reordering it.
    An allow ranks last on purpose — anything with an opinion outranks a grant.
    """
    verdicts: list[tuple[str, str]] = []
    for rule in matching_rules(tool, invocation):
        if AUDIT is not None:  # the selftest is checking which rules can fire
            AUDIT.add(rule)
        if rule.verdict == "allow" and not (invocation.globals_seen <= rule.allow_globals):
            continue  # a global we have not accounted for: no grant
        verdicts.append((rule.verdict, f"{rule.reason} {cited(tool, rule, invocation)}"))
    # The verdict for an invocation nothing matched. Set explicitly, it holds
    # whether or not the tool declares grants — which is how "everything here
    # is the operator's" is said without inventing an empty grant list.
    # Unset, it derives: silent for a tool with no grants, ask for one that
    # has them and was not granted.
    gated = tool.gated_verdict or ("ask" if tool.grants is not None else None)
    if gated is not None and (tool.grants is None or not is_granted(tool, invocation)):
        verdicts.append((gated, f"{tool.gated_reason} {cited(tool, None, invocation)}"))
    for rank in ("deny", "ask", "allow"):
        for verdict in verdicts:
            if verdict[0] == rank:
                return verdict
    return None


def decide_bash(command: str, tools: dict[str, Tool], depth: int = 0) -> tuple[str, str] | None:
    line = strip_heredocs(command)
    commands = split_commands(line)
    if commands is None:
        mentioned = any(re.search(rf"(?<![\w.-]){re.escape(n)}\b", line) for n in tools)
        if mentioned:
            return "ask", "this line could not be parsed, so nothing about it is proven"
        return None

    asked: tuple[str, str] | None = None
    allowed: tuple[str, str] | None = None
    for argv in commands:
        for piece in split_substitutions(argv):
            for verdict in segment_verdicts(piece, tools, depth):
                if verdict[0] == "deny":
                    return verdict
                if verdict[0] == "allow":
                    allowed = allowed or verdict
                else:
                    asked = asked or verdict

    # A substitution that was quoted never reached the splitting above: it is
    # still sitting inside one token. Judge those command lines too.
    if depth < MAX_DEPTH:
        for inner in embedded_commands(line):
            nested = decide_bash(inner, tools, depth + 1)
            if nested is None:
                continue
            if nested[0] == "deny":
                return nested
            if nested[0] != "allow":
                asked = asked or nested

    # An ask anywhere in the line withholds a grant made elsewhere in it: the
    # grant speaks for one command, never for its neighbours.
    if asked or allowed is None:
        return asked

    # A grant is only *used* where it is needed. Without a substitution the
    # line would reach the permission rules unaided, and granting it would
    # waive the working-directory sandbox for nothing. This is the textual test
    # again, and correctly so: the question is whether Claude Code's own
    # textual heuristic will fire, not what the command does.
    return allowed if SUBSTITUTION.search(line) else None


# =========================== REGISTRY ======================================
# The project-specific part. This is the only section to edit — and no rule
# here changes without the operator's agreement. See CHANGING THE RULES.
#
# Pair every rule- or grant-bearing tool here with a broad allow in
# settings.json — never the SHELL_WRAPPERS below, whose names get no allow
# lines — and never with an `ask` rule — see WHAT MUST LAND IN settings.json
# in the module docstring.
#
# Tools a project adds go after GIT. For the shape of a gated entry — grants,
# known_flags, value_flags, and how a rule ranks against a grant — read the
# `stubtool` fixture near the selftest. It is a test fixture rather than a
# config to copy verbatim, but every field is exercised there, and CHOOSING A
# RULE KIND in the module docstring says which kind a tool wants.

# --- shell wrappers: programs whose only job is to run another program ------
# Tools with no rules and no grants — nothing to say about themselves,
# everything to say about what comes next. They come first because everything
# below is judged through them: `sudo git push --force` is a git push.
#
# Unlike the tools that follow, this list is not project policy — how a shell
# hides a command is the same everywhere — so it is the one part of the
# registry that usually travels between projects unchanged. Add to it when a
# project uses a runner that is not here; a missing entry is a silent hole,
# while an entry for a program you never run costs nothing.
SHELL_WRAPPERS: tuple[Tool, ...] = (
    Tool(
        "sudo",
        nested=(Nested(value_opts=frozenset({"-u", "--user", "-g", "--group", "-p", "--prompt"})),),
    ),
    Tool("doas", nested=(Nested(value_opts=frozenset({"-u", "-C"})),)),
    Tool(
        "env",
        nested=(
            Nested(
                value_opts=frozenset({"-u", "--unset", "-C", "--chdir", "-S", "--split-string"})
            ),
        ),
    ),
    Tool("command", nested=(Nested(),)),
    Tool("builtin", nested=(Nested(),)),
    Tool("exec", nested=(Nested(value_opts=frozenset({"-a"})),)),
    Tool("nohup", nested=(Nested(),)),
    Tool("setsid", nested=(Nested(),)),
    Tool("time", nested=(Nested(value_opts=frozenset({"-f", "--format", "-o", "--output"})),)),
    Tool("nice", nested=(Nested(value_opts=frozenset({"-n", "--adjustment"})),)),
    Tool("ionice", nested=(Nested(value_opts=frozenset({"-c", "-n", "-p"})),)),
    Tool(
        "stdbuf",
        nested=(
            Nested(value_opts=frozenset({"-i", "-o", "-e", "--input", "--output", "--error"})),
        ),
    ),
    Tool(
        "timeout",
        nested=(
            Nested(value_opts=frozenset({"-s", "--signal", "-k", "--kill-after"}), operands=1),
        ),
    ),
    Tool("chrt", nested=(Nested(value_opts=frozenset({"-p"}), operands=1),)),
    Tool("taskset", nested=(Nested(value_opts=frozenset({"-c", "-p"}), operands=1),)),
    Tool(
        "flock",
        nested=(
            Nested(
                value_opts=frozenset({"-w", "--wait", "-E", "--conflict-exit-code"}), operands=1
            ),
        ),
    ),
    Tool(
        "xargs",
        nested=(
            Nested(
                value_opts=frozenset(
                    {
                        "-n",
                        "-P",
                        "-I",
                        "-d",
                        "-E",
                        "-L",
                        "-s",
                        "--max-args",
                        "--max-procs",
                        "--replace",
                        "--delimiter",
                        "--max-lines",
                    }
                )
            ),
        ),
    ),
)


# --- git: one grant, and nothing denied ------------------------------------
# Force-push and history rewrite are not gated from here. That says which acts
# this file no longer gates, and nothing about whether the agent performs them
# — write *the enforcement was withdrawn*, never *the agent is authorized*.
# see docs/boundary.md#the-withdrawal-of-2026-09-01
#
# The one `allow` is not a leftover: without it a commit whose message embeds a
# substitution simply fails unattended. A different job, not a weaker boundary.
#
# COMMIT_PATH below is the other reader of git — "would this line commit or
# push?", so the secret check can read what it would carry. A separate
# registry: deleting a rule here does not touch it; deleting the file does.
#
# The template's asks — plain `push`, `clean`, `restore`, `checkout --`,
# `stash drop`, `branch -d`, the worktree pair — are absent as they always were.
# They guard uncommitted or local work, and under `-p` each would become a hard
# refusal. An `ask` on plain `push` would deny the agent the push that backs its
# memory up, which is the loop this whole container exists to keep running.

GIT = Tool(
    name="git",
    global_value_opts=frozenset(
        {"-C", "--git-dir", "--work-tree", "-c", "--exec-path", "--namespace"}
    ),
    global_bare_opts=frozenset({"--no-pager", "--paginate", "--bare", "--no-replace-objects"}),
    rules=(
        # Safe for this shape only: whatever the substitution expands to
        # becomes a commit message, and a message cannot direct a write.
        # `allow_globals` is empty, so `git -C /elsewhere commit -m …` and
        # `git --exec-path=/tmp/x commit -m …` are not granted.
        Rule(
            "allow",
            ("commit",),
            "a commit message cannot direct a write",
            flags=frozenset({"-m", "--message"}),
        ),
    ),
)

# --- bws: denied whole, so that /usr/local/bin/vault is the only route -----
# Not because reading the vault is dangerous — the agent is meant to read it —
# but because `bws secret get` puts the value in a variable and in no file, and
# the secret comparison below reads files. Every fetch through `vault` lands in
# ~/.cache/vault first, which is what makes rule 10 cover the vault at all.
#
# gated_verdict rather than rules: no spelling of `bws` should reach the tool,
# so there is no path worth enumerating. `Bash(bws:*)` in the managed deny list
# is what holds if this guard dies, and this act is the guard's witness in
# CASES and in `just verify`.
#
# Not a wall: the access token is in the session's own environment, so a
# hand-rolled request against the Bitwarden API bypasses this and the cache
# both. It makes the covered route the obvious one and the uncovered route a
# deliberate detour.
# see docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose
BWS = Tool(
    name="bws",
    gated_verdict="deny",
    gated_reason=(
        "the vault is reached through `vault`, not `bws` — a fetch through it "
        "is cached where the secret check can see it, and a fetch around it is "
        "not (`vault list`, `vault get <key>`)"
    ),
)

# --- gh: the generic API door, gated on what turns a read into a write -----
# The endpoint is free to read; what would write is gated here.
# see docs/boundary.md#gh-api-opened-for-reads
#
# Wider than `--method`, because gh's own help says "adding request parameters
# will automatically switch the request method to POST": `gh api
# repos/o/r/issues -f body=hi` posts with no `--method` anywhere. A gate
# reading only `--method` catches the spelling nobody writes.
#
# It fires on presence, not value — `Rule.flags` cannot test one — so
# `--method GET` asks as well. The read that costs has a spelling that does not
# ask, while approximating a value test means guessing at parse time.
#
# `ask` and not `deny`: a write here has an authorized use, since the operator
# is in the room during `just chat`. Unattended it degrades to a refusal.
#
# No `value_flags`, deliberately: declaring them lets a token be swallowed as
# another flag's value, which here could only hide one of the flags this gates.
#
# Nothing backs this up, nor could anything: a permission pattern matches from
# the start of the line and the endpoint always comes first, so no
# `Bash(gh api …)` entry can see a flag that sits after it. If the guard dies,
# `gh api` writes run — ruled acceptable rather than overlooked.
#
# One inconsistency, named rather than hidden: `gh repo delete` is denied
# outright here, and the same act spelled `gh api --method DELETE repos/o/r`
# asks. Closing that needs a value test the rule kind cannot express.
AUTH_STORE = (
    "rule: the login is the operator's to give and the agent's to use, never to change "
    "— `gh auth login --with-token` is the one that is open"
)

GH = Tool(
    name="gh",
    rules=(
        # `gh auth login` is deliberately absent: it is what lets the agent
        # authenticate with a token out of the vault. Denied is everything that
        # would read the credential back out, destroy it, or point git at a
        # different one.
        #
        # `gh auth status` is refused nowhere: the managed allow is
        # `Bash(gh:*)`, the deny list carries no gh entry, and the rules here
        # are the whole of what gh is refused — the verbs that read the login
        # back out, destroy it or repoint git, and `repo delete`.
        # see docs/boundary.md#the-guard-reads-parsed-argv
        Rule(
            "deny",
            ("auth", "token"),
            "this prints the credential itself, which is the one thing a "
            "session must not be able to read back",
        ),
        Rule("deny", ("auth", "logout"), AUTH_STORE),
        Rule("deny", ("auth", "switch"), AUTH_STORE),
        Rule("deny", ("auth", "refresh"), AUTH_STORE),
        Rule(
            "deny",
            ("auth", "setup-git"),
            "this rewrites git's credential helper, which decides what every "
            "later push authenticates as",
        ),
        Rule("deny", ("repo", "delete"), "this destroys the repository"),
        Rule(
            "ask",
            ("api",),
            "gh api with parameters, a body or a method is a write to GitHub — "
            "a read needs none of them",
            flags=frozenset({"--method", "-X", "-f", "--raw-field", "-F", "--field", "--input"}),
        ),
    ),
)

# Docker is deliberately not in this registry: there is no docker binary and no
# socket in this container, so its rules could never fire. If one is ever added
# to the image, take the tool back from the template rather than writing it.

TOOLS: dict[str, Tool] = registry(GIT, GH, BWS)


# =========================== SECRETS =======================================
# The agent's own standing rule is that a secret never enters its repository.
# This is what enforces it.
# see docs/boundary.md#what-a-commit-or-a-push-would-carry
#
# Here and not in a git hook: a hook is found through core.hooksPath, and the
# local .git/config that outranks the system one sits inside the agent's own
# checkout — one `git config` and the hook is gone, with no symptom. This runs
# from the image and cannot be unset from inside, which also makes
# `--no-verify` moot: there are no git hooks to skip.
#
# The commit path and not everything, because every other mistake is fixed in
# the next commit. A secret in history is remediated by rewriting history, and
# a rewrite does not reach the forge's own copies — the one failure class with
# no cleanup at all.
#
# What it does not cover, so silence is not read as coverage: an interpreter.
# `python3 -c` committing through subprocess is program text in another
# language and no argv guard reads it. And it sees commits and pushes, not
# what the agent writes into an issue, a discussion or a forum post.

MIN_SECRET = 24  # shorter than this is not a credential, and collides
# Past this, what a commit carries is not read — and so is refused, never
# waved through. A truncation here would bound nothing and hide something.
# see docs/boundary.md#what-a-commit-or-a-push-would-carry
MAX_SCAN = 4_000_000
# Under the hook's own 10s timeout in the managed settings. Over it Claude Code
# kills the guard first, and a killed guard is no verdict at all.
GIT_TIMEOUT = 5

# The engine's own walk, asked a narrower question: a registry that denies
# exactly commit and push answers "would this line commit or push?" through
# wrappers, substitutions and `git -C`, with the parsing that decides
# everything else. A regex over the raw line would call `git log --grep
# commit` a commit, and then refuse it for a secret staged elsewhere.
COMMIT_PATH = registry(
    Tool(
        name="git",
        global_value_opts=GIT.global_value_opts,
        global_bare_opts=GIT.global_bare_opts,
        rules=(
            Rule("deny", ("commit",), "commit"),
            Rule("deny", ("push",), "push"),
            # An annotated tag's message is a third way into history and is in
            # neither of the other two: a tag object is not in `log -p`. Its
            # message arrives in the command line like a commit's, so naming
            # the act here is most of the fix.
            Rule("deny", ("tag",), "tag"),
            # A note's text is a message like the others. Thin — a plain push
            # does not carry refs/notes — but naming the act costs one line
            # and the push half already reads it.
            Rule("deny", ("notes",), "notes"),
        ),
    )
)

# Where a message can come from that is neither the command line nor the
# diff. `-F -` is excluded: that is the heredoc spelling, and its body is in
# the command text already.
MESSAGE_FLAGS = ("-F", "--file")
MESSAGE_SUBCOMMANDS = ("commit", "tag", "notes")


def git_invocation(argv: list[str]) -> tuple[int, int, str] | None:
    """(where git is, where its subcommand is, what it is) — by position.

    Not by "commit appears among the tokens": in `git log --grep commit -F x`
    the word is grep's pattern and the -F is grep's too. Global options are
    stripped from GIT's own declared sets, so the two cannot drift apart.

    The indices matter as much as the name: everything before the subcommand
    is git's own, or a wrapper's, and `-C` means a directory there — while
    after it, on `commit`, the same spelling means reuse this message.
    """
    for index, token in enumerate(argv):
        if PurePosixPath(token).name != "git":
            continue
        step = index + 1
        while step < len(argv):
            token = argv[step]
            if token in GIT.global_value_opts:
                step += 2
            elif token.startswith("-"):
                step += 1  # a bare global, an =-joined one, or an unknown flag
            else:
                return index, step, token
        return None
    return None


def git_subcommand(argv: list[str]) -> str | None:
    found = git_invocation(argv)
    return found[2] if found else None


CD_COMMANDS = ("cd", "pushd")
DIRECTORY_OPTS = ("-C", "--chdir")
# Moved in ways this does not follow. `--git-dir` and `--work-tree` can point
# the repository and the tree at different places, and guessing which to read
# would be a third answer nobody asked for. Unproven is the honest one.
OPAQUE_OPTS = ("--git-dir", "--work-tree")
# A target only the shell can work out: a variable, a substitution, a glob.
UNRESOLVED = re.compile(r"[$`*?\[]")
# The same move as --git-dir and --work-tree, spelled as an environment
# assignment, and treated identically — unproven, for the same reason.
GIT_DIR_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR")
ASSIGNMENT_COMMANDS = ("export", "declare", "typeset", "local", "readonly")
# The verbs whose content this scan exists to read. Reaching one ends the
# walk: what decides the tree is where the line stands when the verb runs,
# not where it ends up afterwards.
SCANNED_ACTS = ("commit", "push", "tag", "notes")


def moves_the_repository(token: str) -> bool:
    name, assigned, _ = token.partition("=")
    return bool(assigned) and name in GIT_DIR_VARS


# What a commit would record, and therefore what has to be read. A plain
# `git commit` records the index and nothing else; `-a`, `-i`, `-o`, `-p`
# and a pathspec each reach past it into the tracked working tree.
#
# Reading the wider span for every spelling makes a refusal sticky and
# unrelated: the dirty file stays dirty, so every commit of every other file is
# refused until a file nobody was committing is cleaned.
# see docs/boundary.md#which-repository-and-which-span
#
# The parse is one-sided on purpose. INDEX is claimed only when the whole
# command is understood; an option this does not know, a short cluster with a
# letter not below, a lone `-`, anything at all in doubt keeps WORKTREE. So a
# missing entry costs the wider read, never a shorter one.
INDEX = "index"  # git diff --cached
WORKTREE = "worktree"  # that, and git diff HEAD besides

# Long options of `git commit`, by what they do to the span.
COMMIT_WIDE_OPTS = frozenset(
    {
        "--all",
        "--include",
        "--only",
        "--patch",
        "--interactive",
        "--pathspec-from-file",
    }
)
# These consume the NEXT token when not spelled with `=`. Listing one that
# does not is the single way this parse can read too little: the operand it
# swallows would otherwise have been a pathspec, and a pathspec widens.
# Under-listing is safe in the other direction — an unswallowed value looks
# like a pathspec, which widens. So add only what is certain.
COMMIT_VALUE_OPTS = frozenset(
    {
        "--message",
        "--file",
        "--reedit-message",
        "--reuse-message",
        "--fixup",
        "--squash",
        "--author",
        "--date",
        "--template",
        "--cleanup",
        "--trailer",
    }
)
# `--gpg-sign` and `--untracked-files` are here rather than above because
# their value is optional, which in git's parser means `=`-joined only: they
# never take the next token, and listing them as value options would make
# them swallow a pathspec.
COMMIT_BARE_OPTS = frozenset(
    {
        "--amend",
        "--edit",
        "--no-edit",
        "--reset-author",
        "--signoff",
        "--no-signoff",
        "--verify",
        "--no-verify",
        "--allow-empty",
        "--allow-empty-message",
        "--quiet",
        "--verbose",
        "--dry-run",
        "--status",
        "--no-status",
        "--short",
        "--branch",
        "--no-branch",
        "--porcelain",
        "--long",
        "--null",
        "--gpg-sign",
        "--no-gpg-sign",
        "--untracked-files",
        "--no-post-rewrite",
        "--pathspec-file-nul",
        "--progress",
        "--no-progress",
    }
)
# The same four classes, spelled short and clusterable: `git commit -am x`
# is `-a` and `-m x`, and the `a` in it is why that cluster has to be read
# letter by letter rather than compared whole.
COMMIT_SHORT_WIDE = "aiop"
COMMIT_SHORT_VALUE = "mFcCt"  # the rest of the cluster, or the next token
COMMIT_SHORT_OPTIONAL = "uS"  # the rest of the cluster, and never the next
COMMIT_SHORT_BARE = "esnvqz"
COMMIT_SHORT_KNOWN = COMMIT_SHORT_VALUE + COMMIT_SHORT_OPTIONAL + COMMIT_SHORT_BARE


# Why a span went wide, in the words the refusal uses — a refusal that gives
# the verdict without the token turns the one party it constrains into a search
# over spellings. Two reasons, kept apart: the commit really does record more,
# or this parse did not understand the line and kept the wider span rather than
# guess. This is the only place that knows which applied.
# see docs/boundary.md#what-the-refusals-say
def reaches(token: str) -> str:
    return f"`{token}` reaches past the index into the tracked working tree"


def unrecognised(token: str) -> str:
    return (
        f"`{token}` is not a spelling this parse knows, so the span every "
        f"commit had before it is kept rather than guessed at"
    )


def commit_span(argv: list[str]) -> tuple[str, str]:
    """INDEX or WORKTREE, from the operands after the `commit` subcommand,
    with the token that took it wide — empty when the index is the whole of it.
    """
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--":
            # Everything past it is a pathspec, and nothing past it is not.
            rest = argv[index + 1 :]
            return (WORKTREE, reaches(rest[0])) if rest else (INDEX, "")
        if not token.startswith("-") or token == "-":
            # a pathspec: this commit reaches the worktree
            return WORKTREE, reaches(token)
        if token.startswith("--"):
            name = token.partition("=")[0]
            if name in COMMIT_WIDE_OPTS:
                return WORKTREE, reaches(token)
            if name in COMMIT_VALUE_OPTS:
                index += 1 if "=" in token else 2
                continue
            if name not in COMMIT_BARE_OPTS:
                return WORKTREE, unrecognised(token)
            index += 1
            continue
        step = 1
        while step < len(token):
            letter = token[step]
            # Known to widen, or not known at all — the same answer for
            # two different reasons, and both are reasons to widen. The
            # cluster is named whole, because that is what was typed.
            if letter in COMMIT_SHORT_WIDE:
                return WORKTREE, reaches(token)
            if letter not in COMMIT_SHORT_KNOWN:
                return WORKTREE, unrecognised(token)
            if letter in COMMIT_SHORT_VALUE:
                if step + 1 == len(token):
                    index += 1  # the value is the next token
                break
            if letter in COMMIT_SHORT_OPTIONAL:
                break  # whatever follows in the cluster is its value
            step += 1
        index += 1
    return INDEX, ""


def gated_commands(
    command: str, cwd: str
) -> tuple[list[tuple[str, str, str, str]] | None, str | None]:
    """Which repository each gated verb acts on and what it carries.

    (act, directory, span, why) per verb, or (None, why not). The span is a
    commit's alone; the other acts do not have one and carry "". `why` names
    the token that took the span wide, for the refusal to quote.

    The directory is taken from the invocation and not from the session: git
    acts on the tree the invocation names, and reading the other one is a
    confident wrong answer in both directions at once.

    A `cd` with a literal target is followed; `cd notes && git commit` inside a
    repository is ordinary work and lands on the same tree. Anything that
    cannot be resolved without running a shell is unproven, which refuses.
    See docs/boundary.md#which-repository-and-which-span.
    """
    records: list[tuple[str, str, str, str]] = []
    line = strip_heredocs(command)
    commands = split_commands(line)
    if commands is None:
        return None, "the line could not be parsed"
    directory = cwd
    for argv in commands:
        for whole in split_substitutions(argv):
            start = 0
            while start < len(whole) and whole[start] in SHELL_KEYWORDS:
                start += 1
            # Assignments that lead a command bind to what runs next, and
            # `export GIT_DIR=…` on its own binds to everything after it.
            while start < len(whole) and ASSIGNMENT.match(whole[start]):
                if moves_the_repository(whole[start]):
                    return None, f"`{whole[start].partition('=')[0]}=` retargets git itself"
                start += 1
            piece = whole[start:]
            if not piece:
                continue
            if PurePosixPath(piece[0]).name in ASSIGNMENT_COMMANDS:
                for token in piece[1:]:
                    if moves_the_repository(token):
                        return None, f"`{token.partition('=')[0]}=` retargets git itself"
                continue

            if PurePosixPath(piece[0]).name in CD_COMMANDS:
                targets = [token for token in piece[1:] if not token.startswith("-")]
                if len(targets) != 1:
                    return None, "a `cd` with no single target moves somewhere only a shell knows"
                if targets[0] == "-" or UNRESOLVED.search(targets[0]):
                    return None, f"`cd {targets[0]}` resolves only when a shell runs it"
                directory = os.path.normpath(
                    os.path.join(directory, os.path.expanduser(targets[0]))
                )
                continue

            found = git_invocation(piece)
            if found is None:
                continue
            # `-C` binds to this invocation; `cd` binds to the shell, so the
            # first must not persist into whatever runs next.
            _, subcommand_at, subcommand = found
            here = directory
            step = 0
            while step < subcommand_at:
                base, joined, value = piece[step].partition("=")
                if moves_the_repository(piece[step]):
                    return None, f"`{base}=` retargets git itself"
                if base in OPAQUE_OPTS:
                    return None, f"`{base}` points the repository somewhere this does not follow"
                if base in DIRECTORY_OPTS:
                    if not joined:
                        if step + 1 >= len(piece):
                            return None, f"`{base}` was given nothing to change to"
                        value = piece[step + 1]
                        step += 1
                    if UNRESOLVED.search(value):
                        return None, f"`{base} {value}` resolves only when a shell runs it"
                    here = os.path.normpath(os.path.join(here, os.path.expanduser(value)))
                step += 1

            # Stop at the verb being judged: a segment AFTER it must not
            # decide which tree it was scanned against. Ordering is the whole
            # content of `cd`.
            if subcommand in SCANNED_ACTS:
                # Decided here, where the operands of THIS invocation are:
                # `git commit -m a && git commit -a -m b` is one of each.
                span, why = (
                    commit_span(piece[subcommand_at + 1 :]) if subcommand == "commit" else ("", "")
                )
                records.append((subcommand, here, span, why))
    return records, None


def message_files(command: str, depth: int = 0) -> list[str] | None:
    """Paths a commit or tag would take its message from. None: unparseable.

    Scoped to segments that name git AND the subcommand, so `grep -F foo`
    beside a commit on the same line is not mistaken for a message file —
    over-collecting here is not harmless, because a path that cannot be read
    is treated as unproven.

    The engine's own primitives do the cutting up. What is not reused is its
    walk, which returns verdicts rather than the values of flags; recursing
    into a shell payload is the one part repeated, and it is three lines.
    """
    line = strip_heredocs(command)
    commands = split_commands(line)
    if commands is None:
        return None  # unparseable: the caller refuses
    paths: list[str] = []
    for argv in commands:
        for piece in split_substitutions(argv):
            if not piece:
                continue
            if depth < MAX_DEPTH and PurePosixPath(piece[0]).name in SHELL_RUNNERS:
                inner = shell_payload(piece[1:])
                if inner is not None:
                    found = message_files(inner, depth + 1)
                    if found is None:
                        return None
                    paths += found
            if git_subcommand(piece) not in MESSAGE_SUBCOMMANDS:
                continue
            index = 0
            while index < len(piece):
                token = piece[index]
                if token in MESSAGE_FLAGS and index + 1 < len(piece):
                    paths.append(piece[index + 1])
                    index += 2
                    continue
                for flag in MESSAGE_FLAGS:
                    if token.startswith(flag + "="):
                        paths.append(token[len(flag) + 1 :])
                index += 1
    if depth < MAX_DEPTH:
        for inner in embedded_commands(line):
            found = message_files(inner, depth + 1)
            if found is None:
                return None
            paths += found
    return [path for path in paths if path != "-"]


# Compared verbatim. An absent file is skipped rather than missed: `id_rsa` is
# absent wherever the key is an ed25519 one, and the gh login file does not
# exist until `gh auth login` has run. This is the layer with no false
# positives by construction.
#
# Every path here is one this image puts there, and that is the rule for what
# may be added: an agent decides where the credentials it acquires for itself
# live, so a path named here covers nothing from the day it picks another, and
# says nothing when it does. What covers those instead is VAULT_CACHE below —
# every fetched secret, whatever it is called — and the shapes under it.
# see docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose
CREDENTIAL_FILES = (
    ("the ssh private key", "~/.ssh/id_ed25519"),
    ("the ssh private key", "~/.ssh/id_rsa"),
    ("the Claude Code login", "~/.claude/.credentials.json"),
    # Written by `gh auth login --with-token`, which is open. The shape layer
    # already catches a `ghp_`/`github_pat_` token wherever it appears, so this
    # is the belt to that braces: one line, covering a token shape nobody has
    # thought of yet.
    ("the gh login", "~/.config/gh/hosts.yml"),
)

# Everything fetched from the vault. A directory rather than a list because the
# keys are not known here — the point of a vault the operator can add to without
# touching the image. `vault` writes each fetch here before printing anything
# and `bws` is denied, so this is what the vault looks like from the guard's
# side.
#
# Empty or absent is the normal state and must read as "nothing to compare
# against", never as an error: a directory that raised would take the whole
# secret check down with it.
VAULT_CACHE = "~/.cache/vault"

# The entries in there that are not credentials. The vault decides what a
# secret is, so an identifier stored beside a token refuses commits for no
# reason, and the only place to correct that is outside the vault — the file's
# own header says why it is not the vault's note field.
#
# Absent or unreadable exempts nothing: a missing list must read as "every
# vault entry is a secret", never as "none of them are". A file that grants
# exemptions has to fail on the strict side.
VAULT_EXEMPT = "/etc/agent/vault-exempt.txt"


def vault_exempt() -> frozenset[str]:
    try:
        text = Path(VAULT_EXEMPT).read_text(errors="replace")
    except OSError:
        return frozenset()
    names = set()
    for line in text.splitlines():
        name = line.split("#", 1)[0].strip()
        # A vault key has no whitespace in it, so a line that still has some
        # once the comment is stripped is a note someone forgot to comment out
        # — dropped rather than exempted. Enforced here rather than only
        # asserted in the selftest, because the host reader parses the same
        # file and a rule stated in one reader is one the other drifts from.
        if name and not any(c.isspace() for c in name):
            names.add(name)
    return frozenset(names)


# The second layer, for what is derived rather than copied. Deliberately
# short: a shape list that fires on ordinary prose is one that gets switched
# off, and then it is absent on the day it mattered.
#
# Here are the shapes true of every installation, and `host/archive/scan.sh`
# carries the same ones character for character — two readers of one shape that
# differ slightly are two rules, and only one of them gets edited. What is true
# of this installation alone is in the file read below, which both readers add
# to their own floor.
# see docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose
SECRET_SHAPES: tuple[tuple[str, re.Pattern[str]], ...] = (
    # A key is a header and a body. The header alone fires only on prose about
    # keys and on the armour constants a tool needs in order to rebuild a PEM,
    # and a rule whose firings are all false is the one that gets switched off.
    #
    # The separator is "up to twelve characters that cannot be body", which is
    # what lets it read a key however it arrives: behind a real newline, behind
    # a diff's `+` or `-`, behind a JSON-escaped `\n` in a transcript, or after
    # a quote in a source file. It deliberately does not skip `-----END`, whose
    # letters are body characters but stop well short of 32 — which is what
    # makes an armour pair with nothing between it pass.
    (
        "a private key block",
        re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[^A-Za-z0-9+/=]{0,12}[A-Za-z0-9+/]{32,}"),
    ),
    ("a github token", re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}")),
    ("a github token", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    ("an anthropic key", re.compile(r"sk-ant-[A-Za-z0-9-]{20,}")),
)


# --- this installation's own shapes ---
# The shapes above are true of every installation and stay in the code. The
# shape of a secret this agent holds because of what it does — a forum's key
# format, a feed token, a webhook URL — is not, and the tree names nobody, so
# those live in a file the operator writes and this repository does not carry.
# `host/archive/scan.sh` appends the same lines to the collection's floor, from
# the checkout's copy rather than this baked one.
#
# Appended, never replacing: an absent file adds nothing and the floor above
# still runs, which is what a fresh installation has.
# see docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose

SECRET_SHAPES_FILE = "/etc/agent/secret-shapes.txt"


def file_shapes() -> tuple[list[tuple[str, re.Pattern[str]]], list[str]]:
    """The shapes this installation adds, and the lines that would not compile.

    A line that does not compile is reported and not dropped. Dropping it would
    leave a check that reads as installed and compares less than it says, which
    is the one direction a mistake here must never take; the caller refuses on
    it instead, until the line is fixed.
    """
    try:
        text = Path(SECRET_SHAPES_FILE).read_text(errors="replace")
    except OSError:
        return [], []  # absent is the normal state of a fresh installation

    shapes: list[tuple[str, re.Pattern[str]]] = []
    broken: list[str] = []
    for number, line in enumerate(text.splitlines(), 1):
        rule, _, note = line.partition("#")
        rule = rule.strip()
        if not rule:
            continue
        try:
            shapes.append((note.strip() or "a shape this installation added", re.compile(rule)))
        except re.error as complaint:
            # The line number and the complaint, never the line itself: a
            # refusal is written to the transcript, and this is the one file
            # where someone may have typed a value where a shape was meant.
            broken.append(f"line {number}: {complaint}")
    return shapes, broken


def json_strings(node: object) -> list[str]:
    if isinstance(node, str):
        return [node]
    if isinstance(node, dict):
        return [s for v in node.values() for s in json_strings(v)]
    if isinstance(node, list):
        return [s for v in node for s in json_strings(v)]
    return []


# PEM armour, alone on a line. Boilerplate: identical across every key of its
# type, carrying no entropy that belongs to this one.
ARMOUR_ONLY = re.compile(r"-{3,}(BEGIN|END)[ A-Z0-9]*-{3,}")


def secret_strings(text: str) -> list[str]:
    """The parts of a credential file worth matching on.

    A login file is a document, most of which is not secret, so matching it
    whole would never fire — its string leaves are the tokens. A private key
    is the opposite: the file *is* the secret, and its body survives being
    re-wrapped or partly quoted, so each line counts as well as the whole.

    Except its armour. `-----END PRIVATE KEY-----` is 25 characters, over
    MIN_SECRET, so a stored PEM would otherwise register its own boilerplate as
    "the secret", and anything quoting that marker would then match verbatim —
    a diff hunk header is enough. Only the marker stops counting on its own;
    the body line is still a criterion, and the body is the part that is
    actually secret and that survives re-wrapping.
    See docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose.
    """
    out: list[str] = [text.strip()]
    try:
        out.extend(json_strings(json.loads(text)))
    except ValueError:
        out.extend(line.strip() for line in text.splitlines())
    return [v for v in dict.fromkeys(out) if len(v) >= MIN_SECRET and not ARMOUR_ONLY.fullmatch(v)]


def credential_values() -> list[tuple[str, str]]:
    values: list[tuple[str, str]] = []
    for label, path in CREDENTIAL_FILES:
        try:
            text = Path(path).expanduser().read_text(errors="replace")
        except OSError:
            continue  # absent, or unreadable: nothing to compare against
        values.extend((label, v) for v in secret_strings(text))
    try:
        exempt = vault_exempt()
        for entry in sorted(Path(VAULT_CACHE).expanduser().iterdir()):
            if not entry.is_file():
                continue
            if entry.name in exempt:
                # Out of the verbatim list only: SECRET_SHAPES still reads the
                # same text, so an exemption cannot make a real credential
                # invisible, only stop an identifier being mistaken for one.
                continue
            try:
                text = entry.read_text(errors="replace")
            except OSError:
                continue
            values.extend((f"the vault secret {entry.name}", v) for v in secret_strings(text))
    except OSError:
        pass  # no cache directory: nothing has been fetched, nothing to compare

    for name, label in (
        ("GH_TOKEN", "the gh token"),
        # The key to everything else in the vault: a commit carrying it hands
        # over every secret at once, so it belongs here even though nothing
        # fetches it.
        ("BWS_ACCESS_TOKEN", "the vault access token"),
    ):
        token = os.environ.get(name, "")
        if len(token) >= MIN_SECRET:
            values.append((label, token))
    return values


def scan(text: str, values: list[tuple[str, str]] | None = None) -> str | None:
    """What matched, named. Never the value that matched it.

    A check that echoes the secret into its own refusal has moved it rather
    than caught it: the refusal is written to the transcript, and the
    transcript is archived. One more copy, in one more place.
    """
    if not text:
        return None
    for label, value in credential_values() if values is None else values:
        # Checked here and not only where the list is built: a short value
        # is a substring of ordinary prose, and this function must be safe
        # to hand any list at all — the selftest hands it one directly.
        if len(value) >= MIN_SECRET and value in text:
            return f"{label}, matched verbatim"
    shapes, _ = file_shapes()
    for label, pattern in (*SECRET_SHAPES, *shapes):
        if pattern.search(text):
            return f"{label}, matched by shape"
    return None


def git_output(cwd: str, args: list[str]) -> tuple[bool, str] | None:
    """(this call succeeded, its output) — or None when nothing can be read.

    Three states, and collapsing any two of them breaks something.

    None is "nothing proven": a timeout, a missing git, output past the cap.
    The caller refuses on it, because a function that returns an empty string
    when it fails makes a check that passes when it breaks.

    A non-zero exit is "this particular question does not apply" — `git diff
    HEAD` in a repository whose first commit has not happened. Refusing on it
    would refuse every initial commit.

    But "does not apply" is not "there is no repository here": with a cwd that
    is not a repository, every call exits non-zero, every answer is empty, and
    a staged key scans clean. So the caller is told which calls actually ran,
    and refuses when none of them did — a fresh repository always has at
    least one part exit 0, `diff --cached`, while a non-repo has none.
    See docs/boundary.md#which-repository-and-which-span.
    """
    try:
        done = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=GIT_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if len(done.stdout) > MAX_SCAN:
        return None
    return done.returncode == 0, done.stdout


# Why nothing could be read. Three states that each stop the check, and each
# needs its own sentence: a session told to look for a 4MB diff when the real
# cause is a cwd with no repository in it finds neither, concludes the guard is
# broken, and starts looking for a way around.
# see docs/boundary.md#what-the-refusals-say
UNREADABLE = "unreadable"
NO_REPOSITORY = "no-repository"
UNPARSEABLE = "unparseable"


def message_file_text(command: str, directories: list[str]) -> tuple[str | None, str | None]:
    """(what the message files hold, why nothing could be read).

    A path that does not exist is passed over rather than refused: git will
    fail on it too, so nothing reaches history. One that exists and cannot be
    read is unproven, which is refused — the rule the oversized diff gets.

    Not knowing which files they are is a different miss from not being able
    to read one, and it is the commoner of the two: this is asked only after
    the line has already parsed once, so what fails here is a command quoted
    inside it. Saying "a file could not be read" about a line with no file on
    it is a confident wrong answer, and the refusal is written for someone who
    has to act on it.
    """
    paths = message_files(command)
    if paths is None:
        return None, UNPARSEABLE
    text = ""
    # A relative path is resolved against every directory a gated verb on
    # this line runs in. Which command owns which -F is a question worth more
    # than it buys: one file too many can only refuse, one too few is the
    # hole being closed.
    for path in paths:
        wholes = (
            [Path(path)]
            if os.path.isabs(path)
            else [Path(d) / path for d in (directories or ["."])]
        )
        for whole in wholes:
            if not whole.exists():
                continue
            try:
                if whole.stat().st_size > MAX_SCAN:
                    return None, UNREADABLE
                text += whole.read_text(errors="replace")
            except OSError:
                return None, UNREADABLE
    return text, None


def commit_path_text(act: str, cwd: str, span: str) -> tuple[str | None, str | None]:
    if act in ("tag", "notes"):
        # Neither records a change. The message is the whole of what they
        # carry, and it has already been read from the command line and from
        # any -F file.
        return "", None
    if act == "commit":
        # --cached is what a plain commit takes, and `commit_span` has already
        # said whether this spelling takes more. HEAD is the rest: `commit -a`
        # stages tracked changes as it runs and a pathspec records them too, so
        # there the wider read is the right span rather than caution.
        #
        # --cached stays first and unconditional for a second reason: it is the
        # part that exits 0 in a repository with no commits yet, which is how
        # the caller tells "does not apply" from "there is no repository here".
        parts = [git_output(cwd, ["diff", "--cached"])]
        if span != INDEX:
            parts.append(git_output(cwd, ["diff", "HEAD"]))
    else:
        # What a push would publish: everything local that no remote already
        # has, not the current branch's span. `<upstream>..HEAD` is bound to
        # the branch HEAD sits on, while a push publishes whatever refs it is
        # given — `git push origin side`, a refspec, `--all`.
        # see docs/boundary.md#what-a-commit-or-a-push-would-carry
        #
        # The bound it cannot compute: with no remote configured at all,
        # `--not --remotes` excludes nothing and this is the whole history.
        # Acceptable against the cap, and past the cap the answer is a refusal.
        #
        # Tag messages stay a separate read: `--all` covers commits reachable
        # from a tag, not the annotation on the tag object. Every local tag is
        # read rather than those a given push carries — one tag too many can
        # only refuse.
        parts = [
            git_output(cwd, ["log", "-p", "--no-color", "--all", "--not", "--remotes"]),
            git_output(cwd, ["for-each-ref", "--format=%(contents)", "refs/tags"]),
        ]
    if any(part is None for part in parts):
        return None, UNREADABLE
    # Narrowed explicitly: the check above already proved no element is
    # None, but mypy cannot carry that through a list comprehension.
    resolved: list[tuple[bool, str]] = [part for part in parts if part is not None]
    if not any(ok for ok, _ in resolved):
        return None, NO_REPOSITORY
    return "".join(text for _, text in resolved), None


def secret_in_commit_path(command: str, cwd: str) -> str | None:
    verdict = decide_bash(command, COMMIT_PATH)
    if not verdict or verdict[0] != "deny":
        return None
    act = verdict[1].split()[0]
    # Which tree, before what is in it: reading the wrong one is a confident
    # wrong answer, in both directions.
    #
    # The refusals below name the rule by its subject, never by number. A
    # subject survives the agent renumbering its own rules; a number is a copy
    # of a heading in a file this image cannot see move.
    # see docs/boundary.md#what-the-refusals-say
    # Before anything is read: a shape list that cannot be compiled whole is a
    # floor with a hole in it, and the hole is invisible from the answer. So the
    # act is refused until the line is fixed, rather than compared against what
    # did compile. see docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose
    _, broken = file_shapes()
    if broken:
        return (
            f"a secret never enters this history: this installation's shape list "
            f"{SECRET_SHAPES_FILE} does not compile whole ({'; '.join(broken)}), so "
            f"what this {act} carries cannot be judged against it. Nothing about it "
            f"is proven, and unproven is refused here rather than waved through."
        )

    records, undecided = gated_commands(command, cwd)
    if records is None:
        return (
            f"a secret never enters this history: which repository this {act} would act on could not be "
            f"told, because {undecided}. Nothing about what it carries is "
            f"proven, and unproven is refused here rather than waved through."
        )
    # No gated verb resolved means the registry saw one the walk did not —
    # keep the session's directory rather than scanning nothing, and the
    # widest span, because nothing about this line was actually parsed.
    if not records:
        records = [(act, cwd, WORKTREE, "nothing about this line actually parsed")]

    # The message is not in the diff. It travels in the command line — `-m`,
    # or a heredoc body feeding `git commit -F -` — and a secret quoted into
    # a commit message is in the history exactly as firmly as one in a file.
    # Read first because it is a short string, and free next to a `git diff`.
    found, where = scan(command), "its message or arguments"
    if found is None:
        from_file, why = message_file_text(command, [d for _, d, *_ in records])
        if from_file is None:
            because = {
                UNPARSEABLE: (
                    "a command written inside this one — a substitution, or a "
                    "payload handed to a shell — could not be parsed, so where "
                    "the message comes from is not known. No file is named "
                    "here; the argument holding that command is where to look"
                ),
                UNREADABLE: (
                    "it takes the message from a file that is larger than the "
                    "guard reads, or that could not be read at all"
                ),
            }[cast(str, why)]
            return (
                f"a secret never enters this history: what this {act} would say could not be read, because "
                f"{because}. Nothing about it is proven, and unproven is "
                f"refused here rather than waved through."
            )
        found, where = scan(from_file), "the file its message comes from"
    for act, cwd, span, widened in [] if found else records:
        text, why = commit_path_text(act, cwd, span)
        if text is None:
            because = {
                UNREADABLE: (
                    f"it is larger than the guard reads, or git did not answer "
                    f"inside {GIT_TIMEOUT}s"
                ),
                NO_REPOSITORY: (
                    f"there is no git repository at {cwd or '(no directory)'}, "
                    f"which is where this line resolves to — `cd` and `-C` are "
                    f"followed, while `--git-dir`, `--work-tree` and `GIT_DIR=` "
                    f"are deliberately not"
                ),
            }[cast(str, why)]
            return (
                f"a secret never enters this history: what this {act} would carry could not be read, "
                f"because {because}. Nothing about it is proven, and unproven "
                f"is refused here rather than waved through, because the one "
                f"mistake this checks for cannot be undone afterwards."
            )
        found = scan(text)
        if found:
            # Which tree was read, and — when that is more than the index —
            # what made it more. The span is named rather than the half the
            # secret sits in: the two are read as one string, so saying which
            # would be a guess, while the token is the part that is not.
            where = (
                "the commits and tags it would publish"
                if act != "commit"
                else "the change it would record"
                if span == INDEX
                else f"the change it would record and the tracked working "
                f"tree besides, because {widened}"
            )
            break
    if found is None:
        return None
    return (
        f"a secret never enters this history: this {act} carries {found}, in {where}. Nothing ran. The "
        f"value is not named here — a refusal that quotes a secret has copied "
        f"it into the transcript rather than kept it out of the history."
    )


# =========================== hook entry point ==============================


def decide(tool_name: str, tool_input: dict, cwd: str = "") -> tuple[str, str] | None:
    if tool_name != "Bash":
        return None
    command = str(tool_input.get("command", ""))
    verdict = decide_bash(command, TOOLS)
    if verdict and verdict[0] == "deny":
        return verdict  # already refused: nothing to read, nothing to run
    # Ranked above everything softer than a deny, and consulted only when the
    # registry did not already refuse — so an ordinary command pays nothing
    # and a commit pays one `git diff`.
    secret = secret_in_commit_path(command, cwd or os.getcwd())
    return ("deny", secret) if secret else verdict


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        verdict = decide(
            str(payload.get("tool_name", "")),
            payload.get("tool_input") or {},
            str(payload.get("cwd") or ""),
        )
    # A broken guard must not fail open: any internal error becomes an ask.
    # This cannot catch a module that fails to load — see KEEPING IT HONEST.
    except Exception as exc:  # noqa: BLE001
        verdict = ("ask", f"guard hook error, decide manually: {exc}")

    if verdict is None:
        return 0
    decision, reason = verdict
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": decision,
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    return 0


# =========================== selftest ======================================
# Add a case for every rule you add, and — when the operator reports the guard
# getting something wrong — the exact command they reported. Wire `--selftest`
# into pre-commit or CI: a guard that stops working should fail the lint, not
# fail open.

# Cases for the registry's own tools: what each rule does and does not gate.
# Keep these about the tool. Anything that is really about how the engine reads
# a command line belongs in ENGINE_CASES, where it is tested once for all tools.
CASES: tuple[tuple[str, str], ...] = (
    # --- the ordinary session, which must stay out of the way ---------------
    ("git status", "silent"),
    # Shell syntax in front of the command, which also misses the prefix
    # denies: those match from the start of a line. `bws` is the witness
    # because these test the engine finding a command behind shell syntax, and
    # that needs a gated act to be visible at all — re-pointed at an ungated
    # tool, a `silent` here would prove nothing.
    ("{ bws secret list; }", "deny"),
    ("if true; then bws secret list; fi", "deny"),
    ("while :; do bws secret list; done", "deny"),
    ("for f in a b; do bws secret list; done", "deny"),
    ("{ FOO=1 bws secret list; }", "deny"),
    ("(bws secret list)", "deny"),
    # …and the words themselves are not commands to gate.
    ("if true; then echo hi; fi", "silent"),
    ("for f in a b; do echo $f; done", "silent"),
    ("git log --oneline -15", "silent"),
    ("git diff HEAD~1", "silent"),
    ("git add -A", "silent"),
    ("git commit -m wip", "silent"),
    ("git commit -F msg.txt", "silent"),  # not the granted shape
    # Plain push is silent by decision, not by omission: it is how the agent
    # backs its memory up.
    ("git push", "silent"),
    ("git push origin main", "silent"),
    ("git clone git@github.com:example/repo.git", "silent"),
    # Local work, never gated here.
    ("git restore .", "silent"),
    ("git clean -fd", "silent"),
    ("git checkout -- file.py", "silent"),
    ("git stash drop", "silent"),
    ("git branch -D topic", "silent"),
    ("git tag -d v1", "silent"),
    # --- force-push and rewrite: ungated here --------------------------------
    # These assert `silent` on purpose. A `deny` reappearing under any of them
    # is a rule that came back without a ruling, which is the only failure this
    # section can still report, and the reason the list is this long.
    # see docs/boundary.md#the-withdrawal-of-2026-09-01
    ("git push --force", "silent"),
    ("git push -f origin main", "silent"),
    ("git push origin --force main", "silent"),
    ("git push origin main --force", "silent"),
    ("git -C /home/agent/agent push --force-with-lease", "silent"),
    ("git push --mirror origin", "silent"),
    ("git push origin --delete main", "silent"),
    ("git commit --amend --no-edit", "silent"),
    ("git commit -m x --amend", "silent"),
    ("git --git-dir=.git commit --amend", "silent"),
    ("git reset --hard HEAD~1", "silent"),
    ("git reset --keep HEAD~1", "silent"),
    ("git reset --merge HEAD~1", "silent"),
    ("git rebase -i main", "silent"),
    ("git rebase --onto main topic", "silent"),
    ("git filter-branch -f --tree-filter true HEAD", "silent"),
    ("git filter-repo --path src", "silent"),
    ("git-filter-repo --path src", "silent"),  # the standalone binary, no longer a tool
    ("git reflog expire --expire=now --all", "silent"),
    ("git reflog delete HEAD@{2}", "silent"),
    ("git update-ref -d refs/heads/topic", "silent"),
    ("git gc --prune=now", "silent"),
    # --- the grant, and where it is withheld --------------------------------
    ('git commit -m "$(cat msg.txt)"', "allow"),
    ('git commit --message "$(cat m)"', "allow"),
    ('git commit -m "$(bws secret list)"', "deny"),  # a gated command inside
    ('git -C /elsewhere commit -m "$(cat m)"', "silent"),  # a global moves the repo
    ('git --exec-path=/tmp/x commit -m "$(cat m)"', "silent"),  # …and this runs code
    # --- through a wrapper, which is the route the note records walking -----
    ("env FOO=1 bws secret list", "deny"),
    ("nohup bws secret list", "deny"),
    ("timeout 30 bws secret list", "deny"),
    ("sh -c 'bws secret list'", "deny"),
    ('bash -lc "bws secret list"', "deny"),
    ("git status && bws secret list", "deny"),  # judged one command at a time
    ("xargs -n1 bws secret list", "deny"),
    # --- gh api: free to read, gated where it would write -------------------
    ("gh api repos/example/repo/issues", "silent"),
    ("gh api /user", "silent"),
    ("gh api repos/o/r --jq .name", "silent"),  # a read flag is not a write
    ("gh api --paginate repos/o/r/issues", "silent"),
    ("gh api repos/o/r/issues -f title=x", "ask"),  # POST without --method
    ("gh api repos/o/r/issues -F title=x", "ask"),
    ("gh api repos/o/r/issues --raw-field title=x", "ask"),
    ("gh api graphql -f query='mutation{addStar(input:{})}'", "ask"),
    ("gh api --input body.json repos/o/r/issues", "ask"),
    ("gh api --method DELETE repos/o/r", "ask"),
    ("gh api repos/o/r --method DELETE", "ask"),  # after the endpoint: what a
    ("gh api repos/o/r -X PATCH", "ask"),  # prefix pattern cannot see
    ("gh api --method=DELETE repos/o/r", "ask"),  # …and the one-token spelling
    # --- gh auth: the login is given, used, and never changed ---------------
    # `login` is the open one: it is how a token out of the vault becomes the
    # credential gh uses, which is the whole reason the vault holds one.
    ("gh auth login --with-token", "silent"),
    ("gh auth token", "deny"),
    ("gh auth token --hostname github.com", "deny"),
    ("gh auth logout", "deny"),
    ("gh auth switch --user someone", "deny"),
    ("gh auth refresh --scopes repo", "deny"),
    ("gh auth setup-git", "deny"),
    ("gh repo delete owner/repo --yes", "deny"),
    # Spellings no prefix pattern in the managed list can match, which is the
    # reason these rules exist here as well as there.
    ("sudo gh auth token", "deny"),
    ("env X=1 gh auth logout", "deny"),
    # Silent to the guard and denied by the managed list — deliberately, and
    # it is load-bearing: this is what `just verify` probes to prove managed
    # settings are read at all. A guard rule here would answer first and the
    # probe would pass on the guard's word while the deny list rotted.
    ("gh auth status", "silent"),
    # Only `api` and `auth` are gated. The rest of gh is the permission rules'.
    ("gh issue list", "silent"),
    ("gh issue comment 3 --body hi", "silent"),
    ("gh pr view 3", "silent"),
)


# --- test fixture: a tool that does not exist ------------------------------
# `stubtool` is not in TOOLS and is not a real program. It exists so the engine
# can be tested on its own terms — how a line is cut up, how flags are parsed,
# how verdicts rank — without tying those tests to rules that legitimately
# change per project: trimming a git rule must not break a test about newlines.
#
# It declares everything the engine can express, so nothing is tested by
# accident: rules and grants together, a deny and an ask on the same path, a
# value-taking flag, a closed-world flag set. Its shape follows a deploy tool
# that is dangerous by default and safe only when it parses — a fixture, not
# a config to copy verbatim.

STUB_SAFE_FILE = re.compile(r"^(?:.*/)?validates?\.ya?ml$")

STUB_READ_VERBS = re.compile(r"^(list|show|catalog)$")
STUB_WRITE_VERBS = re.compile(r"^(create|delete|set)$")

# A second fixture, for the shapes the first cannot express: a verb that can
# sit anywhere among the operands, and a tool whose unproven case is a denial
# rather than a prompt.
STUBCLI = Tool(
    name="stubcli",
    gated_verdict="deny",
    gated_reason="stub: only a demonstrable read is free here",
    grants=(Grant(operands=any_of(STUB_READ_VERBS)),),
    rules=(
        Rule(
            "deny", (), "stub: a write verb sits in this command", operands=any_of(STUB_WRITE_VERBS)
        ),
    ),
)

# Nothing here is ever silent: no grants, no rules, one verdict. The shape a
# tool takes when every use of it is the operator's.
STUBALWAYS = Tool(
    name="stubalways",
    gated_verdict="deny",
    gated_reason="stub: every use of this one is the operator's",
)

STUB = Tool(
    name="stubtool",
    # A second name for the same tool, so alias indexing is exercised.
    aliases=frozenset({"stub2"}),
    # Two handoffs: one whose own options take a value, one that keeps an
    # operand for itself before the command begins.
    nested=(
        Nested(("exec",), value_opts=frozenset({"-u"}), operands=1),
        Nested(("run",), operands=1),
    ),
    gated_reason="stub: this invocation is not one of the proven-safe shapes",
    known_flags=frozenset(
        {"--syntax-check", "--list-tasks", "-i", "--inventory", "--tags", "--limit", "--mode"}
    ),
    value_flags=frozenset({"-i", "--inventory", "--tags", "--limit", "--mode"}),
    known_env=frozenset({"STUB_QUIET", "STUB_TARGET"}),
    grants=(
        # Two ways to be safe: it only parses, or the file it is given is one
        # that is read-only by construction.
        Grant(require_any=frozenset({"--syntax-check", "--list-tasks"})),
        Grant(operands=STUB_SAFE_FILE),
        # Operands that are paths, so `under` applies there too — the shape a
        # tool like `rm` needs, where the paths are the operands.
        Grant(path=("clean",), operands=under("/tmp", ".scratch")),
        # A flag whose value must match. A regex is right here: the value is a
        # keyword, so the raw string is exactly what matters.
        Grant(path=("apply",), flag_values=(("--mode", re.compile(r"^(dry-run|check)$")),)),
        # An assignment whose value is a path, so `under` resolves it before
        # comparing. A `^/tmp/` regex would accept `/tmp/../etc`. All three
        # location forms are used, so each is covered by the cases.
        Grant(
            path=("apply",),
            env_values=(
                (
                    "STUB_TARGET",
                    under("/tmp", "/home/*/scratch", re.compile(r"^/mnt/\w+/build$")),
                ),
            ),
        ),
    ),
    rules=(
        # Deliberately ask-first: deny must win on ranking, not on table order.
        Rule("ask", ("wipe",), "stub: an ask that deny outranks"),
        Rule("deny", ("wipe",), "stub: an act with no authorized use"),
        # A rule holds even where a grant would otherwise make the line silent.
        Rule("ask", ("touch",), "stub: a rule fires though a grant holds"),
        # The danger is in the environment, not on the command line.
        Rule(
            "deny", (), "stub: an assignment with no authorized use", env=frozenset({"STUB_DANGER"})
        ),
    ),
)

# How the engine reads a command line: splitting, quoting, parsing, ranking.
# Driven entirely by the `stubtool` fixture so that these stay true no matter
# what a project does to its own registry. Nothing here should name a real tool.
ENGINE_CASES: tuple[tuple[str, str], ...] = (
    # --- grants: proven safe, or not ---------------------------------------
    ("stubtool --syntax-check site.yml", "silent"),
    ("stubtool site.yml --syntax-check", "silent"),  # the flag is found last
    ("stubtool -i prod --syntax-check site.yml", "silent"),
    ("stubtool --tags foo --syntax-check deploy.yml", "silent"),
    ("stubtool --list-tasks deploy.yml", "silent"),
    ("stubtool run/validates.yaml", "silent"),  # operand pattern grant
    ("stubtool deploy.yml", "ask"),
    ("stubtool -i prod deploy.yml", "ask"),
    ("stubtool validates.yaml -e target=prod", "ask"),  # unaccounted flag
    # a value-taking flag swallows the next token, so it is not operative
    ("stubtool deploy.yml -i --syntax-check", "ask"),
    ("stubtool deploy.yml --tags --syntax-check", "ask"),
    ("stubtool deploy.yml --limit", "ask"),  # value flag with nothing after it
    # closed world: a flag that is not accounted for leaves it unproven
    ("stubtool deploy.yml -e msg='--syntax-check'", "ask"),
    ("stubtool --syntax-check deploy.yml --unknown", "ask"),
    # --- rules, and how they rank against grants ---------------------------
    ("stubtool wipe --syntax-check", "deny"),  # deny outranks ask and the grant
    ("stubtool touch --syntax-check", "ask"),  # a rule fires though a grant holds
    ("stubtool other --syntax-check", "silent"),  # no rule: the grant decides
    # --- environment assignments -------------------------------------------
    # An assignment before the command is environment, and is matched in its
    # own right rather than skipped.
    ("STUB_QUIET=1 stubtool --syntax-check site.yml", "silent"),  # accounted for
    ("STUB_UNKNOWN=1 stubtool --syntax-check site.yml", "ask"),  # closed world
    ("STUB_DANGER=1 stubtool --syntax-check site.yml", "deny"),  # rule beats grant
    ("STUB_QUIET=1 stubtool deploy.yml", "ask"),  # still not a proven shape
    ("STUB_TARGET=/tmp/x stubtool apply", "silent"),  # grant turns on the value
    ("STUB_TARGET=/prod stubtool apply", "ask"),
    ("stubtool apply", "ask"),  # the assignment is what made it safe
    # `under` resolves the path before comparing, so a grant on a location
    # cannot be satisfied by a string that merely starts with it
    ("STUB_TARGET=/tmp/../etc stubtool apply", "ask"),
    ("STUB_TARGET=/tmp/../../root stubtool apply", "ask"),
    ("STUB_TARGET=/tmp/a/../b stubtool apply", "silent"),  # still under /tmp
    ("STUB_TARGET=/tmp stubtool apply", "silent"),  # the directory itself
    ("STUB_TARGET=/tmpevil stubtool apply", "ask"),  # a prefix is not a parent
    ("STUB_TARGET=tmp/x stubtool apply", "ask"),  # relative: matches nothing
    ("STUB_TARGET=~/tmp stubtool apply", "ask"),  # ~ expands, and is not /tmp
    # a glob location: `*` does not cross a separator
    ("STUB_TARGET=/home/user/scratch stubtool apply", "silent"),
    ("STUB_TARGET=/home/user/scratch/build stubtool apply", "silent"),
    ("STUB_TARGET=/home/a/b/scratch stubtool apply", "ask"),
    ("STUB_TARGET=/home/user/other stubtool apply", "ask"),
    # a regex location, matched against the whole resolved path
    ("STUB_TARGET=/mnt/data/build stubtool apply", "silent"),
    ("STUB_TARGET=/mnt/data/builds stubtool apply", "ask"),
    ("STUB_TARGET=/mnt/data/build/sub stubtool apply", "ask"),  # anchored, exact
    # resolution happens before matching for *every* form, not just the plain one
    ("STUB_TARGET=/home/user/scratch/../../etc stubtool apply", "ask"),
    ("STUB_TARGET=/mnt/data/build/../../../etc stubtool apply", "ask"),
    # a flag whose value must match, where the raw string is what matters
    ("stubtool apply --mode dry-run", "silent"),
    ("stubtool apply --mode check", "silent"),
    ("stubtool apply --mode destroy", "ask"),
    ("stubtool apply --mode", "ask"),  # value flag with nothing after it
    # an assignment *after* the command name is an operand, not environment
    ("stubtool --syntax-check STUB_DANGER=1", "silent"),
    ("STUB_QUIET=1 STUB_TARGET=/tmp/x stubtool apply", "silent"),  # several
    # bash's append form is a command prefix too, and names the same variable
    ("STUB_DANGER+=1 stubtool --syntax-check site.yml", "deny"),
    ("STUB_QUIET+=1 stubtool --syntax-check site.yml", "silent"),
    # lower case is a valid shell name, so it is detected — but it is a
    # different variable, and for a gated tool the closed world catches it
    ("stub_danger=1 stubtool --syntax-check site.yml", "ask"),
    # --- wrappers: a program whose job is to run another program ------------
    # The wrapped command is reached and judged on its own terms.
    ("sudo stubtool deploy.yml", "ask"),
    ("sudo stubtool wipe", "deny"),
    ("env stubtool wipe", "deny"),
    ("time stubtool wipe", "deny"),
    ("nohup stubtool wipe", "deny"),
    ("xargs stubtool wipe", "deny"),
    # eval joins its arguments and runs the result, so the payload is
    # re-examined rather than stepped over — a quoted one is a single token
    # that names no tool, and stepping over it would go silent
    ("eval stubtool wipe", "deny"),
    ('eval "stubtool wipe"', "deny"),
    ("eval 'stubtool wipe'", "deny"),
    ('eval "stubtool --syntax-check a.yml"', "silent"),
    ('eval "make check"', "silent"),
    ("eval \"sh -c 'stubtool wipe'\"", "deny"),  # nesting still terminates
    ("eval", "silent"),  # nothing to run
    ("sudo stubtool --syntax-check site.yml", "silent"),
    # the wrapper's own options are stepped over to find the command
    ("sudo -u deployer stubtool wipe", "deny"),
    ("sudo --user=deployer stubtool wipe", "deny"),
    ("nice -n 5 stubtool wipe", "deny"),
    ("timeout 30 stubtool wipe", "deny"),  # a positional the wrapper takes
    ("timeout -k 5 30 stubtool wipe", "deny"),
    ("xargs -n 1 stubtool wipe", "deny"),
    ("sudo --unknown-flag stubtool wipe", "deny"),  # unknown flags are skipped
    # wrappers stack, and assignments along the way still bind
    ("sudo env STUB_DANGER=1 stubtool --syntax-check a.yml", "deny"),
    ("sudo nice -n 5 stubtool wipe", "deny"),
    ("env STUB_QUIET=1 stubtool --syntax-check a.yml", "silent"),
    # a value-taking option really does consume its value: here `stubtool` is
    # the user to run `wipe` as, not a command, and there is nothing to gate
    ("sudo -u stubtool wipe", "silent"),
    # but an option we do not know is value-taking loses the thread, and a
    # wrapper we cannot see past asks rather than going quiet
    ("sudo --prompt-file /tmp/p stubtool wipe", "ask"),
    ("sudo sh -lc 'stubtool wipe'", "deny"),
    # a wrapper running something ungated says nothing
    ("sudo apt install ripgrep", "silent"),
    ("time make check", "silent"),
    # --- a shell asked to run a command line re-examines it -----------------
    ("sh -c 'stubtool wipe'", "deny"),
    ("bash -c 'stubtool deploy.yml'", "ask"),
    ("sh -c 'stubtool --syntax-check a.yml'", "silent"),
    ("bash -lc 'stubtool wipe'", "deny"),
    ("sh -c 'sh -c \"stubtool wipe\"'", "deny"),  # nesting terminates
    ("sh -c 'make check'", "silent"),
    # python's -c is another language, and is deliberately not read as shell
    ("python3 -c 'print(1)'", "silent"),
    # --- an unrecognised leader is silent by default ------------------------
    # A runner that is not in SHELL_WRAPPERS is not seen through — the fix is
    # to list it there, not to guess from a name appearing in the line, which
    # would gate the second case too.
    ("myrunner stubtool wipe", "silent"),
    # --- any_of, and a gated tool whose unproven case is a denial ----------
    ("stubcli server list", "silent"),  # the verb sits second
    ("stubcli security group rule list", "silent"),  # …and here, fourth
    ("stubcli catalog list", "silent"),
    ("stubcli server delete x", "deny"),  # no read verb: not a proven shape
    ("stubcli server frobnicate x", "deny"),  # unknown is gated, not silent
    ("stubcli", "deny"),  # a matcher on operands needs operands
    ("stubcli server list && stubcli server delete x", "deny"),  # judged apart
    # the one case the deny rule buys once judging is per-invocation: a read
    # verb that is a name rather than a verb
    ("stubcli server delete list", "deny"),
    # gated_verdict without grants: the tool that is always the operator's
    ("stubalways anything at all", "deny"),
    ("stubalways", "deny"),
    ("sudo stubalways --help", "deny"),  # a wrapper does not launder it
    ("grep stubtool README.md", "silent"),
    ("ls ../stubtool", "silent"),
    ("cat docs/env", "silent"),  # `env` is a wrapper name, and also a filename
    # --- a tool that hands off to another command ---------------------------
    # The outer invocation and the inner one are both judged; strongest wins.
    ("stubtool exec box stubtool wipe", "deny"),
    ("stubtool exec -u root box stubtool wipe", "deny"),  # its own option skipped
    ("stubtool exec box stubtool --syntax-check a.yml", "ask"),  # outer unproven
    ("stubtool exec box echo hi", "ask"),  # nothing gated inside
    ("stubtool build .", "ask"),  # no handoff declared at `build`
    # `run` keeps one operand for itself, then the command begins
    ("stubtool run image stubtool wipe", "deny"),  # command after the operand
    ("stubtool run stubtool wipe", "ask"),  # the operand is not read as a program
    ("stubtool run image --syntax-check a.yml", "ask"),  # no command, just args
    # --- operands that are paths, matched with `under` ----------------------
    # Every operand must match, and each is resolved before it is compared.
    ("stubtool clean /tmp/x", "silent"),
    ("stubtool clean /tmp/x /tmp/y", "silent"),
    ("stubtool clean .scratch/build", "silent"),  # a relative location
    ("stubtool clean ./.scratch/build", "silent"),
    ("stubtool clean /tmp/x /etc/passwd", "ask"),  # one operand outside
    ("stubtool clean /etc/passwd", "ask"),
    ("stubtool clean /tmp/../etc", "ask"),  # the traversal, on an operand
    ("stubtool clean .scratch/../secrets", "ask"),
    ("stubtool clean .scratch/a/../b", "silent"),  # resolves back inside
    ("stubtool clean", "ask"),  # an operand grant needs at least one
    # --- aliases: another name for the same tool ----------------------------
    ("stub2 wipe", "deny"),
    ("stub2 --syntax-check site.yml", "silent"),
    ("stub2 deploy.yml", "ask"),
    ("stub2 exec box stubtool wipe", "deny"),  # handoffs come with the alias
    ("stub2 run image stubtool wipe", "deny"),  # and the handoff comes with it
    ("sudo stub2 wipe", "deny"),  # and compose with a wrapper
    ("stub2x wipe", "silent"),  # whole-word, as with the primary name
    # --- quoting ------------------------------------------------------------
    ("echo 'stubtool deploy.yml'", "silent"),  # a whole command quoted is data
    # quotes are resolved before matching: this stays one operand, and one
    # operand carrying a space is not the plain word a grant will accept
    ("stubtool --syntax-check 'my file.yml'", "ask"),
    # a tool is matched on whole words, not on a prefix of its name
    ("stubtool-extra deploy.yml", "silent"),
    ("mystubtool deploy.yml", "silent"),
    # --- separators ---------------------------------------------------------
    ("cd /srv && stubtool run/validates.yaml", "silent"),
    ("stubtool deploy.yml && stubtool --syntax-check a.yml", "ask"),
    ("stubtool --syntax-check a.yml && stubtool deploy.yml", "ask"),
    ("stubtool --syntax-check a.yml && stubtool b.yml --syntax-check", "silent"),
    ("stubtool --syntax-check a.yml; stubtool deploy.yml", "ask"),
    ("stubtool --syntax-check a.yml | stubtool deploy.yml", "ask"),
    ("stubtool --syntax-check a.yml && stubtool wipe", "deny"),
    ("stubtool wipe && stubtool --syntax-check a.yml", "deny"),
    # --- newlines separate commands too -------------------------------------
    ("stubtool --syntax-check a.yml\nstubtool deploy.yml", "ask"),
    ("stubtool deploy.yml\nstubtool --syntax-check a.yml", "ask"),
    ("echo hi\nstubtool deploy.yml", "ask"),
    ("stubtool --syntax-check a.yml\n\n\nstubtool deploy.yml", "ask"),
    ("stubtool --syntax-check a.yml\nstubtool --list-tasks b.yml", "silent"),
    # a newline inside quotes is data: it must not start a new command
    ('echo "one\nstubtool deploy.yml"', "silent"),
    # --- backslash continuations are joined, as the shell joins them --------
    ("stubtool deploy.yml \\\n--syntax-check", "silent"),
    ("stubtool deploy.yml \\\n         --syntax-check", "silent"),
    ("stubtool \\\n--syntax-check site.yml", "silent"),
    # --- a comment is not part of the command -------------------------------
    ("stubtool deploy.yml  # --syntax-check next time", "ask"),
    # --- heredocs -----------------------------------------------------------
    # a body written to a file or a message is data, and dropped
    ("cat > play.yml <<'EOF'\nstubtool deploy.yml\nEOF", "silent"),
    # a body fed to an interpreter is what runs, so it is kept and judged
    ("bash <<'EOF'\nstubtool deploy.yml\nEOF", "ask"),
    ("sh <<SH\nstubtool deploy.yml\nSH", "ask"),
    # --- a line that cannot be parsed is unproven, not safe -----------------
    ("stubtool 'unbalanced", "ask"),
    ("echo 'unbalanced", "silent"),  # no registered tool named: no opinion
    # --- commands the registry says nothing about stay untouched ------------
    ("make check", "silent"),
    ("ls -la && rg TODO src/", "silent"),
    ("python3 scripts/build.py --force", "silent"),
    # --- redirections are punctuation, not operands -------------------------
    # Left in argv as bare words they become operands nobody passed, in every
    # reader of an argv at once.
    ("stubtool --syntax-check site.yml 2>&1", "silent"),
    ("stubtool --syntax-check site.yml > out.txt", "silent"),
    ("stubtool --syntax-check site.yml 2>/dev/null", "silent"),
    ("stubtool --syntax-check site.yml >>log 2>&1", "silent"),
    ("stubtool --syntax-check site.yml &> /dev/null", "silent"),
    ("stubtool --syntax-check site.yml < in.txt", "silent"),
    ("stubtool wipe > /dev/null", "deny"),  # what it is stays what it is
    ("stubtool deploy.yml 2>&1", "ask"),
    # The word after the operator is the target, however it is written, and
    # a target that is not there ends the command all the same.
    ('stubtool --syntax-check site.yml > "my log.txt"', "silent"),
    ("stubtool --syntax-check site.yml >", "silent"),
    # An escaped operator is a literal character: it is an operand, and an
    # operand this grant does not account for leaves the line unproven.
    ("stubtool --syntax-check site.yml \\> out.txt", "ask"),
    # A redirection does not end a command; a separator does, and one after
    # a redirection still does.
    ("stubtool --syntax-check a.yml > out.txt && stubtool wipe", "deny"),
    ("stubtool --syntax-check a.yml >out& stubtool wipe", "deny"),
    ("echo 2 > f\nstubtool wipe", "deny"),
    # --- a command inside a substitution or subshell is still a command -----
    ("echo $(stubtool wipe)", "deny"),
    ("echo $(stubtool --syntax-check a.yml)", "silent"),
    ("VAR=$(stubtool wipe)", "deny"),
    ("cat <(stubtool wipe)", "deny"),
    ("(stubtool wipe)", "deny"),
    ("(cd /srv && stubtool wipe)", "deny"),
    ("echo $(date)", "silent"),  # substitution of something ungated
    ("stubtool --syntax-check $(git rev-parse HEAD).yml", "silent"),
    # A quoted substitution never reaches the splitting above — it is still one
    # token — so it is read off the raw line instead, tracking quotes. Double
    # quotes and backticks run; single quotes do not.
    ('echo "$(stubtool wipe)"', "deny"),
    ("echo `stubtool wipe`", "deny"),
    ('stubtool --syntax-check "$(stubtool wipe)"', "deny"),
    ("echo '$(stubtool wipe)'", "silent"),  # literal: the shell runs nothing
    ("echo '`stubtool wipe`'", "silent"),
    # An escaped opener is a literal character too, and inside double quotes
    # escaping it is the *correct* spelling — so reading it as a substitution
    # would refuse the careful one and permit the careless-looking twin above.
    ('echo "\\`stubtool wipe\\`"', "silent"),
    ('echo "\\$(stubtool wipe)"', "silent"),
    ('echo "see \\`notes/x.md\\` and \\`--method\\`"', "silent"),
    ('echo "\\`stubtool wipe" `stubtool wipe`', "deny"),  # one escaped, one not
    # A heredoc fed to a *shell* is what runs, so it is judged; one fed to
    # another language is program text, and reading it as shell guesses wrong
    # in the direction that costs a refusal.
    ("bash <<'SH'\nstubtool wipe\nSH", "deny"),
    ("python3 - <<'PY'\nnote = \"see `stubtool wipe` for why\"\nPY", "silent"),
    ('python3 - <<\'PY\'\ns = s.replace("stubtool wipe", "x")\nPY', "silent"),
    ('echo "$(stubtool --syntax-check a.yml)"', "silent"),  # nothing gated inside
    ('echo "$(echo $(stubtool wipe))"', "deny"),  # parentheses are counted
    ('echo "no substitution here"', "silent"),
)


def run(cases: tuple[tuple[str, str], ...], tools: dict[str, Tool], label: str) -> int:
    failures = 0
    for command, expected in cases:
        verdict = decide_bash(command, tools)
        got = verdict[0] if verdict else "silent"
        if got != expected:
            failures += 1
            print(f"FAIL  got {got:<7} want {expected:<7} {command!r}")
    print(f"{len(cases) - failures}/{len(cases)} {label} cases passed")
    return failures


def uncovered_rules() -> int:
    """Report rules and grants no case can reach. Intent nobody checks is
    intent nobody has.

    This is the mechanical half of "add a case for every rule you add": a rule
    that fires for nothing is either dead — a path or flag spelled wrong — or
    simply untested, and both look identical from the outside. Grants are held
    to the same bar for the failure that is easier to miss: an unreached grant
    over-prompts rather than under-prompts, so nothing goes wrong loudly and
    the safe shape you declared may never have worked at all.
    """
    global AUDIT
    AUDIT = set()
    try:
        for cases, tools in ((CASES, TOOLS), (ENGINE_CASES, registry(STUB, STUBCLI, STUBALWAYS))):
            for command, _ in cases:
                decide_bash(command, tools)
        all_tools = (*TOOLS.values(), STUB, STUBCLI, STUBALWAYS)
        declared: set[Rule | Grant] = {rule for tool in all_tools for rule in tool.rules}
        declared |= {grant for tool in all_tools for grant in tool.grants or ()}
        missing = declared - AUDIT
    finally:
        AUDIT = None
    for item in sorted(missing, key=lambda i: (i.path, getattr(i, "verdict", ""))):
        kind = "rule" if isinstance(item, Rule) else "grant"
        flags = "".join(f" {flag}" for flag in sorted(getattr(item, "flags", None) or ()))
        path = " ".join(item.path) or "(any)"
        print(f"UNCOVERED  no case reaches {kind} {path}{flags}")
    print(f"{len(declared) - len(missing)}/{len(declared)} rules and grants covered")
    return len(missing)


VERDICTS = frozenset({"deny", "ask", "allow"})


def liveness() -> int:
    """Is the guard alive? Structure and contract only — no behaviour cases.

    Everything here fails silently in production: Claude Code logs a hook it
    could not run and proceeds to the permission rules, which are broad by
    design. So this is the half that belongs in a lint, and it deliberately
    asserts nothing about *verdicts* — those change with every project's
    registry, while these properties do not.
    """
    problems: list[str] = []

    if not os.access(__file__, os.X_OK):
        problems.append("not executable: Claude Code cannot run it as a hook")

    if not TOOLS:
        problems.append("the registry is empty: no tool would ever be judged")

    # Distinct tools, not registry keys: an alias would otherwise report
    # the same broken rule once per name it answers to.
    for tool in sorted({id(t): t for t in TOOLS.values()}.values(), key=lambda t: t.name):
        name = tool.name
        for rule in tool.rules:
            where = f"{name} rule {' '.join(rule.path) or '(any)'}"
            if rule.verdict not in VERDICTS:
                problems.append(
                    f"{where}: verdict {rule.verdict!r} is not one of {sorted(VERDICTS)}"
                )
            if not rule.reason.strip():
                problems.append(f"{where}: no reason, so a prompt would say nothing")
            if rule.verdict == "allow" and tool.grants is None and not rule.flags:
                problems.append(
                    f"{where}: an unconditional allow on a tool with no "
                    "grants waives the sandbox for the whole tool"
                )
        if tool.gated_verdict is not None:
            if tool.gated_verdict not in VERDICTS:
                problems.append(
                    f"{name}: gated_verdict {tool.gated_verdict!r} is not one of {sorted(VERDICTS)}"
                )
            if not tool.gated_reason.strip():
                problems.append(
                    f"{name}: gated_verdict with no gated_reason, so "
                    "the prompt or refusal would say nothing"
                )
        for grant in tool.grants or ():
            if not (grant.path or grant.operands or grant.require_any or grant.flag_values):
                problems.append(
                    f"{name} grant: matches everything, so the tool is not gated at all"
                )

    # The contract, end to end: a payload in, a well-formed answer out.
    payloads: tuple[tuple[dict[str, object], str], ...] = (
        ({"tool_name": "Bash", "tool_input": {"command": "true"}}, "a bash call"),
        ({"tool_name": "Read", "tool_input": {"file_path": "x"}}, "a non-bash call"),
        ({}, "an empty payload"),
    )
    for payload, label in payloads:
        try:
            verdict = decide(
                str(payload.get("tool_name", "")), cast(dict, payload.get("tool_input") or {})
            )
        except Exception as exc:  # noqa: BLE001 — any failure here is the finding
            problems.append(f"{label} raised {exc!r} instead of returning a verdict")
            continue
        if verdict is not None and (
            not isinstance(verdict, tuple) or len(verdict) != 2 or verdict[0] not in VERDICTS
        ):
            problems.append(f"{label} returned {verdict!r}, not None or (verdict, reason)")

    for problem in problems:
        print(f"DEAD  {problem}")
    tools = set(TOOLS.values())
    gated = [t for t in tools if t.rules or t.grants or t.gated_verdict]
    declared = sum(len(t.rules) + len(t.grants or ()) for t in gated)
    print(
        f"liveness: {len(gated)} gated tools, {declared} rules and grants, "
        f"{len(tools) - len(gated)} wrappers, "
        f"{'ok' if not problems else 'BROKEN'}"
    )
    return len(problems)


# --- the secret check ------------------------------------------------------
# Two questions, and they fail differently. Whether a line is a commit at all
# is the one that decides whether anything is read; whether text carries a
# secret is the one that decides the verdict. A wrong answer to the first is
# a refusal of something harmless, which is why `git log --grep commit` is
# here.

# Split so that this file does not itself read as a credential. The agent may
# read the guard, and does; a transcript quoting it then trips the scan in
# `host/archive/scan.sh` and blocks the whole archive.
# see docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose
BEGIN = "-----BEGIN "
# The body is 48 characters, deliberately over the 32 the shape wants: a
# fixture short of the threshold would make the shape case below pass for the
# wrong reason.
FAKE_KEY = BEGIN + "OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAA\n"
FAKE_LOGIN = '{"claudeAiOauth": {"accessToken": "sk-live-9d4f2a77c1e05b83aa61"}}'  # gitleaks:allow — selftest fixture, not a credential

# Which tree the scan reads: every gated verb on the line, with the directory
# in effect when *it* runs. The first case is the ordinary one and the rest are
# the ways a command moves without the session moving with it; `None` means
# unproven, which refuses.
GATED_COMMAND_CASES: tuple[tuple[str, tuple[tuple[str, str], ...] | None], ...] = (
    ("git commit -m x", (("commit", "/repo"),)),
    ("git push origin main", (("push", "/repo"),)),
    ("cd /tmp/w && git commit -m x", (("commit", "/tmp/w"),)),
    ("(cd /tmp/w && git commit -m x)", (("commit", "/tmp/w"),)),
    ("{ cd /tmp/w && git commit -m x; }", (("commit", "/tmp/w"),)),
    ("pushd /tmp/w && git commit -m x", (("commit", "/tmp/w"),)),
    ("git -C /tmp/w commit -m x", (("commit", "/tmp/w"),)),
    ("env -C /tmp/w git commit -m x", (("commit", "/tmp/w"),)),
    ("sudo git -C /tmp/w commit -m x", (("commit", "/tmp/w"),)),
    ("cd /a && cd /b && git commit -m x", (("commit", "/b"),)),
    ("cd /tmp/w && git -C /other commit -m x", (("commit", "/other"),)),
    # Ordinary work inside the repository: a subdirectory is the same tree.
    ("cd notes && git commit -m x", (("commit", "/repo/notes"),)),
    ("cd .. && git commit -m x", (("commit", "/"),)),
    # `-C` after the subcommand is reuse-message, not a directory.
    ("git commit -C HEAD~1 -m x", (("commit", "/repo"),)),
    # More than one verb on a line: each carries its own directory, and the
    # first does not decide for the rest.
    (
        "git commit -m a && cd /tmp/w && git commit -m b",
        (("commit", "/repo"), ("commit", "/tmp/w")),
    ),
    ("git commit -m a && git -C /tmp/w commit -m b", (("commit", "/repo"), ("commit", "/tmp/w"))),
    ("git push && cd /tmp/w && git commit -m b", (("push", "/repo"), ("commit", "/tmp/w"))),
    (
        "git tag -a v1 -m a && cd /tmp/w && git commit -m b",
        (("tag", "/repo"), ("commit", "/tmp/w")),
    ),
    ("git commit -m a; cd /tmp/w; git commit -m b", (("commit", "/repo"), ("commit", "/tmp/w"))),
    ("git -C /clean commit -m a && git commit -m b", (("commit", "/clean"), ("commit", "/repo"))),
    # An ungated verb does not stop the walk.
    ("git log && cd /tmp/w && git commit -m b", (("commit", "/tmp/w"),)),
    ("git status && cd /tmp/w && git commit -m x", (("commit", "/tmp/w"),)),
    # …and what follows the last verb cannot decide anything for it.
    ("git commit -m x && cd /tmp", (("commit", "/repo"),)),
    ("git commit -m x && git -C /other log", (("commit", "/repo"),)),
    ("cd /tmp/w && git commit -m x && cd /elsewhere", (("commit", "/tmp/w"),)),
    # Only a shell can answer these, so nothing is claimed about them.
    ("cd $D && git commit -m x", None),
    ('cd "$(cat p)" && git commit -m x', None),
    ("cd - && git commit -m x", None),
    ("cd && git commit -m x", None),
    ("git --git-dir=/x/.git commit -m x", None),
    ("git --work-tree=/x commit -m x", None),
    ("GIT_DIR=/x/.git git commit -m x", None),
    ("GIT_WORK_TREE=/x git commit -m x", None),
    ("env GIT_DIR=/x/.git git commit -m x", None),
    ("export GIT_DIR=/x/.git; git commit -m x", None),
    ("GIT_DIR=/x/.git GIT_WORK_TREE=/x git push origin main", None),
    # An assignment that does not move git is not a reason to refuse.
    ("FOO=1 git commit -m x", (("commit", "/repo"),)),
    ("export FOO=1; git commit -m x", (("commit", "/repo"),)),
)

# Which tree a commit reaches, spelling by spelling. The wrong answer in one
# direction refuses a commit that carries nothing and keeps refusing; in the
# other it reads less than the commit records, which is the failure this whole
# section exists to prevent. So both are here.
COMMIT_SPAN_CASES: tuple[tuple[str, tuple[str, ...]], ...] = (
    # The index, and nothing else, is what these record.
    ("git commit", (INDEX,)),
    ("git commit -m x", (INDEX,)),
    ("git commit -mx", (INDEX,)),
    ("git commit --message=x", (INDEX,)),
    ("git commit --message x", (INDEX,)),
    ("git commit -F notes.txt", (INDEX,)),
    ("git commit -q -s --no-verify -m x", (INDEX,)),
    ("git commit -sm x", (INDEX,)),
    ("git commit --amend -m x", (INDEX,)),
    ("git commit --", (INDEX,)),
    # An optional-value short takes the rest of its own token and no more,
    # so the next token is still read as what it is.
    ("git commit -uno -m x", (INDEX,)),
    ("git commit -S -m x", (INDEX,)),
    # What an option takes is its value, not a pathspec, however it reads.
    ("git commit -m clean.txt", (INDEX,)),
    ("git commit --author name -m x", (INDEX,)),
    ("git commit --trailer Sign-off -m x", (INDEX,)),
    # Past the index, where reading the working tree is the right span and
    # an index-only read would miss what the commit records.
    ("git commit -a -m x", (WORKTREE,)),
    ("git commit --all -m x", (WORKTREE,)),
    ("git commit -am x", (WORKTREE,)),
    ("git commit -sam x", (WORKTREE,)),
    ("git commit -p -m x", (WORKTREE,)),
    ("git commit -m x clean.txt", (WORKTREE,)),
    ("git commit -m x -- clean.txt", (WORKTREE,)),
    ("git commit -i -m x clean.txt", (WORKTREE,)),
    ("git commit -o clean.txt -m x", (WORKTREE,)),
    ("git commit --only -m x clean.txt", (WORKTREE,)),
    ("git commit --pathspec-from-file=list -m x", (WORKTREE,)),
    # Not understood is not narrowed: an option or a letter this parse does
    # not know keeps the span every commit had before it existed.
    ("git commit --brand-new-flag -m x", (WORKTREE,)),
    ("git commit -X -m x", (WORKTREE,)),
    ("git commit - -m x", (WORKTREE,)),
    # A redirection is punctuation, not a pathspec: `2>&1` arrives as the bare
    # words `2` and `1`, and reading the first as a pathspec takes the wide
    # span on the spelling used on most commands.
    ("git commit -m x 2>&1", (INDEX,)),
    ("git commit -m x > /dev/null", (INDEX,)),
    ("git commit -m x 2>/dev/null", (INDEX,)),
    ("git commit -m x >>log 2>&1", (INDEX,)),
    ("git commit -m x &> /dev/null", (INDEX,)),
    ("git commit -m x < msg.txt", (INDEX,)),
    ("git commit -m x 2>&1 | tee log", (INDEX,)),
    # What the redirection hides must still be read: a real pathspec beside
    # one is a pathspec.
    ("git commit -m x clean.txt 2>&1", (WORKTREE,)),
    ("git commit -a -m x > /dev/null", (WORKTREE,)),
    # Adjacency is what tells an fd from an operand, and the lexer has
    # thrown it away by the time a token is a token — so this is decided on
    # the raw line. `2> f` redirects; `-m 2 > f` commits the message `2`.
    ("git commit -m 2 > log", (INDEX,)),
    ("git commit -m x 2 > log", (WORKTREE,)),
    # An escaped operator is a literal one, so it stays an operand — and an
    # operand widens, which is the direction a mistake here must take.
    ("git commit -m x \\> log", (WORKTREE,)),
    # Each commit on a line answers for itself, like its directory does.
    ("git commit -m a && git commit -a -m b", (INDEX, WORKTREE)),
    ("git commit -a -m a && git commit -m b", (WORKTREE, INDEX)),
    # The other gated acts have no span of their own: what they carry is not
    # a diff at all.
    ("git push", ("",)),
    ("git tag -a v1 -m x", ("",)),
    ("git notes add -m x", ("",)),
)

# What the refusal says when the span went wide. The span itself is proved
# above; this is only the sentence, and it is here because a verdict without
# the token leaves its reader nothing to act on.
COMMIT_WIDENED_CASES: tuple[tuple[str, str], ...] = (
    ("git commit -m x", ""),
    ("git commit -a -m x", "`-a` reaches past the index into the tracked working tree"),
    ("git commit -sam x", "`-sam` reaches past the index into the tracked working tree"),
    (
        "git commit -m x clean.txt",
        "`clean.txt` reaches past the index into the tracked working tree",
    ),
    (
        "git commit -m x -- clean.txt",
        "`clean.txt` reaches past the index into the tracked working tree",
    ),
    # Not understood is said as not understood: the wide read is caution
    # here, not a claim about what the commit records.
    (
        "git commit --brand-new-flag -m x",
        "`--brand-new-flag` is not a spelling this parse knows, so the span every "
        "commit had before it is kept rather than guessed at",
    ),
    (
        "git commit -X -m x",
        "`-X` is not a spelling this parse knows, so the span every commit had "
        "before it is kept rather than guessed at",
    ),
)

MESSAGE_FILE_CASES: tuple[tuple[str, tuple[str, ...] | None], ...] = (
    ("git commit -F notes.txt", ("notes.txt",)),
    ("git commit --file=notes.txt", ("notes.txt",)),
    ("git commit --file notes.txt", ("notes.txt",)),
    ("git tag -a v1 -F notes.txt", ("notes.txt",)),
    ("git notes add -F notes.txt", ("notes.txt",)),
    ("sudo git commit -F notes.txt", ("notes.txt",)),
    ("sh -c 'git commit -F notes.txt'", ("notes.txt",)),
    ("git commit -m wip", ()),
    ("git commit -F -", ()),  # the heredoc: already in the command
    ("grep -F pattern file.txt", ()),  # not a commit at all
    ("git commit -m x && grep -F pattern file.txt", ()),  # a different segment
    ("git log --grep commit -F x", ()),  # neither commit nor tag
    # No file is named, and the escaped backticks must not manufacture one.
    ('git -C /tmp/probe26 commit -q -m "subject with a \\`backtick\\` word"', ()),
    ('git commit -m "see \\`notes/x.md\\`"', ()),
    # Unparseable is not the empty answer, and collapsing the two here is what
    # let the wrong sentence ship.
    ("""git commit -m "$(echo 'x)\"""", None),
)

# Which of the three sentences a refusal carries, asserted rather than assumed.
# `/` exists, is small, and cannot be read as text — an unreadable file with
# no fixture to ship.
MESSAGE_CAUSE_CASES: tuple[tuple[str, str | None], ...] = (
    ("git commit -m wip", None),
    ('git commit -m "see \\`notes/x.md\\`"', None),
    ("git commit -F /no/such/message/file", None),  # git fails on it too
    ("git commit -F /", UNREADABLE),
    ("""git commit -m "$(echo 'x)\"""", UNPARSEABLE),
)

COMMIT_PATH_CASES: tuple[tuple[str, str | None], ...] = (
    ("git commit -m wip", "commit"),
    ("git commit --amend", "commit"),
    ("git -C /home/agent/agent commit -m x", "commit"),
    ("sudo git commit -m x", "commit"),
    ("git push", "push"),
    ("git tag -a v1 -m x", "tag"),
    ("git notes add -m x", "notes"),
    ("git notes append -m x", "notes"),
    ("git tag -s v1 -m x", "tag"),
    ("git tag -d v1", "tag"),  # naming the act is enough; the message is the risk
    ("git push origin main", "push"),
    ("env FOO=1 git push", "push"),
    ("sh -c 'git commit -m x'", "commit"),
    # The reason the trigger is the engine and not a regex: each of these
    # merely says "commit" or "push", and reading a staged diff for them
    # would refuse a harmless command whenever something else was staged.
    ("git log --grep commit", None),
    ("git log --oneline", None),
    ("echo commit", None),
    ("grep -r push .", None),
    ("ls", None),
    ("git status", None),
)

SECRET_CASES: tuple[tuple[str, str | None], ...] = (
    ("an ordinary diff line about a journal entry", None),
    ("+the key is in ~/.ssh, and I did not read it", None),
    # Verbatim outranks shape. FAKE_KEY whole matches BOTH layers — it is a
    # stored credential and it is armour-with-a-body — so the label it comes
    # back with is what proves the order.
    (FAKE_KEY.strip(), "the ssh private key, matched verbatim"),
    # A bare armour line is not a secret on either layer: a stored PEM would
    # otherwise turn its own closing marker into a match criterion.
    # see docs/boundary.md#the-shapes-and-the-rules-that-fire-on-prose
    (BEGIN + "OPENSSH PRIVATE KEY-----", None),
    ("-----END PRIVATE KEY-----", None),
    # git annotating a hunk with the nearest enclosing line, which here is the
    # constant naming the marker.
    ('@@ -12,7 +12,7 @@ ARMOUR_END = "-----END PRIVATE KEY-----"', None),
    # These two are in no credential here, so only the shape can catch them —
    # and the shape wants a body, so they carry one.
    (
        BEGIN + "RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy",
        "a private key block",
    ),
    (
        BEGIN + "EC PRIVATE KEY-----\nMHcCAQEEIBHkYhVYyJ6oQ2rMxFbLnpVvKgFxE1cD",
        "a private key block",
    ),
    # The same body behind a diff's `+` and behind a JSON-escaped newline,
    # because those are the two ways it actually arrives here: a push span is
    # a patch, and a transcript is JSONL, where a string cannot hold a real
    # newline.
    (
        "+" + BEGIN + "RSA PRIVATE KEY-----\n+MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy",
        "a private key block",
    ),
    (
        BEGIN + "RSA PRIVATE KEY-----\\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy",
        "a private key block",
    ),
    # Prose about a key, the armour pair a tool holds in order to rebuild a
    # PEM, and that pair on the `-` side of the diff that removes it — the
    # last is why a header-alone rule cannot be escaped once it has fired:
    # taking the constant out is itself refused.
    (
        "the vault refuses a value starting with a hyphen, so "
        + BEGIN
        + "PRIVATE KEY----- cannot be stored as it stands",
        None,
    ),
    (
        'ARMOUR_TOP = "' + BEGIN + 'PRIVATE KEY-----"\nARMOUR_END = "-----END PRIVATE KEY-----"',
        None,
    ),
    (
        '-ARMOUR_TOP = "' + BEGIN + 'PRIVATE KEY-----"\n-ARMOUR_END = "-----END PRIVATE KEY-----"',
        None,
    ),
    ("+token = ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2", "a github token"),
    ("+github_pat_" + "11ABCDEFG0abcdefghij_" * 2, "a github token"),
    ("+key: sk-ant-" + "api03-XXXXXXXXXXXXXXXXXXXX", "an anthropic key"),
    # A shape from SECRET_SHAPES_FILE and not from the code: the loop below
    # points that file at a fixture, so this case proves the path as well as
    # the pattern. Split like the two above so this file does not itself read
    # as a credential to the scan in `host/archive/scan.sh`.
    ("+secret: 1f916_sk_" + "A1b2C3d4E5f6G7h8I9j0", "a 1f916 key"),
    # …and the forum named in ordinary prose is not a secret. A shape that
    # fired on this would fire on most of what the agent writes.
    ("+posted the finding on 1f916 this morning", None),
    # Verbatim beats shape: this is the layer with no false positives, and
    # the one that catches a credential with no recognisable shape at all.
    (
        "+accessToken = sk-live-9d4f2a77c1e05b83aa61",  # gitleaks:allow
        "the Claude Code login, matched verbatim",
    ),
    ("+b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAA", "the ssh private key, matched verbatim"),
)


def secret_selftest() -> int:
    failures = 0
    for command, want_gated in GATED_COMMAND_CASES:
        got, _ = gated_commands(command, "/repo")
        # The span is asked for separately, below; these cases are about
        # which verb runs where.
        got_gated = None if got is None else tuple((a, d) for a, d, *_ in got)
        if got_gated != want_gated:
            failures += 1
            print(f"  gated-commands: {command!r} -> {got_gated}, wanted {want_gated}")
    for command, want_why in COMMIT_WIDENED_CASES:
        got, _ = gated_commands(command, "/repo")
        got_why = "" if not got else got[0][3]
        if got_why != want_why:
            failures += 1
            print(f"  commit-widened: {command!r} -> {got_why!r}, wanted {want_why!r}")
    for command, want_spans in COMMIT_SPAN_CASES:
        got, _ = gated_commands(command, "/repo")
        got_spans = None if got is None else tuple(s for _, _, s, _ in got)
        if got_spans != want_spans:
            failures += 1
            print(f"  commit-span: {command!r} -> {got_spans}, wanted {want_spans}")
    for command, want_files in MESSAGE_FILE_CASES:
        found = message_files(command)
        got_files = None if found is None else tuple(found)
        if got_files != want_files:
            failures += 1
            print(f"  message-files: {command!r} -> {got_files}, wanted {want_files}")
    for command, want_cause in MESSAGE_CAUSE_CASES:
        _, got_cause = message_file_text(command, ["/repo"])
        if got_cause != want_cause:
            failures += 1
            print(f"  message-cause: {command!r} -> {got_cause}, wanted {want_cause}")
    for command, want_path in COMMIT_PATH_CASES:
        verdict = decide_bash(command, COMMIT_PATH)
        got_path = verdict[1].split()[0] if verdict and verdict[0] == "deny" else None
        if got_path != want_path:
            failures += 1
            print(f"  commit-path: {command!r} -> {got_path}, wanted {want_path}")
    values = [("the ssh private key", v) for v in secret_strings(FAKE_KEY)]
    values += [("the Claude Code login", v) for v in secret_strings(FAKE_LOGIN)]
    # The cases run with SECRET_SHAPES_FILE pointed at a fixture, because one of
    # them is a shape this installation adds rather than one the code carries —
    # so what is proved is that the file is read at all, and from where.
    installed = "+secret: 1f916_sk_" + "A1b2C3d4E5f6G7h8I9j0"
    with tempfile.TemporaryDirectory() as scratch:
        listing = Path(scratch) / "secret-shapes.txt"
        listing.write_text(
            "# what this installation adds to the floor\n"
            "\n"
            "1f916_sk_[A-Za-z0-9]{16,}   # a 1f916 key\n"
        )
        was, globals()["SECRET_SHAPES_FILE"] = SECRET_SHAPES_FILE, str(listing)
        for text, want_scan in SECRET_CASES:
            got_scan = scan(text, values)
            if (got_scan or "") != (want_scan or "") and not (
                want_scan and got_scan and got_scan.startswith(want_scan)
            ):
                failures += 1
                print(f"  scan: {text[:40]!r} -> {got_scan}, wanted {want_scan}")
        globals()["SECRET_SHAPES_FILE"] = str(Path(scratch) / "absent.txt")
        without = scan(installed, values)
        globals()["SECRET_SHAPES_FILE"] = was
    # An absent file adds nothing, which is what a fresh installation has. Asked
    # of the case above, so a fixture that was never read cannot pass both.
    if without is not None:
        failures += 1
        print(f"  secret-shapes: an absent list still matched -> {without}")
    # The refusal must never carry the thing it refused.
    secret = "sk-live-9d4f2a77c1e05b83aa61"  # gitleaks:allow
    reason = scan("+accessToken = " + secret, values) or ""
    if secret in reason:
        failures += 1
        print("  scan: the reason quoted the secret it matched")
    # Too short to be a credential, and long enough to collide with prose.
    if scan("+short", [("x", "short")]) is not None:
        failures += 1
        print("  scan: matched a value under MIN_SECRET")
    # The exemption list is a parser whose silent failure *grants* exemptions,
    # the one direction a mistake here must never go. Read from a real file,
    # because the failure that matters is a path that does not resolve in the
    # image, and an unreadable list exempting everything is indistinguishable
    # from a list that happened to be empty.
    with tempfile.TemporaryDirectory() as scratch:
        listing = Path(scratch) / "vault-exempt.txt"
        listing.write_text(
            "# a comment line\n"
            "\n"
            "cloudflare-account-id   # an identifier, not a credential\n"
            "   spaced-key\n"
        )
        was, globals()["VAULT_EXEMPT"] = VAULT_EXEMPT, str(listing)
        parsed = vault_exempt()
        globals()["VAULT_EXEMPT"] = str(Path(scratch) / "absent.txt")
        absent = vault_exempt()
        globals()["VAULT_EXEMPT"] = was
    if parsed != frozenset({"cloudflare-account-id", "spaced-key"}):
        failures += 1
        print(f"  vault-exempt: parsed {sorted(parsed)}")
    if absent:
        failures += 1
        print("  vault-exempt: an unreadable list exempted something")
    # A line that still holds whitespace once its comment is gone is a note
    # nobody commented out, and exempting it would exempt nothing while
    # looking like it had worked.
    with tempfile.TemporaryDirectory() as scratch:
        listing = Path(scratch) / "vault-exempt.txt"
        listing.write_text("a note that lost its hash\nreal-key\n")
        was, globals()["VAULT_EXEMPT"] = VAULT_EXEMPT, str(listing)
        loose = vault_exempt()
        globals()["VAULT_EXEMPT"] = was
    if loose != frozenset({"real-key"}):
        failures += 1
        print(f"  vault-exempt: a note parsed as a key -> {sorted(loose)}")
    # And that the exemption reaches the comparison and not only the parser: a
    # list that parses perfectly and is then never consulted is the shape of a
    # mechanism that looks installed and does nothing.
    #
    # CREDENTIAL_FILES is emptied for the duration: this runs on the host as
    # well as in the build, and a selftest that reads the operator's own ssh key
    # into memory to prove something about a vault entry is doing more than it
    # was asked to.
    with tempfile.TemporaryDirectory() as scratch:
        cache = Path(scratch) / "cache"
        cache.mkdir()
        (cache / "open-identifier").write_text("a" * 32 + "\n")
        (cache / "real-secret").write_text("b" * 32 + "\n")
        listing = Path(scratch) / "vault-exempt.txt"
        listing.write_text("open-identifier  # an identifier, not a credential\n")
        keep = (VAULT_CACHE, VAULT_EXEMPT, CREDENTIAL_FILES)
        globals()["VAULT_CACHE"] = str(cache)
        globals()["VAULT_EXEMPT"] = str(listing)
        globals()["CREDENTIAL_FILES"] = ()
        compared = {v for _, v in credential_values()}
        (globals()["VAULT_CACHE"], globals()["VAULT_EXEMPT"], globals()["CREDENTIAL_FILES"]) = keep
    if "a" * 32 in compared:
        failures += 1
        print("  vault-exempt: an exempt entry was still compared")
    if "b" * 32 not in compared:
        failures += 1
        print("  vault-exempt: exempting one entry exempted another")
    # A line that does not compile refuses the act, naming the line. The
    # alternative — dropping it and comparing against the rest — is a floor with
    # a hole in it that answers exactly as a whole one does.
    with tempfile.TemporaryDirectory() as scratch:
        listing = Path(scratch) / "secret-shapes.txt"
        listing.write_text(
            "feed=[A-Za-z0-9_-]{16,}   # anchored on the parameter\n"
            "1f916_sk_[A-Za-z0-9   # an unclosed class\n"
        )
        was, globals()["SECRET_SHAPES_FILE"] = SECRET_SHAPES_FILE, str(listing)
        compiled, broken = file_shapes()
        refused = secret_in_commit_path("git commit -m 'an ordinary message'", "/repo") or ""
        globals()["SECRET_SHAPES_FILE"] = was
    if len(compiled) != 1 or len(broken) != 1:
        failures += 1
        print(f"  secret-shapes: {len(compiled)} compiled and {broken} would not")
    if "line 2" not in refused:
        failures += 1
        print(f"  secret-shapes: a line that does not compile did not refuse -> {refused[:60]!r}")

    # Summed outside the f-string: this image's python predates an expression
    # spanning lines inside one.
    total = (
        len(COMMIT_PATH_CASES)
        + len(SECRET_CASES)
        + len(MESSAGE_FILE_CASES)
        + len(MESSAGE_CAUSE_CASES)
        + len(GATED_COMMAND_CASES)
        + len(COMMIT_SPAN_CASES)
        + len(COMMIT_WIDENED_CASES)
        + 10
    )
    print(f"{total} secret cases, {'ok' if not failures else str(failures) + ' FAILED'}")
    return failures


def selftest() -> int:
    failures = liveness()
    failures += run(CASES, TOOLS, "registry")
    failures += run(ENGINE_CASES, registry(STUB, STUBCLI, STUBALWAYS), "engine")
    failures += uncovered_rules()
    failures += secret_selftest()
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    if "--liveness" in sys.argv[1:]:
        sys.exit(1 if liveness() else 0)
    sys.exit(main())
