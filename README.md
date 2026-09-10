# snapgate-canary

[![canary](https://github.com/falvarezma-code/snapgate-canary/actions/workflows/canary.yml/badge.svg)](https://github.com/falvarezma-code/snapgate-canary/actions/workflows/canary.yml)

A language model is an untrusted upstream dependency: its answers can change
without a version bump, a changelog, or a diff. This repository pins 24
prompts and their answers with [Snapgate](https://github.com/falvarezma-code/snapgate),
the way a lockfile pins a library, and re-checks them every night against a
hosted model and a local one. When an answer changes and nothing in this
repository did, the change is recorded in public as an issue containing the
diff and the upstream fingerprint before and after.

There is no application code here. The repository is a consumer of Snapgate
v0.1.1: a config, committed baselines, and three workflows.

## Layout

| Path | What |
|---|---|
| [`snapgate.yaml`](snapgate.yaml) | Two providers (`ollama`, `openai`), 24 prompts in four groups, 44 cases. Each prompt is a YAML anchor shared by both backends. |
| [`.snapgate/baselines/`](.snapgate/baselines/) | The snapshots for the hosted backend. One JSON file per case: the exact request, the checks, the fingerprint, and the answer. Written only by the `record` workflow, on a runner. |
| [`hosts/<class>/`](hosts/) | The Ollama snapshots, one set per CPU SIMD class (`avx2`, `avx512`, `amx`), each with the upstream fingerprint it was recorded against: model digest and quantization, Ollama version, context length, CPU model and flags. [`scripts/host-baselines.sh`](scripts/host-baselines.sh) copies the matching set into place before a comparison. |
| [`fingerprints/`](fingerprints/) | The hosted backend's identity at record time: the alias requested and the dated model the endpoint reported. Snapgate does not record this; [`scripts/fingerprint.sh`](scripts/fingerprint.sh) does the Ollama side. |
| [`schemas/`](schemas/) | JSON Schemas for the extraction group. |
| [`scripts/`](scripts/) | `check.sh` (one backend, retries transient errors within a budget), `drift-report.sh` (issue body and dedupe key), `explain-exit.sh` (statuses to annotations), `fingerprint.sh`, `ollama-serve.sh` (start or restart the server with the pinned settings), `host-baselines.sh` (Ollama baseline sets per SIMD class), `determinism.sh` (experiments; the `determinism` workflow runs it on a runner). |
| [`.github/workflows/gate.yml`](.github/workflows/gate.yml) | On every pull request: check both backends. Anything but `pass` blocks the merge. |
| [`.github/workflows/canary.yml`](.github/workflows/canary.yml) | Nightly and on demand: check both backends, file or update drift issues. |
| [`.github/workflows/record.yml`](.github/workflows/record.yml) | On demand: record or accept baselines on the runner, verify them, open a pull request. |
| [`GAPS.md`](GAPS.md) | What this canary needed that Snapgate does not have, and the smallest change that would close each gap. |

## The two backends

| | `ollama` | `openai` |
|---|---|---|
| Model | `qwen2.5:1.5b`, Q4_K_M, pulled unpinned by tag | `gpt-4o-mini`, the alias, so provider-side version changes are observed |
| Where | Installed on the runner, keyless, `OLLAMA_CONTEXT_LENGTH=2048`, `OLLAMA_NUM_PARALLEL=1`, restarted before every case; baselines per CPU SIMD class | `https://api.openai.com/v1` with the `OPENAI_API_KEY` secret |
| Cases | all 24 | 20; at most 24 requests per check run including retries |
| Baseline check | `exact` | `exact` for extraction and classification, `similarity ≥ 0.9` for summaries and code |
| Params | temperature 0, seed 42, per-group `max_tokens` | same |

The original design used GitHub Models with the built-in token and no secret.
GitHub retired that service on 2026-07-30; see GAPS.md.

## Vocabulary

Snapgate gives every case one of five statuses. The nightly treats them
differently, and only one of them is news.

| Exit | Status | Meaning | Nightly action |
|---|---|---|---|
| 0 | `pass` | every check passed | nothing |
| 1 | `drift` | request unchanged, answer differs: **upstream moved** | open or update a `drift` issue; the job stays green |
| 1 | `drift` with an empty diff | the answer is unchanged but a check rejects it: the recording is wrong, not the model | fail the job, no issue |
| 2 | `stale` | a prompt, parameter, or check changed and the baseline was not re-recorded | fail the job, no issue |
| 2 | `missing` | no baseline recorded | fail the job, no issue |
| 3 | `error` | provider or config error: network, 429, missing key | retry transient errors, then fail the job, no issue |
| | not comparable | the runner's CPU SIMD class has no recorded Ollama baseline set | skip the Ollama comparison with a warning; job green |

A red badge therefore means the canary itself needs attention. Drift is in
the issues, not the badge.

## Local reproduction

Five commands. The local answers will not all match the committed baselines:
those were recorded on a GitHub runner CPU and floating point differs across
hardware, which is why baselines are recorded there and not on a laptop. The
diffs are the point.

```sh
go install github.com/falvarezma-code/snapgate/cmd/snapgate@v0.1.1
OLLAMA_CONTEXT_LENGTH=2048 OLLAMA_NUM_PARALLEL=1 ollama serve &
ollama pull qwen2.5:1.5b
scripts/check.sh ollama
snapgate diff json.address.ollama      # or any case the check reported as DRIFT
```

`scripts/determinism.sh <case> [N]` runs one case N times and reports how
many answers were identical. On an M1 with the settings above, 10 of 10 for
every case tried. Run it before trusting `exact` on new hardware.

## Demo 1: a pull request changes one word of a system prompt

The `classify.spam` prompt gains two words. The PR touches `snapgate.yaml`
only. The gate runs `snapgate check`, the case's fingerprint no longer
matches the committed baseline, and Snapgate refuses to compare answers
produced by different prompts:

```
STALE    classify.spam.ollama  request or checks changed since baseline
      messages[0].content: "Classify the email. Reply with exactly one word from this list: spam, ham. Lowercase, no punctuation, nothing else." -> "Classify the email. Reply with exactly one word from this list: spam, ham, in lowercase. Lowercase, no punctuation, nothing else."

24 cases: 23 passed, 0 drifted, 1 stale, 0 missing, 0 errors (exit 2)
```

The job fails with the annotation `stale baseline (ollama): classify.spam.ollama`
and branch protection blocks the merge until the baseline is re-recorded on
purpose. Locally:

```sh
snapgate check classify.spam.ollama     # exit 2; keeps the new answer under .snapgate/last/
snapgate diff classify.spam.ollama      # what the new prompt changed in the answer, if anything
snapgate accept classify.spam.ollama    # promotes it; commit .snapgate/baselines/classify.spam.ollama.json
```

Or, to record on the same hardware as the nightly, run the **record**
workflow with `mode: accept` and merge its pull request into the branch. The
baseline diff in that PR shows the old and new prompt next to the old and
new answer. Editing a check has the same effect as editing a prompt: checks
are part of the fingerprint.

## Demo 2: nothing here changed, the model did

The nightly run finds a case whose fingerprint still matches its baseline
but whose answer does not:

```
DRIFT    json.address.ollama  response changed, request unchanged
      exact: response differs from baseline; run `snapgate diff` to see how
      similarity: similarity to baseline is 0.980, threshold is 1.000; run `snapgate diff` to see how

24 cases: 23 passed, 1 drifted, 0 stale, 0 missing, 0 errors (exit 1)
```

The job opens an issue titled `Drift: ollama/qwen2.5:1.5b 2026-09-09` with
the `drift` label. The body, produced by `scripts/drift-report.sh`, looks
like this (the diff is from a local dry run; the fingerprint delta is
illustrative):

````markdown
Nightly canary detected **upstream drift** on `ollama` / `qwen2.5:1.5b`.

Nothing in this repository changed: every request fingerprint still matches
its committed baseline. The answers did not.

## Cases (1 of 24 drifted)

| case | status | similarity | model reported | detail |
|---|---|---|---|---|
| `json.address.ollama` | drift | 0.98 | `qwen2.5:1.5b` | exact, similarity |
| `json.product.ollama` | pass | 1 | `qwen2.5:1.5b` | |
| ...

## Diffs

### json.address.ollama

```diff
--- baseline/json.address.ollama
+++ current/json.address.ollama
@@ -2,5 +2,5 @@
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
For the hosted backend the fingerprint section is a table of the model name
the endpoint reported at record time and in this run, which is how an alias
quietly moving to a new dated snapshot shows up.

To re-baseline after reviewing the diff, run the **record** workflow with
`mode: accept` for that backend. It re-checks on the runner, promotes only
the drifted cases, verifies them with a second check, and opens a pull
request with the new baselines and fingerprint. Merging it is the
acknowledgement. Baselines are never written on `main` by any workflow.

## Things to know before trusting a red badge

- **For a local model, the CPU's instruction set is part of the upstream.**
  qwen2.5:1.5b on the CPU path has exactly two answers for 8 of the 24
  prompts, and which one a machine gives is decided by the SIMD
  instructions the VM exposes, which select the kernels Ollama runs. Eight
  determinism runs on GitHub's pool: every host exposing only AVX2 (AMD
  EPYC 7763 and 9V74) gave one identical set, every host exposing AVX-512
  (AMD EPYC 9V45) gave the other, and two VMs reporting the same CPU model
  can sit on different sides. The first nightly hit this across the two
  classes: 8 of 24 differed, similarity as low as 0.35
  ([issue #2](https://github.com/falvarezma-code/snapgate-canary/issues/2)).
  So Ollama baselines are kept per SIMD class under `hosts/<class>/`, each
  with the fingerprint it was recorded against, and a run loads the set
  for the class it landed on. A class with no set is reported as not
  comparable and the job stays green; run the `record` workflow with
  `if-host-unseen` until a run lands on it. The hosted backend is
  CPU-independent and has one set.
- **On the runner's CPU, the answer also depends on what Ollama's prompt
  cache already holds.** A prompt sent while the cache holds a different
  prompt can decode differently from the same prompt sent to an empty
  cache. Measured with the `determinism` workflow: on one CPU the
  empty-cache answer was identical across ten server restarts, while the
  first record run, which sent the cases back to back, disagreed with
  itself on 3 of 24. So every Ollama case here is sent to a freshly
  restarted server, in record, verify, gate and nightly alike, at the cost
  of a few seconds per case. A `snapgate check` against a server that has
  already answered something is not comparable to the baseline.
- **Hosted answers at temperature 0 with a seed are close to deterministic,
  not deterministic.** That is why summaries and code on `openai` use a
  similarity threshold. The similarity score is in every issue.
- **The record workflow verifies what it records.** `snapgate record` does
  not run the checks on the answer it stores, so `record.yml` re-runs the
  whole backend the way the nightly does. A check that rejects the model's
  honest answer blocks the PR for any backend; on Ollama so does an answer
  that differs on the second call, because Ollama answers are reproducible.
  On OpenAI a second-call difference is listed in the PR instead of blocking
  it: the first hosted record saw one extraction come back pretty-printed
  instead of compact, and low-rate hosted variance is what the nightly is
  there to record. It spends two hosted calls per case.
- **Pull requests from the `record` workflow do not trigger `gate`.** GitHub
  does not run workflows on events caused by the built-in token. Close and
  reopen the PR to run the gate, or merge on the strength of the record log.

## Development

```sh
git config core.hooksPath .githooks    # once per clone: commit-msg strips attribution trailers
actionlint .github/workflows/*.yml
shellcheck -S style scripts/*.sh
```

Commit conventions and the disclosure of how this repository is built are in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Setting it up in a fork

1. Add the `OPENAI_API_KEY` repository secret, or delete the `openai` jobs.
2. Settings → Actions → General → allow GitHub Actions to create pull
   requests. `record.yml` needs it.
3. Run the `record` workflow once with `backend: both`, `mode: record`, and
   merge its PR. That is the first set of baselines. Then run it a few more
   times with `backend: ollama`, `if-host-unseen: true`, merging each PR,
   until the nightly stops reporting "not comparable": each run records a
   set for whichever SIMD class it lands on. Three classes cover GitHub's
   current pool.
4. Branch protection on `main`: require the checks `snapgate check (ollama)`
   and `snapgate check (openai)`.

MIT licensed.
