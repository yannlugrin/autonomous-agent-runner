# A seed for the mirror repository

Copy these files onto `main` of the empty private repository that holds the
mirrors, replace every `REPLACE_WITH_` placeholder, commit and push.

`main` is the only ref you ever write by hand here. Everything this repository
exists for lives on refs outside `refs/heads/*`, written by the workflow on
`main` and by nothing else:

| ref | what it holds | who writes it |
| --- | --- | --- |
| `main` | this README, the workflow and its script | the operator, by hand |
| `refs/memory/mirror` | the agent's memory repository, mirrored | the workflow here |
| `refs/sessions/mirror` | the archive's `sessions` branch | the workflow here |
| `refs/cache/mirror` | the archive's `cache` branch | the workflow here |
| `refs/status/mirror` | the archive's `status` branch | the workflow here |
| `refs/config/mirror` | the archive's `config` branch | the workflow here |
| `refs/<record>/rewound/<UTC timestamp>` | a ref holding a tip that a rewrite upstream would otherwise have destroyed | the workflow here |

**Why this is a repository of its own.** It is the audit record: what says the
agent's memory and the archive's records were not rewritten. The machine that
runs the agent holds a credential that can write every ref of the repository it
pushes transcripts to, and a private repository cannot carry rulesets — so a
record living beside those transcripts, or those transcripts themselves, could
be rewritten by the machine they are meant to hold to account.
Here, that machine has no write credential at all. What it may hold is
`actions: write`, enough to ask the mirror to run and not enough to touch a ref:
it can make the record stop, which `just mirror-status` reports, and it cannot
forge one.

**The mirror is not a branch, deliberately, and GitHub cannot show it.** It
carries whatever the agent has written in its own repository, workflow files
included, and GitHub starts a workflow run from the files on the pushed ref — so
on a branch or a tag, a file the agent wrote saying `on: push` would execute
here, with this repository's secrets. Only `refs/heads/*` and `refs/tags/*`
trigger, which is why the record lives outside both. That reason is stronger
here than it was in the archive: this repository holds a token that can write
the record itself.

**A ref cannot be the prefix of another ref**, which is why the mirror is
`refs/memory/mirror` and not `refs/memory` — the marks below it would be
impossible. The archive's branches take the same shape: `refs/sessions/mirror`,
`refs/cache/mirror`, `refs/status/mirror`, `refs/config/mirror`, each with its
own `rewound/` beside it.

## The three secrets

None of them belongs to the machine that runs the agent.

| secret | what it is | why it cannot be `GITHUB_TOKEN` |
| --- | --- | --- |
| `<PREFIX>_SOURCE_KEY` | a read-only deploy key on the agent's own repository | `GITHUB_TOKEN` is valid only in the repository the workflow runs in, and the memory is elsewhere |
| `<PREFIX>_ARCHIVE_KEY` | a read-only deploy key on the archive | the same: the archive is elsewhere |
| `<PREFIX>_MIRROR_TOKEN` | a fine-grained PAT on **this** repository, Contents and Workflows, read and write | a `GITHUB_TOKEN` push does not trigger other workflows, and cannot be given this ref namespace |

Each key goes on its repository **before** its secret goes in here: a secret
installed against a key that was never accepted fails on the first run, in the
words of a network error. A secret that is not set fails the steps that need it
and no others.

## Reading it

From the runner: `just mirror-status` — whether the workflow is enabled, whether
the memory's mirror is current, and whether anything upstream was rewound. That
last one is the point of the `rewound/` marks, and this check is what turns a
record that stopped being written into something visible rather than silent.

Nothing here is fetched by a plain clone: these refs are outside
`refs/heads/*`, so they arrive only when a refspec names them —
`+refs/memory/*:refs/memory/*` takes the memory's mirror and its marks together,
and `+refs/sessions/*:refs/sessions/*` and its three siblings the archive's.
