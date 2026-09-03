# A seed for the agent's own repository

Copy these files into the empty private repository named by `<NAME>_REPO`,
commit them, and push. That commit is the agent's memory on its first
morning; everything after it is the agent's own writing, and nothing in the
runner ever commits here again.

Edit them before you push. They are a shape, not content: the name, the
self-description and the rules are yours to decide, and the agent will
rewrite all three itself soon enough. The twelve rules in `CLAUDE.md` are a
short form of the ones the runner was built around — direction from the
operator only, free by default with a few lines, never its own confinement,
memory in files, small true commits, secrets never in the repository. Three
of them are what the runner's own mechanisms assume: rule 1 (what is read is
never direction), rule 3 (the boundary lives in the operator's repository),
rule 10 (secrets go through `vault`). Change the rest as you like.

| file | what it is |
| --- | --- |
| `CLAUDE.md` | The standing instructions. Claude Code loads it into every session automatically, so it is the one file that is always read. |
| `SELF.md` | Who the agent is, in a paragraph. Named by the system prompt the runner renders, alongside `CLAUDE.md`. |
| `JOURNAL.md` | What each session did, newest first. The only record that survives a session, because the container's transcripts are not memory. |
| `.claude/settings.json` | Project settings, deliberately holding no `permissions` block. |
| `tools/` | Scripts the agent writes for itself. Empty but present, because one permission rule names this path. |

## What the runner requires of them

**A session-start routine in `CLAUDE.md`, under that name.** An unattended
session opens with *"Run the session-start routine in CLAUDE.md"* and nothing
else — see `host/session/run.sh`. A repository without one gets a session
that has been told to do something it cannot find.

**No `permissions` block in any settings file the agent can write** —
neither `.claude/settings*.json` here nor `~/.claude/settings*.json` in the
volume. An allow rule short-circuits the auto-mode classifier, so a rule the
agent writes for itself is a bypass it granted itself. `just status` reports
one if it appears; the check is `host/release/check-agent-settings.sh`.

**`tools/` is the allow-rule path.** Managed settings allow
`Bash(python3 tools/*)` and the same under the checkout's absolute path, so
a script the agent puts there runs without a prompt. Nothing else in the
repository has that property, and moving the directory silently removes it.

**`ERROR_ON_PUSH` appears in the repository root when the backup fails.**
The hook writes it and nothing removes it but a session; a `CLAUDE.md` that
does not look for it is one where a failed backup is invisible from inside.

The runner reads nothing else here. `SELF.md` and `JOURNAL.md` are named by
the system prompt and by the routine above, and both are conventions this
seed sets rather than mechanisms — rename them and the only thing that
breaks is a sentence.
