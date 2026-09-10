# GAPS.md

What this canary needs from Snapgate, what Snapgate has, and the smallest
change that would close each gap. Written against Snapgate **v0.1.1**
(commit `42a36ab`, 2026-09-08). Nothing here modifies Snapgate; every open
gap has a workaround the canary uses.

## What exists (v0.1.1)

### Config (`snapgate.yaml`, `version: 1`)

Strict decoder: unknown keys anywhere are a config error (exit 3).

```yaml
version: 1
providers:
  <name>:
    type: openai-compatible      # or: fixture (dir: <path>)
    base_url: <url>              # default https://api.openai.com/v1; "/chat/completions" is appended
    api_key_env: <ENV_VAR>       # optional; omit for keyless endpoints (no Authorization header)
    timeout: 60s                 # per request
defaults:                        # applied to any case that omits the field
  provider: <name>               # implicit when only one provider is defined
  model: <model>
  samples: 1
  params: {temperature: 0, max_tokens: 256, seed: 42}
cases:
  - name: <[A-Za-z0-9][A-Za-z0-9_.-]*>   # no slashes; used as the baseline filename
    provider: <name>
    model: <model>
    samples: 1
    params: {temperature: 0, max_tokens: 256, seed: 42}
    messages: [{role: system|user|assistant, content: "..."}]
    checks:
      - {type: exact}                      # byte-identical to baseline
      - {type: normalized}                 # equal after lowercasing + whitespace collapse
      - {type: similarity, threshold: 0.9} # Levenshtein ratio vs baseline; reports a score pass or fail
      - {type: contains, value: "..."}
      - {type: not_contains, value: "..."}
      - {type: regex, pattern: "..."}      # RE2
      - {type: json_valid}
      - {type: json_schema, schema: path.json}   # draft 2020-12, path relative to config
      - {type: max_length, value: "200"}   # code points
      - {type: min_length, value: "1"}
```

YAML anchors and aliases survive the strict decoder (verified), so one
prompt can be defined once and pointed at two backends.

### CLI

| Command | Notes |
|---|---|
| `snapgate record [case...] [--force]` | One provider call per case, writes `.snapgate/baselines/<case>.json` (schema v2, includes the checks). Refuses to overwrite without `--force`. Stops at first error. Does **not** run the checks on what it records. |
| `snapgate check [case...] [--json]` | Calls the provider (`samples` times per case), runs checks, writes `.snapgate/last/<case>.json`. Every case runs even if one errors. |
| `snapgate diff <case>` | Unified diff of baseline vs. last checked response. No provider call. |
| `snapgate accept [case...]` | Promotes last checked response to baseline. Refuses if the request or checks changed since that check. |
| `snapgate --version` | Reports the module version for `go install ...@v0.1.1` builds; baselines carry it as `snapgate_version`. |

Global flags: `--config/-c <path>` (default `snapgate.yaml`; the store lives
at `<config dir>/.snapgate/`), `--ci` (terse, no color). Case selection is
by exact name only; unknown names are an error.

### Statuses and exit codes (ADR 0004)

| Exit | Status | Meaning | Canary action |
|---|---|---|---|
| 0 | `pass` | every check passed on every sample | nothing |
| 1 | `drift` | request unchanged, response differs: **upstream moved** | open or update a `drift` issue; job green |
| 2 | `stale` | prompt, params, or checks changed since the baseline was recorded | fail the job, no issue: a repo change slipped past the gate |
| 2 | `missing` | no baseline recorded | fail the job, no issue: run the record workflow |
| 3 | `error` | provider or config error: bad YAML, unset key env, any HTTP failure (429 included), timeout | retry transient errors, then fail the job, no issue |

Severity for a mixed run: error > stale > missing > drift > pass. The
process exit code alone cannot separate "one 429 plus three drifts" from
"one 429", so the canary reads per-case `status` from `check --json`.

One edge: `drift` with an empty `diff` means the kept response is
byte-identical to the baseline but a check still fails. Nothing upstream
moved; the baseline was recorded with an answer the checks reject. The human
report says "baseline itself fails <check>". See G15.

### `check --json` per case

`name`, `status`, `provider` (config entry name), `model` (requested),
`response_model` (what the endpoint reported; empty on error),
`fingerprint {expected, actual}`, `fingerprint_changes` (why it is stale, in
words), `diff` (unified diff of baseline vs. kept response, headers
`--- baseline/<case>` / `+++ current/<case>` with no timestamps; empty on
pass), `score` (similarity ratio of the kept sample, or `null` when the case
has no `similarity` check), `error`, `samples[].checks[] {type, passed,
message, score}`.

### Fingerprint

`sha256` over canonical JSON of `{provider: {name, type}, request: {model,
messages, temperature, max_tokens, seed}, checks: [...]}`. Checks are in it
since v0.1.1, with schema paths as written so the hash is machine-independent.
`samples` is excluded. It is a *request* fingerprint, not an *upstream*
fingerprint (G1).

### OpenAI-compatible provider

`type: openai-compatible` with `base_url`, `api_key_env` (optional), `timeout`.
Sends `{model, messages, temperature, max_tokens, seed, n: 1}`; reads
`choices[0].message.content`, `model`, `finish_reason`. A keyless request
answered 401/403 is reported as "no api_key_env configured for provider".

### Temperature and seed

Under `defaults.params` and per case, not per provider. Both backends take
the same wire format, so one `defaults.params` (temperature 0, seed 42) serves
both.

## Closed by v0.1.1

| Was | Now |
|---|---|
| G6: API key mandatory, dummy `OLLAMA_API_KEY` needed | `api_key_env` is optional; omit it for Ollama. |
| G8: `--version` printed `dev` for `go install` builds | Module version is reported and stamped into baselines. Tags `v0.1.0`, `v0.1.1` exist. |
| G9: no diff in `check --json` | Per-case `diff` field, timestamp-free headers. `drift-report.sh` reads it instead of calling `snapgate diff`. |
| G12: exit 2 called "drift" | Vocabulary is `pass/drift/stale/missing/error`; drift now means upstream moved. |
| G13 (most of it): similarity score only on failure | `score` on every `similarity` result, pass or fail, and at case level. |

## Open gaps

| # | Gap | Canary workaround | Smallest Snapgate change |
|---|---|---|---|
| G1 | **No upstream fingerprint** (two asks: a per-provider describe hook, and capturing `system_fingerprint`). `response_model` is now in the JSON, which covers the hosted alias-to-snapshot case, but nothing queries Ollama `/api/tags`, `/api/show`, `/api/version`, and the OpenAI `system_fingerprint` field is dropped. | `scripts/fingerprint.sh` captures Ollama version, digest, quantization, parameter size, context length, backend (CPU/GPU), arch and CPU model; `record.yml` commits it under `fingerprints/ollama.json` and the nightly diffs it. For OpenAI, `record.yml` writes `fingerprints/openai.json` from `response.model` and the nightly compares `response_model` per case. | (a) `SystemFingerprint string \`json:"system_fingerprint,omitempty"\`` on `provider.Response`, filled from the OpenAI response. (b) Optional `Describe(ctx, model) (map[string]string, error)` on a provider; the openai-compatible provider implements it for Ollama hosts via `/api/show` and `/api/version`; stored as `upstream: {...}` in the baseline and reported as a delta by `check`. Not part of the request fingerprint. |
| G2 | **No configurable snapshot path.** The baseline directory is hard-coded to `<config dir>/.snapgate/baselines/`. Beyond naming, this is what blocks keeping more than one baseline set per config: the Ollama backend needs one set per CPU SIMD class. | Hosted baselines stay in `.snapgate/baselines/`; Ollama sets live under `hosts/<class>/baselines/` and `scripts/host-baselines.sh` copies the matching one into the store before every run. | A global `--state-dir <path>` flag (or `store: <dir>` key) defaulting to `.snapgate`; the canary would pass `--state-dir hosts/<class>` and drop the copy step. |
| G3 | **No external prompt files.** Messages are inline YAML; no include or `content_file`. | Prompts live inline in `snapgate.yaml`, grouped by comment headers, one anchor per prompt reused by both backends. | `content_file: <path>` on a message, inlined at load so the fingerprint is unchanged. |
| G4 | **No case filter by provider or group**; selection is by exact name only. | Name convention `<group>.<case>.<backend>`; workflows build the list with `yq '.cases[] \| select(.provider == "ollama") \| .name'`. | `--provider <name>` on `check` and `record`. |
| G5 | **No retry on 429/5xx** (in TODO). A 429 is exit 3, case status `error`, message contains `HTTP 429`. | `scripts/check.sh` re-runs only cases whose error looks transient, with backoff and a call budget, and merges the JSON. | Retry in `openaicompat.Complete` on 429 and 5xx honoring `Retry-After`, bounded by `timeout`. |
| G7 | **No passthrough for non-standard params, and no renaming.** Ollama's `num_ctx` cannot be sent (Ollama's `/v1` ignores it anyway). Newer OpenAI models reject `temperature`/`seed` and want `max_completion_tokens`. | Pin `num_ctx` server-side: `OLLAMA_CONTEXT_LENGTH=2048 OLLAMA_NUM_PARALLEL=1 ollama serve`. Use `gpt-4o-mini`, which accepts the classic trio. | `extra_body: {}` map on a provider entry merged into the request (it is part of the request, so it joins the fingerprint), plus a setting to rename `max_tokens`. |
| G10 | **Fingerprint covers provider name and type only**, not `base_url` or the model bytes. Repointing `ollama` at another host or re-pulling a re-tagged `qwen2.5:1.5b` is invisible until outputs change. | This is what the canary is for; G1's workaround supplies the identity delta. | Covered by G1(b). |
| G11 | **No GitHub Actions annotations** (`--format=github`, in TODO). | `scripts/explain-exit.sh` emits `::error` annotations from the JSON. | As listed in TODO. |
| G13 | **`score` exists only when the case has a `similarity` check.** An `exact` case reports `score: null`. | Every `exact` case also carries `similarity: 1` (same pass condition) so the drift issue can show how far the answer moved. | Compute the ratio for every baseline-relative case, or make `exact` report one. |
| G15 | **`record` does not run the checks on what it records.** A baseline the checks reject is written silently and every later `check` reports `drift` with an empty diff ("baseline itself fails"). The nightly cannot tell that from upstream drift by status alone. | `record.yml` runs `check` after `record` and refuses to open the PR unless every recorded case is `pass`. The nightly treats `drift` with an empty diff as a job failure, not an issue. | `record` runs the checks on the recorded response and warns, or refuses without `--allow-failing`. |
| G16 | **No JSON-semantic comparison.** `exact` and `normalized` compare text, so `{"a":1}` and a pretty-printed `{\n  "a": 1\n}` are drift, and `similarity` scores that pair at 0.81 while a real value change scores 0.98. Observed on the first hosted record: gpt-4o-mini answered the same extraction compact once and pretty-printed the next time. | The extraction prompts ask for compact single-line JSON, which removes most of the formatting freedom; `exact` stays. | A `json_equal` check that parses both sides and compares canonical JSON (sorted keys, no whitespace); the structured JSON diff already in TODO would give it a readable failure. |

## External gap: GitHub Models is retired

Requested hosted backend: GitHub Models at `https://models.github.ai/inference`
with `permissions: models: read` and `GITHUB_TOKEN`.

Observed on 2026-09-08: both `/catalog/models` and
`/inference/chat/completions` return **HTTP 410** with
`{"error":{"code":"github_models_retirement_brownout", ...}}`. GitHub's
changelog says GitHub Models (playground, catalog, inference API, BYOK) was
fully retired on 2026-07-30 after brownouts on July 16 and 23; the 410 body
text is stale. No free successor is named.

**Decision (2026-09-08): OpenAI, model alias `gpt-4o-mini`, secret
`OPENAI_API_KEY`, at most 24 hosted requests per run.** It is the cheapest
current "mini" model ($0.15 in / $0.60 out per 1M tokens) that still accepts
the three parameters Snapgate sends. The `gpt-5*` family rejects
`temperature` and `seed` and wants `max_completion_tokens` (G7);
`gpt-4.1-nano` is cheaper but scheduled for removal on 2026-10-23. The alias
rather than the dated snapshot is used on purpose: an alias re-pointed to a
new snapshot is upstream drift, and `response_model` shows the dated name
before and after.

Consequences: the zero-secret path is gone, forks without the secret skip
the hosted gate job, and the nightly fails loudly if the secret is missing.
Snapgate needed no change.

## Not gaps, but worth knowing

- **On the runner's CPU, Ollama's answer depends on what its prompt cache
  holds, and on the SIMD instruction class the VM exposes.** Measured
  2026-09-10 with the `determinism` workflow, Ollama 0.34.0, qwen2.5:1.5b
  Q4_K_M. Cache: on a warm server a free-text prompt sent after a different
  prompt gives one answer and the same prompt repeated gives another, ten
  times identical; `OLLAMA_KEEP_ALIVE=0` made no difference; with the
  server restarted before every request, ten of ten identical. The first
  record run failed its verify pass for this (3 of 24 cases, one at 0.684
  similarity). Instruction class: eight fresh-server runs across GitHub's
  pool, one request per sensitive case each, gave exactly two answer
  families for the same 8 of 24 cases. Every host exposing `avx avx2 fma
  f16c` (AMD EPYC 7763 ×4, 9V74 ×2) produced one family byte for byte;
  every host exposing AVX-512 (`avx512f/bw/vl/_vnni/_bf16`, AMD EPYC 9V45
  ×2) produced the other. Two record runs on VMs both reporting "AMD EPYC
  9V74" had landed on opposite sides, which is what ruled out the CPU model
  as the key. Consequences in this repo: every Ollama case is sent to a
  freshly restarted server (`BEFORE_CASE` in `scripts/check.sh`), and
  Ollama baselines are kept per class (`avx2`, `avx512`, `amx`) under
  `hosts/<class>/`, with `scripts/host-baselines.sh` deriving the class
  from `/proc/cpuinfo` flags and loading the right set at run time. The
  cache part is not a Snapgate gap (no request option can choose the cache
  path, and Ollama's `/v1` endpoint exposes none anyway, G7). The per-class
  part is G2 and G1 in one: a `--state-dir` flag would replace the copy
  step, and a baseline keyed by upstream fingerprint would replace the
  whole script. It also means Snapgate's `samples: 2` on this backend
  would disagree with itself.
- **Checks are in the fingerprint now.** Tightening a similarity threshold
  on a hosted case makes it `stale` and costs a re-record. Plan check edits
  with prompt edits.
- `record` stops at the first error; `check` does not.
- `check` writes `.snapgate/last/` even on pass. `accept` is the only
  snapshot-update path besides `record --force`; neither runs on `main` in
  this repo.
- `json_valid` rejects fenced ```` ```json ```` blocks by design. Prompts say
  "JSON only, no code fences"; a model that starts fencing is legitimate
  drift.
- Local validation on 2026-09-08 (Ollama 0.33.0, Apple M1, GPU): all 24
  Ollama cases pass their structural checks, and `scripts/determinism.sh`
  reported 10/10 identical answers for the cases tried. Those answers are
  not committed; baselines come from a runner (`record.yml`).
- `qwen2.5:1.5b` wraps code in fences despite being told not to. The
  code-gen checks therefore anchor on the `def` line and leave fences to
  the baseline comparison.
