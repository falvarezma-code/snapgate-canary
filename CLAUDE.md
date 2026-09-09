# Conventions for this repository

Commit messages follow Snapgate's (github.com/falvarezma-code/snapgate):

1. Subject: `type(scope): summary`. Types are feat, fix, docs, ci, chore; scope is the area when one applies (config, scripts, canary, record, gate); lowercase, imperative or noun phrase, no trailing period, under 80 characters.
2. Body only when the why is not obvious from the diff: prose wrapped at about 72 columns explaining reasoning and trade-offs, not restating the change. Docs and CI commits usually have none.
3. One logical change per commit, small and reviewable.
4. No trailers of any kind: no Co-Authored-By, no "Generated with", no session ids. `.claude/settings.json` disables attribution and `.githooks/commit-msg` strips it; run `git config core.hooksPath .githooks` once per clone.
5. Disclosure of AI-assisted development lives in CONTRIBUTING.md under "How this is built", never in commit messages or pull requests. Commit messages never mention the assistant, a prompt, or a conversation.

Other constraints: no application code (prompts, snapshots, scripts and workflows only); baselines under `.snapgate/baselines/` are written only by the record workflow, never by hand and never on main; only Snapgate features that exist are used, and gaps go in GAPS.md.
