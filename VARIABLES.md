# Variables

A variable is named for **what it is about**, not for what reads it. Four
namespaces, and the rule that separates them is the whole of the scheme:

| prefix | what it is about | who reads it |
| --- | --- | --- |
| `<NAME>_*` | things that are genuinely **the agent's** — its repository, its identity, facts about its own sessions | the agent, and the image scripts acting for it |
| `AGENT_*` | **this agent's** things that the runner holds and the agent never sees | the host, and the image build |
| `RUNNER_*` | **the runner's** machinery — identical whichever agent ran here | the host only |
| a tool's own | whatever that tool already calls it | that tool |

`<NAME>` is the agent's name, uppercased, with dashes as underscores:
`AGENT_NAME=Borges` gives `BORGES_REPO`. There is no fixed prefix to grep for,
which is the point — the agent reads its own name in its own environment.

Everything derives from **`AGENT_NAME`**. Only four values cannot be computed
and must be written in `.env`; every other line below is optional and shown
with what it derives to.

```
AGENT_NAME ─┬─► <NAME>_GIT_NAME
            └─► AGENT_USER  (lowercased, spaces closed up)
                 ├─► AGENT_PREFIX      the <NAME> above, uppercased
                 ├─► AGENT_HOME        /home/$AGENT_USER
                 │    └─► <NAME>_REPO_DIR   $AGENT_HOME/$AGENT_USER
                 ├─► AGENT_VOLUME      $AGENT_USER-home
                 ├─► RUNNER_PROJECT    $AGENT_USER-runner
                 ├─► the image tags    $AGENT_USER-agent:{candidate,deployed}
                 ├─► BWS_VAULT_*       $AGENT_USER-{acquired,provisioned,test}
                 └─► every lock, record and log under RUNNER_*
```

An override becomes the input to every step under it: setting `AGENT_USER`
moves the home, the checkout, the volume, the project, the image tags and the
vault projects together.

---

## Must be set

| | |
| --- | --- |
| `AGENT_NAME` | What the agent is called. Everything else is built from it. Static by necessity — it is what the dynamic prefix is derived *from*. |
| `<NAME>_REPO` | The agent's own repository, over SSH. |
| `<NAME>_GIT_EMAIL` | What it commits as. Use the account's own `users.noreply` address: the numeric id is not a function of the handle, so nothing can derive it. |
| `AGENT_ARCHIVE_REPO` | `owner/name` of the transcript archive. Not derivable — the archive is usually not owned by the agent's own account. Needed only by `collect`, `read` and the mirror. |
| `AGENT_MIRROR_REPO` | `owner/name` of the mirror — the audit record, held on refs outside `refs/heads/*` in a repository of its own. Kept apart from the archive because the machine that runs the agent has write on the archive to push transcripts, a private repository cannot carry rulesets, and a record that machine could rewrite is not a record. `just mirror-status` and `just setup-mirror` want it; without it they say so rather than reading the archive and reporting a mirror that is no longer there. |

## `<NAME>_*` — the agent's own

These are the complete set a session sees. The container builds the names from
`id -un`, because the account **is** the agent; nothing has to be passed in to
say who it is.

| | |
| --- | --- |
| `<NAME>_GIT_NAME` | Commit identity. Defaults to `AGENT_NAME`. |
| `<NAME>_GIT_EMAIL` | Commit address. |
| `<NAME>_REPO` | Its repository, over SSH. |
| `<NAME>_REPO_DIR` | Its checkout. Defaults to `$AGENT_HOME/$AGENT_USER`; the clone is given this path explicitly, so nothing about the repository's own name decides it. |
| `<NAME>_CLAUDE_VERSION` | The Claude Code version the image was built for. Arrives as `AGENT_CLAUDE_VERSION`, because a Dockerfile `ENV` name is literal; the entrypoint moves it into this namespace and unsets the original, so a session sees one spelling. |
| `<NAME>_RUNNER_COMMIT` | The runner commit this image was built from, short. Arrives as `AGENT_RUNNER_COMMIT` for the reason the line above gives, and is moved into this namespace by the entrypoint. It exists so a session can name its own version without comparing anything: until 2026-09-02 the image recorded no commit at all, which is how a 30-hour-old image once looked deployed. `just build` measures it in the checkout it is building — the build context is `image/` and carries no `.git` — and `just deploy` builds from the deployed checkout, so what a session reads is what is live. Empty on an image built by anything but `just build`, and a session is then told the image does not say. |
| `<NAME>_RUNNER_COMMITTED_AT` | When that commit was made, ISO-8601 UTC. Same route, same emptiness. |
| `<NAME>_RUNNER_PUSHED_AT` | When that commit reached origin, ISO-8601 UTC. Same route. Empty means no push entry for it in the building host's `refs/remotes/origin/main` reflog — the image was built where nothing pushes, so what it runs may never have reached origin. Read back out of the image by `deploy --state`, which is how the value crosses from the machine that builds to the one that runs. |
| `<NAME>_DOMAIN` | The agent's own domain, if it has one. Renders the `autoMode` block in `image/managed-settings.json`, which tells the classifier which zone is the agent's to publish on — a classifier that cannot place a hostname it meets in a transcript judges it as a stranger's. Empty is a real answer and means it has none; the placeholder resolves to nothing and the classifier is told nothing rather than told wrong. |
| `<NAME>_MODEL` | The model a session runs on, an alias such as `opus` or `sonnet`. Rendered into the `model` key of `image/managed-settings.json` at build, so it holds for every kind of session and the agent cannot edit it. `sonnet` unless set; `just verify` compares what a session was served against it. |
| `<NAME>_SCHEDULE` | `enabled`, `paused`, `disabled` or `unknown`. |
| `<NAME>_SCHEDULE_CRON` | The five fields of the installed line, read even when paused; empty when nothing is installed. |
| `<NAME>_WAKE_DEFAULT` | **The cadence.** Minutes a wake-up waits when the session asked for nothing — most sessions, and every session on an installation that never arms the request. Always a number. There is no `<NAME>_SCHEDULE_COOLDOWN` beside it any more: the crontab says when cron looks, this says how long a wake-up then waits. |
| `<NAME>_WAKE_MIN` | The floor, in minutes, and always a number. Two jobs: the least a request may ask for, and how long after a conversation ends nothing starts. It applies whether or not the request is armed, because the second job has nothing to do with the first. |
| `<NAME>_WAKE_REQUEST` | Whether a session's closing message can move that number, as exactly `true` or `false`. What will happen, not what `.env` says: a ceiling nobody set disarms it, and a session told `true` there would be reading the setting rather than the mechanism. |
| `<NAME>_WAKE_MAX` | The ceiling a request is clamped to, in minutes — `360` unless set — or `none` when the request is not armed, because there is no ceiling on something that is not read. |
| `<NAME>_WAKE_ASKED` | Minutes the last **unattended** session asked for in its closing message, raw, or `none` if it asked for nothing. Reported whether or not the feature is armed: an agent asking for something it is not being given is a state worth seeing. |
| `<NAME>_WAKE_GRANTED` | Minutes the next wake-up is held to: the ask clamped where there was one, `<NAME>_WAKE_DEFAULT` where there was not. **Always a number** — a wake-up always grants something, and asking for nothing is accepting the default rather than declining to be woken. `900` beside a `GRANTED` of `360` is a request cut to the ceiling, which is the only way a session learns the outcome of its own ask; an `ASKED` of `none` beside a `GRANTED` of `20` is the default accepted. It mirrors what `run.sh` enforces: the **recorded** wake where there was an honoured ask, since that is the number in force, and the live default where there was not. |

**All six are always present, and `none` is a value.** An absent variable — or
one present and empty — leaves a session unable to tell an intended state from
a line that broke, and those are opposite situations. So `none` means there is
genuinely no such number, empty means something failed, and `just verify` fails
on an empty one. `unknown` is deliberately not reused here: the instants above
use it for "could not tell", and this is "there is nothing to tell". Only
`_WAKE_MAX` and `_WAKE_ASKED` can say `none`; `_WAKE_REQUEST` is always `true`
or `false`, and `_WAKE_DEFAULT`, `_WAKE_MIN` and `_WAKE_GRANTED` are always
numbers.
| `<NAME>_LAST_SESSION_ENDED` | ISO-8601 UTC, or `unknown`. Counts every session, mostly the schedule's. |
| `<NAME>_LAST_CHAT_ENDED` | ISO-8601 UTC, or `unknown` — when the **operator** last spoke, which the line above cannot answer. |
| `<NAME>_LAST_AUTO_SESSION_ENDED` | ISO-8601 UTC, or `unknown` — when the last **unattended** session ended. Neither of the two above answers it: the first counts conversations and the second counts only those, so the difference is not derivable from the pair. Read from `RUNNER_LAST_RUN`, the only thing that knows, and `unknown` also covers a session that was killed or is still running. This is the clock a wake-up is measured against once a request is armed. |
| `<NAME>_OTHER_SESSION_STARTED_AT` | Set only by `run --force` and `chat --force` when a session was already running: that session's start. |

Four more reach a session under the `ACCOUNT_` namespace rather than the
agent's, because they are about the **account** and not about the agent:

| | |
| --- | --- |
| `ACCOUNT_USAGE_SESSION` | What the budget gate saw for the 5-hour window: `used=`, `allowed=`, `ratio=`, the `budget=` it was computed with, `window=` and `resets=`. `ratio` is `used` over `allowed` as a percentage, and above 100 is what an `--ignore-budget` session sees. |
| `ACCOUNT_USAGE_WEEKLY` | The same for the 7-day total. |
| `ACCOUNT_USAGE_SCOPED` | The model-scoped weekly limits, joined by `; `, and printed even when empty — they are reported and never gated. It used to repeat the key once per limit, which is faithful to a list and impossible in an environment. |
| `ACCOUNT_BUDGET_GUARD` | Whether the **host** would have refused, normalised to exactly `true` or `false` — never absent, never empty, because the contract is that a session never has to interpret a sentinel. It is told even when `--ignore-budget` bypassed the answer. |

They are printed only on the path that reached a verdict, so the usage
variables and the budget they were computed with are absent together and never
half-present: **what a session sees is seven variables or none.**
`host/lib/session-env.sh` forwards whatever `claude-usage.py` printed **by
prefix**, never by name, so the two cannot part company the day one gains a
field.

**They carry facts and never direction.** This channel reaches the agent
through a layer it cannot answer, so a sentence in it that said what to do
would be direction outside the trusted channel, with no symptom.

## `AGENT_*` — the agent's, held by the runner

| | |
| --- | --- |
| `AGENT_NAME` | Above. Also passed to the container, for messages a human reads. |
| `AGENT_USER` | The slug every derived name is built from: the name lowercased, spaces closed up. A unix account, a volume and an image tag cannot hold a capital or a space. |
| `AGENT_PREFIX` | `AGENT_USER` uppercased, dashes to underscores. Exported because compose builds the same names and cannot uppercase. |
| `AGENT_HOME` | The account's home. **Build arg**; never in the runtime environment. |
| `AGENT_REPO_DIR` | The checkout, as a build arg only — it is baked into one permission rule. The runtime value the agent reads is `<NAME>_REPO_DIR`. |
| `AGENT_VOLUME` | The docker volume holding the agent's whole world. |
| `AGENT_PROJECT_DIR` | The directory name Claude Code files transcripts under — the checkout path with every `/` turned into `-`. A name, not a path: it sits inside `~/.claude/projects/`. |
| `AGENT_SKIP_CLONE` | Any non-empty value skips the clone, so the image can be exercised without a repository or a key GitHub knows about. Announces itself on every start. |
| `AGENT_ARCHIVE` | Where the archive is checked out. Defaults to `archive/` **inside this repository**, gitignored like `deployed/` and made by `just setup-archive`, so a clone of this repository arranges nothing outside its own directory. Set it to keep the archive elsewhere — a sibling checkout, say — and that default never applies. A relative value counts from this checkout, not from where `just` ran. |
| `AGENT_MIRROR` | Where the mirror's clone sits. Defaults to `mirror/` **inside this repository**, gitignored like `archive/`, and made by `just setup-mirror`. A working folder, and **blobless** — `--filter=blob:none` — because `just mirror-status` reads commit metadata and one workflow file, never a tree: measured 1.4 MB against 267 MB for the whole memory. Read from a clone rather than over the API so the same command gives the same answer from either machine. A relative value counts from this checkout, not from where `just` ran. |
| `AGENT_ARCHIVE_REPO` | Above. |
| `AGENT_MIRROR_WORKFLOW` | The mirror workflow's file name **in that repository**. Defaults to `mirror-$AGENT_USER.yml`. Nothing here renames that file. |
| `AGENT_TRANSCRIPT_RETENTION_DAYS` | How long Claude Code keeps transcripts in the volume, as `cleanupPeriodDays` in managed settings. **Build arg**; never in the runtime environment — a session reads the number back out of the settings file that decides it, so there is no second copy to drift. Defaults to `30`, Claude Code's own default, and the render refuses anything that is not a whole number of days, 1 or more: `0` is valid JSON and means delete everything at the next session start. |
| `AGENT_MIRROR_COOLDOWN` | Minutes before a session may ask the mirror to run again. Empty, unset, or unparseable means every session asks — the opposite of the budget guard, on purpose: this is a cost knob, and the direction with no undo is a mirror that did not run. |

### The plumbing names

`just` cannot export a computed name and compose cannot dereference one, so
the justfile translates: it reads `<NAME>_X` from `.env`, exports a fixed
`AGENT_X`, and compose emits `<NAME>_X` into the container. Set the
`<NAME>_` spelling; these are what carries it across.

| | |
| --- | --- |
| `AGENT_REPO` | `<NAME>_REPO`. Read directly by `host/archive/setup.sh`, which needs the source repository the mirror's deploy key goes on, by `host/monitor/drift-audit.sh`, and by `host/lib/journal.sh`, which fetches the clone `just stats` and `just journal` read the journal from. |
| `AGENT_GIT_NAME`, `AGENT_GIT_EMAIL` | `<NAME>_GIT_NAME` and `<NAME>_GIT_EMAIL`, on their way to the entrypoint. Written by the justfile and read by compose alone. |
| `AGENT_DOMAIN` | `<NAME>_DOMAIN`, as a **build arg**: it renders the `autoMode` block of `image/managed-settings.json` and is never in the runtime environment. The community sentence renders the same block and is deliberately not a variable — it is in `image/config/community.txt`; see [`docs/configuration.md`](docs/configuration.md#the-three-files-that-are-yours). |
| `AGENT_WAKE_DEFAULT` | `<NAME>_WAKE_DEFAULT` — the cadence, in minutes. **`60` when unset or unparseable**, because there is no safe way to have none: unset would mean the cron expression alone is the clock, and the expression this repository recommends is `* * * * *`. An explicit `0` is somebody's decision and means exactly that. |
| `AGENT_WAKE_REQUEST` | `<NAME>_WAKE_REQUEST` — exactly `true` lets a session's closing message move that number. Read on the host, which decides; the container is told what the decision came out as, never what was written here. |
| `AGENT_WAKE_MIN`, `AGENT_WAKE_MAX` | `<NAME>_WAKE_MIN` and `<NAME>_WAKE_MAX`. The floor is the default wait when unset, which makes an installation that sets only the default behave as a single cooldown always did. The ceiling is `360` — six hours, since nothing here reports a session that never ran, so there has to be a number rather than an unbounded sleep. Both fall back on a typo rather than disarming the request; only a floor **above** the ceiling disarms it. See [`docs/schedule.md`](docs/schedule.md#a-session-asks-for-its-own-next-wake-up). |

## `RUNNER_*` — machinery

Identical whichever agent ran here. Every one is **required, not defaulted**:
a shared fallback would be two agents on one lock — or worse, one agent whose
recipes lock `/tmp/<name>-session.lock` while a script that missed the export
locks a generic path. Two locks, neither excluding the other, and nothing to
see. `just` derives and exports them; running these scripts outside `just`
fails loudly instead.

The two build-time values are the exception and are deliberately not
required: they are measured per build, and empty is a real answer that
travels into the image and is reported there as such.

| | |
| --- | --- |
| `RUNNER_PROJECT` | Compose's project name. Prefixes container names only — the volume is named explicitly, so this never reaches it. |
| `RUNNER_MEM_LIMIT` | The memory a session may take, `mem_limit` in compose. Unset is measured off this machine — `/proc/meminfo` less 512 MB, capped at 4096m, floored at 512m — because one `.env` reaches every host the deploy ships to and a constant written for the machine that builds arrives on the machine that runs. Set it to go tighter; not in `.env`, which travels. |
| `RUNNER_CPUS` | The CPU a session may take, `cpus` in compose. Unset is `nproc` capped at 2. A value above what the machine has is not a loose limit: docker refuses to start the container at all, and every session, probe and `just listen` fail on a message about CPUs. |
| `RUNNER_IMAGE` | Which image to run. `build` sets it to the candidate; unset means the deployed tag. |
| `RUNNER_IMAGE_CANDIDATE` | The candidate tag, `$AGENT_USER-agent:candidate`. What `build` tags, `verify` proves, and `test-container` runs. |
| `RUNNER_IMAGE_DEPLOYED` | The deployed tag, `$AGENT_USER-agent:deployed`. `verify` compares compose's own `image:` default against it — compose cannot read a `just` variable, so that default is the one duplicated name in the repository. |
| `RUNNER_COMMIT` | Set by `just build` alone, and only for the length of the build: the commit of the checkout being built, passed to compose as a build argument and baked in. A session reads it back as `<NAME>_RUNNER_COMMIT`. |
| `RUNNER_COMMITTED_AT` | That commit's date, ISO-8601 UTC. Same life, same route. |
| `RUNNER_PUSHED_AT` | When that commit reached origin, ISO-8601 UTC, from the reflog of `refs/remotes/origin/main` in the checkout being built — `update by push` entries only, since a fetch entry would date a pull. Same life, same route. |
| `RUNNER_EXTRACT_IMAGE` | The throwaway image used to read the volume from outside. `alpine:3`. |
| `RUNNER_DEPLOYED` | The deployed checkout — a worktree of the `deployed` branch that cron runs from, which `just deploy` resets and `just schedule` writes the cron line for. Defaults to `deployed/` **inside this repository**, gitignored. A relative value counts from this checkout, not from where `just` ran — and the justfile tells the deployed checkout from the other by comparing its own directory to this value. |
| `RUNNER_DEPLOY_HOST` | The ssh target of the machine the agent runs on, when that is not this one — an alias from `~/.ssh/config`, or `user@host`. Empty means it runs here, which is what a clone gets and what every recipe did before this existed. With it set, `just deploy` builds and proves the image here, prepares the checkout there, ships the image, and hands the question and the tag flip to that host; `deploy --state` and `--diff` forward, because they describe what is live and that is no longer this machine. |
| `RUNNER_DEPLOY_DIR` | The checkout on that host, `runner` unless set, taken from that account's home unless it starts with `/`. Kept apart from `RUNNER_DEPLOY_HOST` because the deploy needs each alone — `git push` wants `target:path`, `docker save \| ssh` wants only the target. Refused rather than quoted if it holds anything but letters, digits, `.`, `_`, `-` and `/`: it is interpolated into a shell on the far side. Both of these are filtered out of the `.env` that reaches that host. |
| `RUNNER_IMAGE_INCOMING` | The tag an image travels under, `$AGENT_USER-agent:incoming`. A tag goes with the image through `docker save`, so one sent under its live name would be live on arrival, ahead of every check; `just land` renames it after the checks, and that rename is the deploy. |
| `RUNNER_RUNTIME_ONLY` | `true` on the machine the agent runs on, never set by hand: `just deploy` stamps it into the copy of `.env` it sends there, on every deploy, so it cannot be lost by editing the file it lives in. `just build` refuses there outright — the image is built where the code is edited and arrives by `docker save | ssh docker load` — and `just deploy` refuses unless it carries `RUNNER_SHIPPED_ID`, which only the deploying machine sets. A guard against a hand on the wrong terminal and not a boundary: the file it reads is editable by anyone who can type there at all. |
| `RUNNER_REPO` | `owner/name` of this repository on GitHub, on the machine the agent runs on, never set by hand: `just deploy` stamps it into the `.env` it sends there, from this checkout's `origin`. `deploy --state` over there asks origin how far the live commit is behind its default branch, because that checkout is the live commit itself and has no origin to count against. Unset, the deploy row says the count could not be read. |
| `RUNNER_SHIPPED_ID` | Set by the deploying machine on the deploy it runs over ssh, never in `.env`. Its presence is what tells that host the image was built elsewhere and is already loaded: it checks the two equalities — the arrived id against this one, and the image's baked commit against the checkout beside it — instead of building. Unset, `deploy` builds from the deployed checkout as it always has. |
| `RUNNER_MONITOR` | Where the drift audit keeps its world: its clone of the archive's mirror of the agent's memory, the two anchors, the reports and the log — and the clone of the agent's own repository `just stats` reads its journal heading from and `just journal` its entries. Defaults to `monitor/` **inside this repository**, gitignored like `deployed/` and `archive/`, and made by `just drift-audit` on its first run. Set it to keep that state elsewhere, or to point one run at a scratch directory. A relative value counts from this checkout, not from where `just` ran. |
| `RUNNER_ZEBRA` | The background band under every second row of the tables `just tools` and `just cost` print on a terminal (the header is bold and underlined whatever this says), as an SGR parameter list. Defaults to `48;5;237`, a dark grey for a dark theme; set `48;5;254` or so for a light theme, `none` for no band. A band and not dim text because the operator is colourblind and text weight is not enough contrast to follow a row. Never applied when the output is piped. |
| `RUNNER_REMOTE_PORT` | The port `just listen --remote` serves the live view on, default `7681`. Bound to `127.0.0.1` alone and reached through the tailnet, so this only has to be free on this machine — move it when something else here already wants it. |
| `RUNNER_CHECKOUT` | The checkout a script was shipped in — computed by `host/lib/root.sh` from its own location, not by `just`, and the directory every host script then runs in. For the deployed copy that is `deployed/` itself, which is the other question from `RUNNER_ROOT` above it. |
| `RUNNER_ROOT` | The project root, which is not always the justfile's own directory: the deployed checkout is a worktree *inside* the project, and its copy of the justfile must compute the same archive and the same deployed path as the checkout above it. `host/lib/root.sh` finds the CHECKOUT a script was shipped in, which is the other question. |
| `RUNNER_IS_DEPLOYED` | `yes` in the deployed checkout, `no` anywhere else. The live recipes forward on it; the deployed copy is where the forwarding has to stop, or it would forward to itself forever. |
| `RUNNER_SAYS` | The marker `run` writes in front of an unattended session's opening prompt, so that the transcript renderer can print `runner` over it rather than the operator's name. Matched literally in transcripts already written. |
| `RUNNER_LOCK` | The session lock. One session at a time. |
| `RUNNER_SESSION_NAME` | What a session's container is called, so "is a session running?" has an answer. `just shell` and the probes must **not** wear this name. |
| `RUNNER_LAST_SESSION_ENDED_AT` | Epoch seconds when a session of any kind last ended. Under the cache directory, not `/tmp`: a wait that forgets on reboot is a wait that lets a session start immediately after every restart. The unattended cadence counts from the run record's `ended` instead; this stamp is what a conversation moves. |
| `RUNNER_LAST_CHAT_ID` | The session id of the last conversation, written at its **start**, so `chat --continue` resumes that one rather than the hourly unattended run. |
| `RUNNER_LAST_CHAT_ENDED_AT` | Epoch seconds when a conversation last **ended**. Surfaced to the agent as `<NAME>_LAST_CHAT_ENDED`. |
| `RUNNER_RUN_LOG` | Where cron writes what an unattended run printed. Named in the crontab line `schedule` installs. |
| `RUNNER_CACHE_DIR` | The host cache directory, `~/.cache/<agent>`, and the default root of every stamp and log below. Per agent: a shared directory would have two agents reading and overwriting each other's stamps. |
| `RUNNER_REVIEW_HELD` | How many transcripts the review gate is holding, and when that was counted — written by `collect` at every session end, read by `status` and the status snapshot. A session ending changes the count; a gate change shows only at the next `collect`. Asking `collect --held` instead costs a container start and a scan of the volume — all of it after a gate change. A missing file is not a zero: both readers say the count has not been taken and name `collect --held`. |
| `RUNNER_SNAPSHOT_PUBLISHED_AT` | When the status snapshot was last pushed to the archive's `status` branch. |
| `RUNNER_CREDENTIALS` | When the two credentials the agent runs on expire — the Claude setup-token and the token `gh` runs on — written by `credentials` at every session end and read by `status`. Both dates are in the container, so a reading costs a container start; taking it where nothing is waiting is why `status` reads a file. A missing file is not "they are fine": `status` says nothing has been read, and a reading that is there carries its own age. See [docs/vault.md](docs/vault.md#when-a-credential-expires). |
| `RUNNER_SNAPSHOT_COOLDOWN` | Minutes between publishes, default `10`. Checked before the collection, because collecting costs a container start: a floor tested after the expensive part is not a floor. |
| `RUNNER_SNAPSHOT_LOCK` | One writer per branch. |
| `RUNNER_CONFIG_LOCK` | The same, for the `config` branch `just deploy` backs this installation's own files up to. |
| `RUNNER_RECORDS_DIR` | One durable record per archived session, `~/.cache/<agent>/records/` unless set — when it ran, what it was, what it spent, which commits it made, which runner built its container, and what the next wake-up was counting when it ended. Written once when every field in it is final and never rewritten, which is what lets `just records` append one small file per session rather than rewrite a growing one: git stores whole blobs, and a single file rewritten forty times a day would push the whole cache each time. |
| `RUNNER_RECORDS_STATE` | What the sealing was done against — the three source refs and when — so a record can be audited against its sources later and staleness is visible rather than silent. On this host only: the `cache` branch is written once per file, and this is the one file that would change on every run. |
| `RUNNER_RECORDS_LOCK` | One writer per branch, as above, for `cache`. |
| `RUNNER_WEDGE_MINUTES` | How long an **unattended** session may run before it is reported as wedged, default `120`. Measured rather than chosen: of 289 completed sessions on the archive's status branch the 90th percentile is 16 minutes and the longest ever was 54, and the long ones are all just before midnight, where the agent waits out a `sleep` for the date to turn. Conversations are never counted — they legitimately run for hours. An explicit `0` turns the check off; anything else that is not a number falls back to the default, because a typo must not silently disable the only report a wedge ever produces. |
| `RUNNER_SAMPLE_SECONDS` | Seconds between host-wide sysstat samples while `run` or `chat` is running, from just before the container starts to the end of the script, so the collection is sampled too. Written by `sadc -S XDISK` under `$RUNNER_CACHE_DIR/sysstat/` as daily `saDD` files, each replaced a month later, and read back into every run's record as `system`, which `just status` and `just stats --system` show — see `docs/monitor.md`, under "The machine a run ran on". Unset, `0` or not a number is off; a host where `sadc` is in none of the places sysstat installs it skips it in silence. |
| `RUNNER_LAST_RUN` | How the last unattended run ended: when it started, what it was called, when it came back, and the `terminal_reason` its result envelope reported. Written only when a session actually starts, so a stop stays unconsumed across every wake-up that stands down — that is the latch the recovery start reads. It also holds the start of the wedged session already reported, so a hang notifies once rather than once a minute — see `docs/schedule.md`, under "The wedge alarm". And it holds what that session asked for as its next wake-up and what it was given, `asked_wake_after` and `wake_after`, which is the clock the next wake-up is measured against. |

## Tool namespaces

A tool keeps the names it already expects; these are not ours to rename.

| | |
| --- | --- |
| `ACCOUNT_BUDGET_GUARD` | Whether **this host** refuses a session that is over budget. Only exactly `true` arms it. |
| `ACCOUNT_BUDGET_SESSION_START` / `_CAP` | The 5-hour window's allowance, as percentages **of the whole account**. It climbs from START at the window's reset to CAP just before the next one, so a cap of 60 is not 60% available at the reset. Unset is not "no limit" — the gate refuses to answer and no session starts. |
| `ACCOUNT_BUDGET_WEEKLY_START` / `_CAP` | The same, over 7 days. |
| `ACCOUNT_BUDGET_CACHE_MINUTES` | How long a usage reading may be reused, on the host and in the container alike. The endpoint allows five requests per five minutes across the **account**, and `* * * * * just run` outside its wait asks once a minute — which spends it exactly and leaves nothing for the session's own read or for any Claude Code you have open. Default `5`; `0` turns the cache off; anything above 60, negative or unparseable is refused, because `300` is what seconds typed for minutes looks like. Unset is the default and **not** a refusal, which is the opposite of every other `ACCOUNT_BUDGET_*` and the one thing the shared prefix hides: those four are a guard, and a guard that defaults to permissive is one installed and doing nothing. This is a cadence knob, and a checkout that has never heard of it must still start sessions. |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code's own. Set by `image/vault-env.sh` from the vault's `claude-oauth-token`, unless one is already in the environment — that one wins, which is how `just verify` passes a deliberate value. Unset means the session falls back to `~/.claude/.credentials.json` in the volume, silently; `just verify`'s `session login` verdict is what says which. `claude-usage.py` deliberately never reads it: a setup-token is inference-only and the usage endpoint answers it 403. |
| `XDG_CACHE_HOME` | Where the host cache goes when it is set to an absolute path. `just`'s `cache_dir()` honours it and so does `claude-usage.py`, so the runner's stamps and the usage reading stay in one tree — until 2026-08-29 only the first did, and on a machine that set the variable the two halves of one cache sat in different trees with no symptom. Empty or relative is ignored, per the spec and because an empty value joined onto a filename yields a *relative* path: the reading would land wherever the process started — the checkout by hand, `$HOME` under cron — and never be found by the next run that looked. It does **not** move the vault cache; see below. |
| `BWS_ACCESS_TOKEN` | Bitwarden Secrets Manager. Unset is not a failure — the vault is simply not configured. |
| `BWS_SERVER_URL` | Which Bitwarden server issued the token. A token from `bitwarden.eu` is rejected on the US default as `invalid_client`, which reads exactly like a bad token. |
| `BWS_PATH` | Where the `bws` binary is. A test seam. |
| `BWS_VAULT_PROJECT` | The writable project. Defaults to `<agent>-acquired`. |
| `BWS_VAULT_READABLE_PROJECT` | The read-only project. Defaults to `<agent>-provisioned`. That split is what lets the agent store a secret it acquired without overwriting one it was given. |
| `BWS_VAULT_TEST_PROJECT` | Defaults to `<agent>-test`. |
| `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER` | Claude Code's own. Literal `"1"`, never `${VAR:-}`: any non-empty value including `0` turns the behaviour **on**, so an unset host variable would arrive as the empty string and the line would look set while doing nothing. |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | Claude Code's own, and the one of that family **deliberately not set**: it carries the `ai-title` entries `session-meta.jq` builds a session's title from. |
| `COMPOSE_PROJECT_NAME` | Compose's own. Outranks `name:` in the file, which is why the justfile exports it. |
| `COMPOSE_PROGRESS` | Compose's own, exported as `quiet` by the justfile so the two lines it prints naming a throwaway container do not sit above every answer this repository gives. Progress only: the container's own output, `no such service`, and a failing build's diagnostics all still print. A **successful** build's layer output does not, which is why `just build` passes `--progress auto` — the one override, and the one command whose progress is the answer. |
| `OPERATOR_NAME` | The human the agent reports to. Named in messages, and — since 2026-08-31 — in the `autoMode` block, so the classifier can connect a name it meets in a transcript to the operator. Defaults to `Operator`. |
| `OPERATOR_SAYS` | The bracket `chat` writes in front of the operator's message — the line rule 1 rests on. `host/session/last-chat.sh` greps the volume for exactly this, so changing `OPERATOR_NAME` on a running installation makes earlier conversations unfindable by `chat --continue`. |
| `OPERATOR_GITHUB_HANDLE` | The operator's GitHub account. Renders the same block: `<handle>/*` already appears there as a trusted owner, and without this nothing connects that owner to the person the agent writes about by name. Empty is a real answer. It is not a secret — the agent's own rules make the handle an address on GitHub — but it is an identity, which is why it lives here and not in a tracked file. |

## Build pins

`ARG` names in `image/Dockerfile`, never in `.env` and never in a runtime
environment. They are what the image installs, and moving one is a rebuild.

| | |
| --- | --- |
| `CLAUDE_CODE_VERSION` | Which Claude Code the image installs. A session reads it back as `<NAME>_CLAUDE_VERSION`, and `just verify`'s `claude code` verdict compares it against what actually answers on PATH — the pin installs a version and does not keep one. |
| `BWS_VERSION`, `BWS_SHA256` | The Bitwarden CLI the vault wrapper calls, and the checksum the build verifies the download against. |

## Not configurable, deliberately

The **vault cache** — `$HOME/.cache/vault`. `bash-guard.py` reads it to learn
what a secret looks like for its rule on secrets in commits, and
`host/archive/read-volume.sh` reads it to know what to redact from transcripts.
Three files hardcode that path; a variable that moved only the first would
disarm both, in silence. `XDG_CACHE_HOME` does not move it either, and that is
the same ruling rather than an oversight: the third reader is on the **host**,
looking into the volume as `/vol/.cache/vault` through a container that never
sees the agent's environment. It could not follow the variable, so an
XDG-aware vault would leave the redaction scan reading an empty directory and
reporting nothing wrong.

## Two things the mechanics force

**`AGENT_NAME`, `AGENT_USER`, `AGENT_HOME` and `AGENT_REPO_DIR` cannot carry
the dynamic prefix.** A Dockerfile `ARG` or `ENV` name is literal, and
`AGENT_NAME` is what the prefix is derived from in the first place.

**`just` cannot export a computed name, and compose cannot compute a value
reference** — only a key, and only in the list form of `environment:`, where
the whole string is interpolated. So the justfile is the translator: it reads
`<NAME>_REPO` from `.env`, exports a plumbing `AGENT_REPO`, and compose emits
`<NAME>_REPO` into the container. The middle names are listed above, under
*The plumbing names*. This is also why `compose.yaml` **requires** `AGENT_USER` rather
than defaulting it: a bare `docker compose` carries only what `.env` holds, and
a default would let it address an empty volume beside the real one in silence.

`just verify` proves both halves — that no configured name appears in tracked
content, and that compose still refuses to guess which agent it is.
