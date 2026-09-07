# The agent's runner. Every recipe here runs on the host — the container is
# what these operate, never what they run in.

# The oldest `just` that can read this file, so an older one says which version
# it wants instead of a parse error. `verify` reads the number back out of it.
# see docs/configuration.md#what-justs-own-settings-buy
set minimum-version := '1.55.0'

# ===========================================================================
# Who the agent is. One value is required — AGENT_NAME — and everything below
# is derived from it; each step may be overridden in .env, and an override
# becomes the input to every step under it.
# see docs/configuration.md#one-name-everything-derived
agent_name := env_var_or_default("AGENT_NAME", "agent")
# Exported so host/verify/ can ask whether the tree names this installation.
export AGENT_NAME := agent_name

# The slug everything machine-readable is built from: the name, lowercased,
# with spaces closed up, because a unix account, a volume and an image tag
# cannot hold a capital or a space.
agent_user := env_var_or_default("AGENT_USER", lowercase(replace(agent_name, " ", "-")))
export AGENT_USER := agent_user

# The agent's own namespace: what is genuinely the agent's is prefixed with its
# name, so a session reads BORGES_REPO and not a generic one. Dashes become
# underscores because a shell name cannot hold one.
agent_prefix := uppercase(replace(agent_user, "-", "_"))
export AGENT_PREFIX := agent_prefix

# What .env calls the agent's own values, re-exported under a plumbing name
# compose can reference: compose cannot dereference a computed name and `just`
# cannot export one, so this file is the one place that translates.
# see docs/configuration.md#one-name-everything-derived
export AGENT_REPO := env_var_or_default(agent_prefix + "_REPO", "")
export AGENT_GIT_NAME := env_var_or_default(agent_prefix + "_GIT_NAME", agent_name)
export AGENT_GIT_EMAIL := env_var_or_default(agent_prefix + "_GIT_EMAIL", "")

# The agent's own domain, translated like the repository above it, and from
# there a build arg that renders the autoMode block in managed-settings.json.
# Empty tells the classifier the agent has no domain, which is better than
# telling it someone else's.
export AGENT_DOMAIN := env_var_or_default(agent_prefix + "_DOMAIN", "")

# The model a session runs on, rendered into managed settings at build so it
# holds for every kind of session and the agent cannot edit it. An alias, so
# a newer model of the same tier is picked up without an edit.
export AGENT_MODEL := env_var_or_default(agent_prefix + "_MODEL", "sonnet")

agent_home := env_var_or_default("AGENT_HOME", "/home" / agent_user)
export AGENT_HOME := agent_home

# The checkout, under the agent's home and named after it. The clone is given
# this path explicitly, so nothing about the repository's own name decides it.
repo := env_var_or_default(agent_prefix + "_REPO_DIR", agent_home / agent_user)
export AGENT_REPO_DIR := repo

# The volume that holds everything the agent owns. The Compose project name
# prefixes container names only — the volume is named explicitly in
# compose.yaml, so it never depends on where this repository sits.
export AGENT_VOLUME := env_var_or_default("AGENT_VOLUME", agent_user + "-home")

# Exported here because the environment outranks compose.yaml's own `name:`,
# and this machine sets COMPOSE_PROJECT_NAME per directory.
# see docs/configuration.md#composes-project-name-decides-where-the-volume-is-not
export COMPOSE_PROJECT_NAME := env_var_or_default("RUNNER_PROJECT", agent_user + "-runner")

# Quiet suppresses progress only — output and errors still print — and `just
# build` overrides it back to `auto`, the one place that wants a successful
# build's layer output.
# see docs/configuration.md#compose-narration-is-quiet-and-build-turns-it-back-on
export COMPOSE_PROGRESS := "quiet"
# ===========================================================================

# So a recipe reads its arguments as `$@` rather than as text spliced into its
# body: `just chat --force "a prompt, with commas"` needs the flag and the
# prompt to stay separate words.
set positional-arguments := true

# A recipe without a shebang echoes every line as it runs, comments included.
set ignore-comments := true

# .env reaches the recipes, not only compose: the budget guard runs on the
# host, so the percentages and ACCOUNT_BUDGET_GUARD have to be readable here.
# see docs/budget.md
set dotenv-load := true

# One session at a time, and one place that says where that is recorded:
# `run`, `chat` and the cron line `schedule` installs must all name the same
# file or the lock guards nothing. /tmp is spelled out rather than following
# TMPDIR, which cron does not set; the cache root below follows XDG_CACHE_HOME.
# see docs/configuration.md#the-lock-path-is-literal-the-cache-path-follows-xdg
export RUNNER_LOCK := env_var_or_default("RUNNER_LOCK", "/tmp" / agent_user + "-session.lock")

# One directory per agent, plain names inside it — two agents sharing a cache
# would invalidate each other's scan on every run. The root is a default for
# the names below, not a prefix they are forced through, which is what lets a
# test recipe point one file elsewhere without moving the rest.
# see docs/configuration.md#one-cache-directory-plain-names-inside-it
runner_cache := env_var_or_default("RUNNER_CACHE_DIR", cache_dir() / agent_user)
# The scan cache `collect` keys on a fingerprint of this volume's secrets.
export RUNNER_CACHE_DIR := runner_cache

export RUNNER_LAST_SESSION_ENDED_AT := env_var_or_default("RUNNER_LAST_SESSION_ENDED_AT", runner_cache / "last-session")
# The id of the last `chat` conversation, for --continue, and when that
# conversation ended — two different facts, and only the second is told to the
# agent (as {{PREFIX}}_LAST_CHAT_ENDED) so it can tell "nobody has spoken to me
# in three days" from "no session has run".
export RUNNER_LAST_CHAT_ID := env_var_or_default("RUNNER_LAST_CHAT_ID", runner_cache / "last-chat")
export RUNNER_LAST_CHAT_ENDED_AT := env_var_or_default("RUNNER_LAST_CHAT_ENDED_AT", runner_cache / "last-chat-ended")
export RUNNER_SNAPSHOT_PUBLISHED_AT := env_var_or_default("RUNNER_SNAPSHOT_PUBLISHED_AT", runner_cache / "status-published")
export RUNNER_SNAPSHOT_LOCK := env_var_or_default("RUNNER_SNAPSHOT_LOCK", "/tmp" / agent_user + "-status-publish.lock")

# What `deploy` takes before it writes the archive's `config` branch, for the
# reason the snapshot lock exists: two writers racing between reading that
# branch and pushing over it.
export RUNNER_CONFIG_LOCK := env_var_or_default("RUNNER_CONFIG_LOCK", "/tmp" / agent_user + "-config-backup.lock")

# One durable record per archived session — when it ran, what it was, what it
# spent, which commits it made, and which runner built its container. Written
# once, when every field in it is final, and never rewritten; `just records`
# writes them here and publishes them to the archive's `cache` branch.
# see docs/monitor.md#one-record-per-session
export RUNNER_RECORDS_DIR := env_var_or_default("RUNNER_RECORDS_DIR", runner_cache / "records")

# What the sealing was done against — the three source refs and when. It stays
# on this host rather than on the branch, which is written once per file: this
# is the one file that would change on every run.
export RUNNER_RECORDS_STATE := env_var_or_default("RUNNER_RECORDS_STATE", runner_cache / "records-state.json")

# One writer per branch, as above.
export RUNNER_RECORDS_LOCK := env_var_or_default("RUNNER_RECORDS_LOCK", "/tmp" / agent_user + "-records-publish.lock")

# How the last unattended run ended, and — until a session actually starts —
# that nobody has been told about it yet. It also holds which wedged session
# has already been toasted: one record per run, keyed on that run's start.
# see docs/sessions.md#recovering-a-session-that-was-stopped
# see docs/schedule.md#the-wedge-alarm
export RUNNER_LAST_RUN := env_var_or_default("RUNNER_LAST_RUN", runner_cache / "last-run")

# Where cron writes what an unattended run printed. Named in the crontab line
# `schedule` installs, so a second agent on this host neither shares the log
# nor is mistaken for this one when `schedule` reads the line back.
export RUNNER_RUN_LOG := env_var_or_default("RUNNER_RUN_LOG", runner_cache / "run.log")

# The project root, which is not always this justfile's directory: the deployed
# checkout is a worktree inside the project, and its own copy of this file must
# compute the same archive and the same deployed path as the checkout above it.
root := if file_name(justfile_directory()) == "deployed" { parent_directory(justfile_directory()) } else { justfile_directory() }
# Exported because the scripts need this answer and cannot compute it:
# host/lib/root.sh finds the checkout it was shipped in, which for the deployed
# one is `deployed/` itself. `deploy` and `listen --live` both mean this one.
export RUNNER_ROOT := root

# Where the archive is, and the only place that decides it — five copies of a
# path is four that stay behind on the day it moves. Inside the project and
# gitignored, as `deployed/` is, so a demonstration anyone can clone arranges
# nothing outside its own directory; set AGENT_ARCHIVE to keep it elsewhere.
# A relative value is taken from this checkout, not from wherever `just` runs:
# cron runs it from `deployed/`, and `../archive` must name one place.
# see docs/archive.md
archive_setting := env_var_or_default("AGENT_ARCHIVE", "")
export AGENT_ARCHIVE := if archive_setting == "" { root / "archive" } else if archive_setting =~ '^/' { archive_setting } else { root / archive_setting }

# Where the deployed checkout is — the one cron runs `just run` from. A git
# worktree of the `deployed` branch, inside this project, gitignored, and moved
# only by `just deploy`. It exists because cron reads whatever tree it is
# pointed at, committed or not.
# see docs/release.md#where-the-deployed-checkout-lives
deployed_setting := env_var_or_default("RUNNER_DEPLOYED", "")
export RUNNER_DEPLOYED := if deployed_setting == "" { root / "deployed" } else if deployed_setting =~ '^/' { deployed_setting } else { root / deployed_setting }

# Where the drift audit keeps its world — its clone of the archive's mirror of
# the agent's memory, the two anchors, the reports and the log. Inside the
# project and gitignored, as the two above are, and made by `just drift-audit`
# on its first run.
# see docs/monitor.md#where-the-audit-keeps-its-state
monitor_setting := env_var_or_default("RUNNER_MONITOR", "")
export RUNNER_MONITOR := if monitor_setting == "" { root / "monitor" } else if monitor_setting =~ '^/' { monitor_setting } else { root / monitor_setting }

# Whether this justfile is the deployed one. The live recipes forward to the
# deployed checkout unless they are already in it, and this is where the
# forwarding stops. Exported rather than tested in the scripts: it compares the
# path `just` resolved against the one it derived, where a script re-deriving
# from its own location would answer differently if either were a symlink.
# see docs/sessions.md
export RUNNER_IS_DEPLOYED := if justfile_directory() == RUNNER_DEPLOYED { "yes" } else { "no" }

# The two image tags, named once. `build` produces the candidate; `deploy`
# builds the deployed one from the deployed checkout and then points the
# candidate at it, so the candidate is never behind what is live. compose.yaml
# cannot read these, so its `image:` default is a copy of the deployed name,
# and `verify` compares the two, since a copy nobody compares is one that drifts.
# see docs/release.md
export RUNNER_IMAGE_CANDIDATE := agent_user + "-agent:candidate"
export RUNNER_IMAGE_DEPLOYED := agent_user + "-agent:deployed"

# Whose words these are, in front of every message `just chat` seeds and every
# prompt `run` writes. The operator could have typed it themselves but did not
# — the runner did, and rule 1 rests on that line being visible. The marker is
# matched literally in transcripts already written, so changing OPERATOR_NAME
# on a running installation stops `chat --continue` finding a conversation from
# before the change.
# see docs/configuration.md#the-operator-marker-is-matched-literally
operator_name := env_var_or_default("OPERATOR_NAME", "Operator")
# Exported for the same reason AGENT_NAME is: host/verify/ searches the tree
# for the names this installation was configured with.
export OPERATOR_NAME := operator_name

# host/session/last-chat.sh finds a conversation in the volume by looking for
# exactly what `chat` wrote.
export OPERATOR_SAYS := "[from " + operator_name + ", not from the runner]"

# The other half of the same line: host/session/transcript.jq reads it back to
# decide whose name to print over a message — without it, an unattended start
# is displayed as the operator while its own first words say it is not them.
export RUNNER_SAYS := "[automated start — from the runner, not from " + operator_name + "]"

# How Claude Code spells that path when it files a transcript: the directory
# with every `/` turned into `-`. Computed, never typed — a copy spelled by
# hand goes on naming the old checkout after it moves, which reads as "no
# transcripts yet" rather than as an error.
export AGENT_PROJECT_DIR := replace(repo, "/", "-")

# ===========================================================================
# The recipes. Every one is a doc line, its declared arguments, and one `exec`
# into a script under host/ — the directory the [group] names. Nothing below
# decides anything: what a command does is in the script, and this is the table
# of contents `just --list` prints.
#
# The arguments are declared, so `just` parses them and `just --usage <recipe>`
# prints them. Each is exported and reaches its script as an environment
# variable of the same name; a flag carries `yes` and its absence `no`, one
# vocabulary across every script. `--cooldown` and the two counts carry a value.
#
# Three recipes keep `*ARGS` because their shape cannot be declared: `chat`,
# whose message is free text that may begin with a dash; `collect`, whose
# --approve and --redact take two values each and repeat; and `test-container`,
# where everything after the flag is a command with options of its own.
# ===========================================================================

# private, because bare `just` already runs it. Listed, it offers a name whose
# only effect is what typing nothing does.
[private]
default:
    @just --list
    @echo
    @echo "just --usage <recipe> shows its options, with what each one does."


# --------------------------------------------------------------- session ---

# no-exit-message, because cron calls this every minute under --cooldown and
# just's own "Recipe `run` failed with exit code 75" on each skip is 1440 lines
# a day into a log nothing rotates. Every path that exits non-zero says why
# first, and the exit code reaches cron either way.
[doc("One unattended session — --listen watches, --wait queues, --force ignores the lock")]
[group("session")]
[no-exit-message]
[arg("force", long, value="yes", help="start one beside a running session, after asking")]
[arg("listen", long, value="yes", help="render the transcript as it is written")]
[arg("wait", long, value="yes", help="queue behind the running session instead of standing down")]
[arg("ignore_budget", long="ignore-budget", value="yes", help="start even when the account is over its allowance")]
[arg("cooldown", long, pattern='\d+', help="minutes that must have passed since the last session ended")]
run $force="no" $listen="no" $wait="no" $ignore_budget="no" $cooldown="0":
    @exec host/session/run.sh

[doc("A conversation with the agent — waits for a running session; --continue resumes the last one, --force joins anyway")]
[group("session")]
[arg("ARGS", help="[--force] [--continue] your message")]
chat *ARGS:
    @exec host/session/chat.sh "$@"

[doc("A shell in the container, for bootstrap and looking around — --build first")]
[group("session")]
[arg("build", long, value="yes", help="build the candidate and look inside that instead of the deployed image")]
shell $build="no":
    @exec host/session/shell.sh

[doc("A container with no volume — an empty home every run, for rehearsing recovery; --build first")]
[group("session")]
[arg("ARGS", help="[--build] [command...]")]
test-container *ARGS:
    @exec host/session/test-container.sh "$@"

[doc("A running session from its first line, live — or the last one's tail, or all of it; --live never closes, --remote serves it to the tailnet")]
[group("session")]
[arg("all", long, value="yes", help="the whole transcript, with no ceiling on what is read")]
[arg("wait", long, value="yes", help="wait for a session when none is running, then give the prompt back")]
[arg("live", long, value="yes", help="as --wait, and wait again for the next one; never closes")]
[arg("remote", long, value="yes", help="serve the live view on the tailnet, for any device on it — implies --live, and ends with this window")]
[arg("summary", long="no-summary", value="no", help="leave out what the session cost when it ends")]
[arg("n", pattern='\d+', help="how many messages of a finished session to show")]
listen $all="no" $wait="no" $live="no" $remote="no" $summary="yes" $n="20":
    @exec host/session/listen.sh

[doc("Read one transcript whole — by its number in `just sessions`, or by its own id")]
[group("session")]
[arg("id", help="a row of the last 'just sessions' — 1 to 3 digits — or a session or subagent id, hex and four characters or more")]
[arg("subagent", long, help="read the K-th subagent that session spawned instead; the read lists them")]
[arg("full", long, value="yes", help="a tool call's whole payload rather than its first line")]
read $id $subagent="" $full="no":
    @exec host/session/read.sh

[doc("Whether a session is running, what it has spent, whether scheduling is on, what the gate is holding")]
[group("session")]
status:
    @exec host/session/status.sh


# --------------------------------------------------------------- archive ---

[doc("Archive transcripts to the private archive repo — add --push to publish")]
[group("archive")]
[arg("ARGS", help="[--push] [--held] [--approve <what> <why>]... [--redact <what> <why>]...")]
collect *ARGS:
    @exec host/archive/collect.sh "$@"

# The one forwarding guard left in the index. Every other live recipe carries
# it inside its script, but host/archive/publish-status.sh has two callers
# already where they mean to be — `run` on every wake-up, before it forwards,
# and `chat` when a session ends — and a guard in the script would ask them the
# "not deployed, run there anyway?" question in the middle of a heartbeat.
[doc("Put the host's half of the status page where the dashboard can read it")]
[group("archive")]
[arg("now", long, value="yes", help="publish now, ignoring the ten-minute floor")]
publish-status $now="no":
    #!/usr/bin/env bash
    set -uo pipefail
    . host/lib/root.sh
    . host/lib/deployed.sh
    typed=(); typed_flag --now "$now"
    [ "$RUNNER_IS_DEPLOYED" = yes ] || forward_to_deployed publish-status ${typed[@]+"${typed[@]}"}
    exec host/archive/publish-status.sh ${typed[@]+"${typed[@]}"}

# A failure here is the archive's own and it says so in its own words.
[doc("What the archive holds, newest first — `just read <number>` opens one")]
[group("archive")]
[no-exit-message]
[arg("all", long, value="yes", help="every session, not the newest screenful")]
[arg("day", long, help="only sessions that started on that local day — 08-26, or 2026-08-26")]
sessions $all="no" $day="":
    @exec host/archive/sessions.sh

[doc("How the mirror is doing — is it running, is it current, was anything rewound")]
[group("archive")]
[no-exit-message]
mirror-status:
    @exec host/archive/mirror.sh

[doc("Clone the archive and set up the credentials its mirror workflow runs on")]
[group("archive")]
setup-archive:
    @exec host/archive/setup.sh


# --------------------------------------------------------------- monitor ---

[doc("Audit what moved in the agent's memory since the baseline — a Claude session, here, on your login")]
[group("monitor")]
[no-exit-message]
drift-audit:
    @exec host/monitor/drift-audit.sh

[doc("Move the baseline to the last audited commit — the ratchet, and it asks first")]
[group("monitor")]
drift-accept:
    @exec host/monitor/drift-accept.sh

[doc("The cumulative diff the reports are drawn from, with no agent in the way")]
[group("monitor")]
[arg("ARGS", help="[PATH...] limit the diff to these paths, as git diff takes them")]
drift-diff *ARGS:
    @exec host/monitor/drift-diff.sh "$@"

# no-exit-message: an archive with nothing mirrored yet is a state, not a
# defect, and the script says so in its own words.
[doc("What the audit stands on — the mirror, the two anchors, and the last runs")]
[group("monitor")]
[no-exit-message]
drift-status:
    @exec host/monitor/drift-status.sh

# The session ids cannot be declared and the two flags can, so this is the one
# recipe that mixes them. `just` passes every declared parameter as a
# positional argument too, ahead of them, so the two are shifted off and what
# reaches the script is ids.
[doc("What the archived sessions cost — one line each, or --by-day; -d N widens the window")]
[group("monitor")]
[no-exit-message]
[arg("by_day", long="by-day", value="yes", help="one line per day instead of one per session")]
[arg("days", long, short="d", pattern='\d+', help="how many of the archive's days to price; 0 is the default window — one day, ten with --by-day")]
[arg("ARGS", help="[SESSION-ID...] price those sessions wherever they sit in the archive, matched on the start of the id; no window applies")]
cost $by_day="no" $days="0" *ARGS:
    @shift 2 && exec host/monitor/cost.sh "$@"

# no-exit-message: an archive with nothing pushed, or a mirror that has never
# run, is a state and not a defect, and the script says so in its own words.
[doc("One durable record per archived session — every session end seals its own; --recheck audits them, --prove diffs the present commands against them")]
[group("monitor")]
[no-exit-message]
[arg("recheck", long, value="yes", help="re-derive every stored record and diff it against what is stored, writing nothing")]
[arg("prove", long, value="yes", help="render what sessions, read, tools and cost print today from the records alone, and diff")]
[arg("publish", long="no-publish", value="no", help="write the records here and push nothing to the archive")]
[arg("rewrite", long, help="replace one session's record, for a transcript a redact ruling changed after it sealed")]
records $recheck="no" $prove="no" $publish="yes" $rewrite="":
    @exec host/monitor/records.sh

# no-exit-message: a store with no records in it is a state and not a defect,
# and the script names the command that fills it.
[doc("What the agent has been doing, and whether that is changing — one screen from the sealed records; -d N narrows it to N whole days, --all gives every one a row")]
[group("monitor")]
[no-exit-message]
[arg("days", long, short="d", pattern='\d+', help="how many whole days back to report on, ending yesterday; 0 is everything the records hold, with four weeks in the weekly table")]
[arg("all", long, value="yes", help="a row for every day of the window, not the last seven")]
stats $days="0" $all="no":
    @exec host/monitor/stats.sh

[doc("Count tool calls per day in the archived session transcripts — one line per tool, or name tools for one line per day")]
[group("monitor")]
[no-exit-message]
[arg("days", long, short="d", pattern='\d+', help="how many of the archive's days to count; 0 is the default window — five days, ten when tools are named")]
[arg("ARGS", help="[TOOL...] transpose: one line per day, one column per named tool, in the order given")]
tools $days="0" *ARGS:
    @shift 1 && exec host/monitor/tools.sh "$@"


# --------------------------------------------------------------- release ---

[doc("Create .venv, install the pinned lint tooling, and make this installation's own configuration files")]
[group("release")]
[arg("restore", long, value="yes", help="take those files from the archive's config branch instead of from their examples")]
setup $restore="no":
    @exec host/release/setup.sh

[doc("ruff, mypy, shellcheck and check-auto-mode — the checks pre-commit runs")]
[group("release")]
lint:
    @exec host/release/lint.sh

[doc("Build the image as the candidate — nothing runs it until `just deploy`")]
[group("release")]
[arg("deployed", long, value="yes", help="tag the deployed image instead of the candidate; only the deployed checkout may")]
build $deployed="no":
    @exec host/release/build.sh

[doc("Go live — set the deployed checkout to HEAD and build the image from it; --diff patches, --state reports")]
[group("release")]
[arg("diff", long, value="yes", help="the patch between what is live and what would be, and change nothing")]
[arg("state", long, value="yes", help="what is live as parseable fields, and change nothing")]
deploy $diff="no" $state="no":
    @exec host/release/deploy.sh

[doc("Pin what the Dockerfile takes from outside — the base image's digest and Claude Code's version — as a diff to read")]
[group("release")]
[arg("image", long, value="yes", help="the base image only: resolve its tag to today's digest")]
[arg("claude", long, value="yes", help="Claude Code only: the version npm publishes as latest")]
pin $image="no" $claude="no":
    @exec host/release/pin.sh $([ "$image" = yes ] && echo --image) $([ "$claude" = yes ] && echo --claude)


# -------------------------------------------------------------- schedule ---

# No pattern on --cron or --cooldown, unlike `run --cooldown`: a pattern is
# checked against the default as well, and the default of both is empty — which
# is how this recipe tells "not said" from a value. schedule.sh checks the
# digits itself. An attribute run may not be interrupted by a comment, which is
# why this sits above the whole block.
[doc("What is scheduled — --enable installs or resumes, --pause holds, --disable removes")]
[group("schedule")]
[arg("enable", long, value="yes", help="install the entry, or bring a paused one back")]
[arg("pause", long, value="yes", help="comment the entry out where it stands")]
[arg("disable", long, value="yes", help="remove the entry altogether")]
[arg("relocate", long, value="yes", help="point the installed entry at the deployed checkout")]
[arg("state", long, value="yes", help="what is scheduled as parseable fields")]
[arg("cron", long, help="the five cron fields, quoted: \"M H D M W\"")]
[arg("cooldown", long, help="minutes since the last session ended before a wake-up starts one")]
schedule $enable="no" $pause="no" $disable="no" $relocate="no" $state="no" $cron="" $cooldown="":
    @exec host/schedule/schedule.sh


# ---------------------------------------------------------------- verify ---

[doc("Prove the mechanisms that fail silently when they are wrong — --build first")]
[group("verify")]
[arg("build", long, value="yes", help="build the candidate first, so what is proved is what you changed")]
[arg("deployed", long, value="yes", help="prove what cron runs instead of the candidate")]
verify $build="no" $deployed="no":
    @exec host/verify/verify.sh

# There is deliberately no recipe that removes the volume. The agent's memory
# lives there, deletion is not recoverable, and a one-word footgun is how that
# happens by accident. Do it by hand if you ever mean it.
# see docs/configuration.md#there-is-no-recipe-that-removes-the-volume
