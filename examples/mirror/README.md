# A seed for the mirror repository

Copy these files onto `main` of the empty private repository that holds the
mirrors, replace every `REPLACE_WITH_` placeholder, commit and push.

`main` is the only ref you ever write by hand here. Everything this repository
exists for lives on refs outside `refs/heads/*`, written by the workflow on
`main` and by nothing else:

| ref | what it holds | who writes it |
| --- | --- | --- |
| `main` | this README and the workflow | the operator, by hand |
| `refs/memory/mirror` | the agent's memory repository, mirrored | the workflow here |
| `refs/memory/rewound/<UTC timestamp>` | an annotated tag holding a tip that a rewrite upstream would otherwise have destroyed | the workflow here |

**Why this is a repository of its own.** It is the audit record: what says the
agent's memory was not rewritten. The machine that runs the agent holds a
credential that can write every ref of the repository it pushes transcripts to,
and a private repository cannot carry rulesets — so a record living beside those
transcripts could be rewritten by the machine it is meant to hold to account.
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
impossible. The mirrors of the transcripts and the sealed records, when they
exist, take the same shape: `refs/sessions/mirror`, `refs/cache/mirror`, each
with its own `rewound/` beside it.

## The two secrets

Neither is new, and neither belongs to the machine that runs the agent.

| secret | what it is | why it cannot be `GITHUB_TOKEN` |
| --- | --- | --- |
| `<PREFIX>_SOURCE_KEY` | a read-only deploy key on the agent's own repository | `GITHUB_TOKEN` is valid only in the repository the workflow runs in, and the memory is elsewhere |
| `<PREFIX>_MIRROR_TOKEN` | a fine-grained PAT on **this** repository, Contents and Workflows, read and write | a `GITHUB_TOKEN` push does not trigger other workflows, and cannot be given this ref namespace |

The key goes on the agent's repository **before** the secret goes in here: a
secret installed against a key that was never accepted fails on the first run,
in the words of a network error.

## Reading it

From the runner: `just mirror-status` — whether the workflow is enabled, whether
the mirror is current, and whether anything upstream was rewound. That last one
is the point of the `rewound/` marks, and this check is what turns a record that
stopped being written into something visible rather than silent.

Nothing here is fetched by a plain clone: these refs are outside
`refs/heads/*`, so they arrive only when a refspec names them —
`+refs/memory/*:refs/memory/*` takes the mirror and its marks together.
