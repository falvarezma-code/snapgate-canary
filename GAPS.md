# GAPS.md

What this canary needs from Snapgate, what Snapgate has, and the smallest
change that would close each gap. Written against Snapgate commit
`3b89dc650ec4ecc75bf6b56cb660006437117fb8` (2026-09-03, `main`, no tags).
Nothing here modifies Snapgate; every gap has a workaround the canary uses.

## What exists

### Config (`snapgate.yaml`, `version: 1`)

Strict decoder: unknown keys anywhere are a config error (exit 3).

```yaml
version: 1
providers:
  <name>:
    type: openai-compatible      # or: fixture (dir: <path>)
    base_url: <url>              # default https://api.openai.com/v1; "/chat/completions" is appended
    api_key_env: <ENV_VAR>       # default OPENAI_API_KEY; must be set and non-empty at open time
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
      - {type: similarity, threshold: 0.9} # Levenshtein ratio vs baseline
      - {type: contains, value: "..."}
      - {type: not_contains, value: "..."}
      - {type: regex, pattern: "..."}      # RE2
      - {type: json_valid}
      - {type: json_schema, schema: path.json}   # draft 2020-12, path relative to config
      - {type: max_length, value: "200"}   # code points
      - {type: min_length, value: "1"}
```

YAML anchors and aliases survive the strict decoder (verified with a built
binary): `messages: &p [...]` in one case and `messages: *p` in another
works, so one prompt can be defined once and pointed at two backends.

### CLI

| Command | Notes |
|---|---|
| `snapgate record [case...] [--force]` | One provider call per case, writes `.snapgate/baselines/<case>.json`. Refuses to overwrite without `--force`. Stops at first error. |
| `snapgate check [case...] [--json]` | Calls the provider (`samples` times per case), runs checks, writes `.snapgate/last/<case>.json`. Every case runs even if one errors. |
| `snapgate diff <case>` | Unified diff of baseline vs. last checked response. No provider call. |
| `snapgate accept [case...]` | Promotes last checked response to baseline. Refuses if the case definition changed since that check. |
| `snapgate init` | Starter config; not used here. |

Global flags: `--config/-c <path>` (default `snapgate.yaml`; the store lives
at `<config dir>/.snapgate/`), `--ci` (terse, no color). Case selection is
by exact name only; unknown names are an error.

### Exit codes and how the canary maps them

| Exit | Snapgate status | Meaning | Canary meaning |
|---|---|---|---|
| 0 | `pass` | every check passed on every sample | no drift |
| 1 | `fail` | a check failed (e.g. `exact` vs baseline) | **upstream drift**: same request, different output. Open an issue. |
| 2 | `drift` | fingerprint of the case definition differs from the baseline's, or no baseline | **definition drift**: someone changed a prompt/param without re-recording. Blocks PRs in `gate.yml`; on `main` it is a repo bug, not model drift. |
| 3 | `error` | provider or config error: bad YAML, unset key env, HTTP non-2xx (429 included), timeout, malformed JSON | tool/network failure. Fail the job, no drift issue. |

Yes, Snapgate distinguishes output drift (1) from tool/network error (3),
and from prompt changes (2). When cases mix, the most severe code wins
(3 > 2 > 1), so the canary must use `check --json` and read the per-case
`status` (`pass|fail|drift|error`) plus `error` (message, e.g.
`... returned HTTP 429: ...`) rather than the process exit code alone.

Note the vocabulary clash: Snapgate's "drift" is *definition* drift. The
canary README uses "upstream drift" for exit 1 and "definition drift" for
exit 2.

On a definition-drift case, `check` still calls the provider, runs the
checks, and writes `.snapgate/last/`, so `snapgate diff <case>` afterwards
shows the output diff too (prefixed with a note about the fingerprint
change). That is exactly what the "PR changes one word of a system prompt"
demo needs: the DRIFT line shows `messages[i].content: "old" -> "new"` and
`fingerprint a -> b`, and `diff` shows what the output did.

### OpenAI-compatible provider

`type: openai-compatible` exists with `base_url`, `api_key_env`, `timeout`.
It POSTs `{model, messages, temperature, max_tokens, seed, n: 1}` with
`Authorization: Bearer <key>` and reads `choices[0].message.content`,
`model`, and `choices[0].finish_reason`. Both backends are covered by it.
Ollama's `/v1/chat/completions` accepts `temperature`, `seed`, `max_tokens`.

### Fingerprint

`sha256` over canonical JSON of `{provider: {name, type}, request: {model,
messages, temperature, max_tokens, seed}}` (ADR 0003). It answers "was this
baseline produced by the request I am about to send?" It is a *request*
fingerprint, not an *upstream* fingerprint (see G2).

The baseline file stores `provider`, the full `request`, and `response:
{text, model, finish_reason}`. `response.model` is whatever the endpoint
reports (Ollama: the tag, e.g. `qwen2.5:1.5b`; OpenAI-style hosts usually a
dated version such as `gpt-4o-mini-2024-07-18`). That field is the only
upstream identity Snapgate records.

### Temperature and seed

`temperature`, `seed`, `max_tokens` can be set under `defaults.params` and
overridden per case. Both are in the fingerprint. There is no per-provider
params block, but since both backends receive the same OpenAI-style body a
single `defaults.params` (temperature 0, seed 42) serves both.

## Gaps

| # | Gap | Canary workaround | Smallest Snapgate change |
|---|---|---|---|
| G1 | **No upstream fingerprint** (two asks: a per-provider describe hook, and capturing `system_fingerprint`). Nothing queries Ollama `/api/tags`, `/api/show`, `/api/version`, and the OpenAI `system_fingerprint` response field is dropped. Only `response.model` is kept. | `scripts/fingerprint.sh` captures Ollama version, digest, quantization, parameter size, context length; the workflow commits its output at record time under `fingerprints/ollama.json` and diffs it nightly. For the hosted backend, diff `response.model` between `.snapgate/baselines/` and `.snapgate/last/` with `jq`. | (a) Add `SystemFingerprint string \`json:"system_fingerprint,omitempty"\`` to `provider.Response`, filled from the OpenAI response (additive, omitempty; maintainer decides whether that needs a `schema_version` bump). (b) Optional `Describe(ctx, model) (map[string]string, error)` interface a provider may implement; the openai-compatible provider implements it for Ollama hosts by calling `<host>/api/show` and `/api/version`; result stored as `upstream: {...}` in the baseline and reported as a delta by `check`. Not part of the request fingerprint. |
| G2 | **No configurable snapshot path.** The baseline directory is hard-coded to `<config dir>/.snapgate/baselines/`; a `snapshots/` directory cannot be used. | Commit `.snapgate/baselines/` as the snapshot directory (`.snapgate/.gitignore` already excludes `last/`). README says so. Alternative: a `snapshots -> .snapgate/baselines` symlink; not recommended, it only helps browsing. | A global `--state-dir <path>` flag (or `store: <dir>` key) defaulting to `.snapgate`. |
| G3 | **No external prompt files.** Messages are inline YAML; there is no include or `content_file`. A `prompts/` directory cannot be consumed by Snapgate. | Prompts live inline in `snapgate.yaml`, grouped by comment headers (`# --- json-extraction ---`), one anchor per prompt reused by both backends. The repo has no `prompts/` directory. | `content_file: <path>` on a message, resolved against the config directory and inlined at load time so the fingerprint is unchanged. |
| G4 | **No case filter by provider or group**; selection is by exact name only. The nightly job must run one backend at a time. | Name convention `<group>.<case>.<backend>` (`json.invoice.ollama`). Workflows build the list with `yq '.cases[] \| select(.provider == "ollama") \| .name'` (`yq` is preinstalled on `ubuntu-latest`). | `--provider <name>` on `check` and `record`. |
| G5 | **No retry on 429/5xx** (listed in TODO). An HTTP 429 is exit 3, case status `error`, message contains `HTTP 429`. | `canary.yml` re-runs only cases whose status is `error` with a 429/5xx message, `snapgate check <those names>`, with backoff (30s, 60s, 120s) and a hard cap so the hosted budget is never exceeded. Results are merged with `jq` and `.snapgate/last/` is per-case so `diff` still works. | Retry in `openaicompat.Complete` on 429 and 5xx honoring `Retry-After`, bounded by `timeout`. |
| G6 | **API key is mandatory.** `api_key_env` must name a set, non-empty env var. Ollama needs no auth. | Set `OLLAMA_API_KEY=ollama` (any non-empty string) in the workflow and in the README's local steps. | Accept `api_key_env: none` (literal) to send no `Authorization` header. |
| G7 | **No passthrough for non-standard params.** Ollama's `num_ctx` cannot be sent; Ollama's `/v1` endpoint ignores it anyway. | Start the server with `OLLAMA_CONTEXT_LENGTH=2048 OLLAMA_NUM_PARALLEL=1 ollama serve` (documented env vars; the default context is 4096 and has changed across versions, so pin it). Record both in `fingerprints/ollama.json`. | `extra_body: {}` map on a provider entry, merged into the request. Decide explicitly whether it joins the fingerprint (it is part of the request, so it should). |
| G8 | **`snapgate --version` prints `dev`** for `go install` builds and baselines record `snapgate_version: dev`. No release tag exists. | Workflows pin `go install github.com/falvarezma-code/snapgate/cmd/snapgate@3b89dc650ec4ecc75bf6b56cb660006437117fb8`. Baselines will say `dev`. | Fall back to `debug.ReadBuildInfo().Main.Version` when `Version == "dev"`; tag `v0.1.0`. |
| G9 | **`check --json` carries no response text and `diff` has no JSON form.** The issue body needs the diff. | Loop over `fail` cases from the JSON and call `snapgate diff <case>` for each, concatenated into the issue body inside a fenced block. | `diff --json`, or `response.text` in the check report's sample results. |
| G10 | **Fingerprint covers provider name and type only**, not `base_url` or the model bytes. Repointing `ollama` at another host or re-pulling a re-tagged `qwen2.5:1.5b` is invisible to Snapgate until outputs change. | This is what the canary is for; G1's workaround supplies the identity delta. | Covered by G1(b). |
| G11 | **No GitHub Actions annotations** (`--format=github`, in TODO). | Not needed; the job log and the issue carry the report. | As listed in TODO. |
| G12 | **Exit 2 is called "drift"** in the CLI, README and JSON (`status: drift`), but it means the *case definition* changed, not the model. Consumers watching for model drift read it backwards. | This repo says "stale baseline" everywhere (`scripts/check.sh` prints it as `stale`) and reserves "drift" for exit 1. | Rename the status to `stale` (JSON `status: "stale"`, human label `STALE`, help text "stale baseline: case definition changed since it was recorded"). It is a contract change: README, golden files, and a note in the changelog. Keep exit code 2. |
| G13 | **Similarity scores are only reported on failure.** A passing `similarity` check has no message, so the score cannot be logged for a case that passed. | Every `exact` case also carries `similarity: 1`; the two fail together and the similarity message carries the score into the issue. Hosted cases with a 0.9 threshold only show a score when they fail. | Put the measured ratio in `check.Result` (e.g. `"score": 0.936`) for `similarity` regardless of pass or fail; it is already computed. |
| G14 | **Only `temperature`, `max_tokens`, `seed` can be sent**, and always under those names. Newer OpenAI models reject `temperature`/`seed` and require `max_completion_tokens`; Ollama's `num_ctx` has no home either. | Pick a model that accepts the classic trio (`gpt-4o-mini`); pin `num_ctx` server-side (G7). | Same as G7: an `extra_body` map on the provider merged into the request, plus a provider setting to rename `max_tokens`. |

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
`temperature` and `seed` and wants `max_completion_tokens` instead of
`max_tokens`, so it cannot be driven by the current provider (see G14);
`gpt-4.1-nano` is cheaper but scheduled for removal on 2026-10-23. The alias
rather than the dated snapshot is used on purpose: an alias re-pointed to a
new snapshot is upstream drift, and `response.model` in the baseline shows
the dated name before and after.

Consequences: the zero-secret path is gone, forks without the secret skip
the hosted gate job, and the nightly fails loudly if the secret is missing.
Snapgate needed no change.

## Not gaps, but worth knowing

- `record` stops at the first error; `check` does not. Initial snapshot
  generation is a local Ollama run, so this only matters for the hosted
  backend's first `record`.
- `check` writes `.snapgate/last/` even on pass. `accept` is the only
  snapshot-update path besides `record --force`; neither runs on `main` in
  this repo.
- `similarity` is Levenshtein over code points, O(n*m); fine for short
  outputs.
- `json_valid` rejects fenced ```` ```json ```` blocks by design. Prompts
  must say "JSON only, no code fences"; a model that starts fencing is a
  legitimate drift signal.
- Local validation on 2026-09-08 (Ollama 0.33.0, Apple M1, GPU): all 24
  Ollama cases pass their structural checks, and `scripts/determinism.sh`
  reported 10/10 identical answers for the cases tried. Those answers are
  not committed; baselines come from a runner (`record.yml`).
- `qwen2.5:1.5b` wraps code in fences despite being told not to. The
  code-gen checks therefore anchor on the `def` line and leave fences to
  the baseline comparison.
