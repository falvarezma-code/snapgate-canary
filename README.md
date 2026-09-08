# snapgate-canary

[![canary](https://github.com/falvarezma-code/snapgate-canary/actions/workflows/canary.yml/badge.svg)](https://github.com/falvarezma-code/snapgate-canary/actions/workflows/canary.yml)

A language model is an untrusted upstream dependency: its answers can change
without a version bump, a changelog, or a diff. This repository pins 24
prompts and their answers with [Snapgate](https://github.com/falvarezma-code/snapgate),
the way a lockfile pins a library, and re-checks them every night against a
hosted model and a local one. When an answer changes and nothing in this
repository did, the change is recorded in public as an issue containing the
diff and the upstream fingerprint before and after.

There is no application code here. The repository is a consumer of Snapgate:
a config, committed baselines, and three workflows.

## Layout

| Path | What |
|---|---|
| [`snapgate.yaml`](snapgate.yaml) | Two providers (`ollama`, `openai`), 24 prompts in four groups, 44 cases. Each prompt is a YAML anchor shared by both backends. |
| [`.snapgate/baselines/`](.snapgate/baselines/) | The snapshots. One JSON file per case: the exact request, its fingerprint, and the answer. Written only by the `record` workflow, on a runner. |
| [`fingerprints/`](fingerprints/) | What the upstream was when the baselines were recorded: model digest and quantization, Ollama version, context length, CPU. Snapgate does not record this; [`scripts/fingerprint.sh`](scripts/fingerprint.sh) does. |
| [`schemas/`](schemas/) | JSON Schemas for the extraction group. |
| [`scripts/`](scripts/) | `check.sh` (one backend, retries transient errors within a budget), `drift-report.sh` (issue body and dedupe key), `explain-exit.sh` (exit code to annotation), `fingerprint.sh`, `determinism.sh` (local experiments only). |
| [`.github/workflows/gate.yml`](.github/workflows/gate.yml) | On every pull request: check both backends. A non-zero exit blocks the merge. |
| [`.github/workflows/canary.yml`](.github/workflows/canary.yml) | Nightly and on demand: check both backends, file or update drift issues. |
| [`.github/workflows/record.yml`](.github/workflows/record.yml) | On demand: record or accept baselines on the runner and open a pull request. |
| [`GAPS.md`](GAPS.md) | What this canary needed that Snapgate does not have, and the smallest change that would close each gap. |

## The two backends

| | `ollama` | `openai` |
|---|---|---|
| Model | `qwen2.5:1.5b`, Q4_K_M, pulled unpinned by tag | `gpt-4o-mini`, the alias, so provider-side version changes are observed |
| Where | Installed on the runner, `OLLAMA_CONTEXT_LENGTH=2048`, `OLLAMA_NUM_PARALLEL=1` | `https://api.openai.com/v1` with the `OPENAI_API_KEY` secret |
| Cases | all 24 | 20; at most 24 requests per run including retries |
| Baseline check | `exact` | `exact` for extraction and classification, `similarity ≥ 0.9` for summaries and code |
| Params | temperature 0, seed 42, per-group `max_tokens` | same |

The original design used GitHub Models with the built-in token and no secret.
GitHub retired that service on 2026-07-30; see GAPS.md.

## Vocabulary

Snapgate has three non-zero exits and the canary treats them differently.

| Exit | Snapgate says | This repo says | Nightly action |
|---|---|---|---|
| 1 | `FAIL`: a check failed | **upstream drift**: same request, different answer | open or update a `drift` issue; job stays green |
| 2 | `DRIFT`: case definition changed since the baseline | **stale baseline**: someone changed a prompt without re-recording | fail the job, no issue |
| 3 | `ERROR`: provider or config error | **not drift**: network, 429, missing key | retry transient errors, then fail the job, no issue |

## Local reproduction

Five commands. The local answers will not all match the committed baselines:
those were recorded on a GitHub runner CPU and floating point differs across
hardware, which is why baselines are recorded there and not on a laptop. The
diffs are the point.

```sh
go install github.com/falvarezma-code/snapgate/cmd/snapgate@v0.1.1
OLLAMA_CONTEXT_LENGTH=2048 OLLAMA_NUM_PARALLEL=1 ollama serve &
ollama pull qwen2.5:1.5b
OLLAMA_API_KEY=ollama scripts/check.sh ollama
snapgate diff json.address.ollama      # or any case the check reported as FAIL
```

`scripts/determinism.sh <case> [N]` runs one case N times and reports how
many answers were identical. On an M1 with the settings above, 10 of 10 for
every case tried. Run it before trusting `exact` on new hardware.

## Demo 1: a pull request changes one word of a system prompt

The `classify.spam` prompt gains two words. The PR touches `snapgate.yaml`
only. The gate runs `snapgate check` and the case's request fingerprint no
longer matches the committed baseline:

```
DRIFT  classify.spam.ollama
      messages[0].content: "Classify the email. Reply with exactly one word from this list: spam, ham. Lowercase, no punctuation, nothing else." -> "Classify the email. Reply with exactly one word from this list: spam, ham, in lowercase. Lowercase, no punctuation, nothing else."

24 cases: 23 passed, 0 failed, 1 stale, 0 errors (exit 2)
```

The job fails with the annotation `stale baseline (ollama): classify.spam.ollama`,
and branch protection blocks the merge. Snapgate refuses to compare answers
produced by different prompts, so the baseline has to be re-recorded on
purpose:

```sh
snapgate check classify.spam.ollama     # exit 2, keeps the new answer under .snapgate/last/
snapgate diff classify.spam.ollama      # what the new prompt changed in the answer, if anything
snapgate accept classify.spam.ollama    # promotes it; commit .snapgate/baselines/classify.spam.ollama.json
```

Or, to record on the same hardware as the nightly, run the **record**
workflow with `mode: accept` and merge its pull request into the branch.
The baseline diff in the PR shows the old and new prompt side by side with
the old and new answer.

## Demo 2: nothing here changed, the model did

The nightly run finds a request whose fingerprint still matches its baseline
but whose answer does not. The job opens an issue titled
`Drift: ollama/qwen2.5:1.5b 2026-09-09` with the `drift` label. The body,
produced by `scripts/drift-report.sh`, looks like this (the diff is from a
local dry run; the fingerprint delta is illustrative):

````markdown
Nightly canary detected **upstream drift** on `ollama` / `qwen2.5:1.5b`.

Nothing in this repository changed: every request fingerprint still matches
its committed baseline. The answers did not.

## Cases (1 of 24 drifted)

| case | status | similarity to baseline | failing checks / error |
|---|---|---|---|
| `json.address.ollama` | fail | 0.980 | exact, similarity |
| ...

## Diffs

### json.address.ollama

```diff
   "postal_code": "BS1 4DJ",
-  "country": "GB"
+  "country": "UK"
 }
```

## Upstream fingerprint

Changed:

```diff
   "runtime": {
     "backend": "cpu",
     "context_length": "2048",
     "num_parallel": "1",
-    "ollama_version": "0.33.0"
+    "ollama_version": "0.34.0"
   }
```
````

The issue is keyed on a hash of the diffs, not the date. The next night, if
the diffs are the same, the job comments "still drifted, day 2" on the open
issue; if they differ, it opens a new issue that says which one it supersedes.
For the hosted backend the fingerprint section is a table of the `model`
string the endpoint reported at record time and in this run.

To re-baseline after reviewing the diff, run the **record** workflow with
`mode: accept` for that backend. It re-checks on the runner, promotes only
the drifted cases, and opens a pull request with the new baselines and
fingerprint. Merging it is the acknowledgement. Baselines are never written
on `main` by any workflow.

## Things to know before trusting a red badge

- **A CPU change is not model drift.** GitHub runners are not all the same
  machine. The fingerprint records the CPU model and core count; a drift
  issue whose fingerprint delta shows only a `host.cpu` change is hardware
  numerics, not the model. That is why it is in the fingerprint.
- **Hosted answers at temperature 0 with a seed are close to deterministic,
  not deterministic.** That is why summaries and code on `openai` use a
  similarity threshold. The similarity score is in every issue.
- **Pull requests from the `record` workflow do not trigger `gate`.** GitHub
  does not run workflows on events caused by the built-in token. Close and
  reopen the PR to run the gate, or merge on the strength of the record log.

## Setting it up in a fork

1. Add the `OPENAI_API_KEY` repository secret, or delete the `openai` jobs.
2. Settings → Actions → General → allow GitHub Actions to create pull
   requests. `record.yml` needs it.
3. Run the `record` workflow once with `backend: both`, `mode: record`, and
   merge its PR. That is the first set of baselines.
4. Branch protection on `main`: require the checks `snapgate check (ollama)`
   and `snapgate check (openai)`.

MIT licensed.
