# A seed for the transcript archive

Copy these files onto `main` of the empty private repository named by
`AGENT_ARCHIVE_REPO`, replace every `REPLACE_WITH_` placeholder, commit and
push. Then run `just setup-archive` in the runner, which clones it, raises
its Actions token to write, and installs the two secrets the mirror
workflow runs on.

`main` is the only ref you ever write by hand. Every other ref here is written
by a machine, lives on a ref of its own, and shares no root commit with `main`
or with any of the others — so a `git log` on one shows only that record, and
the tooling on `main` can be rewritten without touching a byte of any of them.

| ref | what it holds | who writes it |
| --- | --- | --- |
| `main` | this README, the workflows, the page's scripts | the operator, by hand |
| `sessions` | one file per session transcript, filed by the UTC day it happened, plus the ledger of what was ruled on | `just collect --push`, from the runner, on the host |
| `status` | `snapshot.json` — what the host knows and no reader on GitHub can: whether a container is up, what the crontab holds, what the account has spent | `just publish-status`, from the runner |
| `config` | the runner's three per-installation files, which are untracked there and have no other copy | `just deploy`, once a deploy has succeeded |
| `refs/archive/<agent>` | a mirror of the agent's memory repository | the `mirror-<agent>` workflow here, hourly |

**The mirror is not a branch, deliberately, and GitHub cannot show it.** It
carries whatever the agent has written in its own repository, workflow files
included, and GitHub starts a workflow run from the files on the pushed ref
— so on a branch or a tag, a file the agent wrote saying `on: push` would
execute here, with this repository's secrets. Only `refs/heads/*` and
`refs/tags/*` trigger. Read it with `just mirror-status` in the runner, or
`git fetch origin '+refs/archive/*:refs/archive/*'`.

No record here is authoritative. `sessions` is a copy of what the volume
held at collection time and `refs/archive/<agent>` a copy of what the agent
had pushed at mirror time; both are read-only, and restoring from one is a
deliberate act rather than a sync.

## What is here

| | |
| --- | --- |
| `.github/workflows/mirror-AGENT.yml` | the mirror. **Rename it** to `mirror-<agent>.yml` — the runner looks for that name. |
| `.github/workflows/check-credentials.yml` | proves the status page's four secrets on demand, without printing one. Delete it if you are not installing the page. |
| `scripts/session-meta.jq` | one archived session as a row. Read by the status page's renderer; the runner keeps its own copy for `just sessions`. |
| `optional-status-page/` | the page, and everything it needs. It requires a Cloudflare account — see its README. |

## The placeholders

Every one of them is a `REPLACE_WITH_` string rather than a plausible
default, so a leftover is visible in a diff and fails loudly. `git grep
REPLACE_WITH_` lists what is left.

| placeholder | what to put there |
| --- | --- |
| `REPLACE_WITH_AGENT` | `AGENT_USER` from the runner's `.env` — lowercase, the name every derived thing is built from |
| `REPLACE_WITH_PREFIX` | the same, uppercased, dashes as underscores. It prefixes the secret names `just setup-archive` writes |
| `REPLACE_WITH_SOURCE_REPO` | `owner/name` of the agent's own repository |
| `REPLACE_WITH_OWNER` | the GitHub account that owns this archive |
| `REPLACE_WITH_ARCHIVE` | this repository's own name |
| `REPLACE_WITH_AGENT_NAME` | the agent's display name, for the page's heading |

## The secrets

`just setup-archive` sets the first two and asks you for the token. The rest
are the status page's, set by hand.

| secret | what it is |
| --- | --- |
| `<PREFIX>_SOURCE_KEY` | a read-only deploy key on the agent's repository. The mirror fetches with it. |
| `<PREFIX>_ARCHIVE_TOKEN` | a fine-grained PAT on **this** repository, Contents and Workflows, read and write. It cannot be `secrets.GITHUB_TOKEN`: an Actions token may never push a commit that touches `.github/workflows/`, and the day the agent adds a workflow to its own repository every mirror run would fail. It expires, and the mirror stops dead when it does. |
| `<PREFIX>_READ_TOKEN` | status page only. Fine-grained, read-only on the agent's repository, with Issues and Discussions read. |
| `CF_ACCOUNT_ID`, `CF_KV_NAMESPACE_ID`, `CF_KV_TOKEN` | status page only. |

**Push `main` before expecting the mirror to run.** A scheduled workflow
only exists once it is on the default branch, and GitHub disables schedules
after 60 days with no repository activity — a collection push counts, so
`just collect --push` is what keeps the mirror alive.
