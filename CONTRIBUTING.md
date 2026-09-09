# Contributing

This repository is a consumer of Snapgate, not a fork of it. Anything
Snapgate cannot do goes in [GAPS.md](GAPS.md) with the workaround used; the
fix belongs upstream.

## Before opening a PR

```sh
git config core.hooksPath .githooks   # once per clone; see below
actionlint .github/workflows/*.yml
shellcheck -S style scripts/*.sh
```

To exercise a prompt change against the local backend, follow the five
commands under "Local reproduction" in the README. Do not commit anything
under `.snapgate/baselines/` by hand: baselines are recorded on a runner by
the `record` workflow so the nightly compares like with like.

## Ground rules

- **No application code.** Prompts, schemas, committed snapshots, shell
  scripts and workflows only. If a change needs a `main.go`, it needs to go
  to Snapgate instead.
- **Prompt edits and check edits are the same kind of change.** Both are in
  the fingerprint, both make the case stale, both need a re-record through
  the `record` workflow (`mode: accept`).
- **Hosted budget.** A gate or nightly run spends at most 24 requests on the
  hosted backend, retries included. Adding a hosted case means removing one.
- **Small commits, conventional messages** (`feat(config): ...`,
  `ci(canary): ...`, `docs: ...`). One logical change each; a body only when
  the why is not obvious from the diff. No attribution trailers of any kind:
  `.githooks/commit-msg` strips them, and `.claude/settings.json` turns them
  off at the source.

## How this is built

This project is developed with Claude Code as a pair-programming tool. The
scope, the choice of backends, and the decisions about what the canary
reports and when are the maintainer's; GAPS.md records the reasoning behind
the non-obvious ones. Every change is reviewed by the maintainer before it
lands on `main`, and the gate workflow runs both backends on each one.
