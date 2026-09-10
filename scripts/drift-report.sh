#!/usr/bin/env bash
# Build the body of a drift issue from a check report.
#
#   scripts/drift-report.sh <backend> <report.json> <outdir>
#
# Writes into <outdir>:
#   body.md   issue body: per-case table with similarity scores and reported
#             model names, the unified diffs, and the upstream fingerprint
#             before (committed) and after (this run)
#   key       hex digest of the diffs; two runs that produce the same diffs
#             produce the same key, so the nightly can tell "same drift,
#             day N" from "new drift"
#   model     the model name as configured for this backend
#
# Only cases with status "drift" and a non-empty diff count as upstream
# drift. A drift with an empty diff means the baseline itself fails a check
# (the request and the response are unchanged); it is listed separately and
# never keyed, because nothing upstream moved.
#
# Environment:
#   SNAPGATE_CONFIG   config path (default snapgate.yaml)
#   RUN_URL           link to the workflow run, if any
# shellcheck disable=SC2016  # markdown backticks inside printf formats are literal
set -euo pipefail

backend="${1:?usage: $0 <backend> <report.json> <outdir>}"
report="${2:?usage: $0 <backend> <report.json> <outdir>}"
out="${3:?usage: $0 <backend> <report.json> <outdir>}"
config="${SNAPGATE_CONFIG:-snapgate.yaml}"
here="$(cd "$(dirname "$0")/.." && pwd)"
store="$(cd "$(dirname "$config")" && pwd)/.snapgate"

for t in yq jq; do
  command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 3; }
done
mkdir -p "$out"

model=$(yq -r ".cases[] | select(.provider == \"$backend\") | .model" "$config" | sort -u | head -1)
printf '%s\n' "$model" > "$out/model"

total=$(jq -r '.cases | length' "$report")
ndrift=$(jq -r '[.cases[] | select(.status == "drift" and .diff != "")] | length' "$report")
nempty=$(jq -r '[.cases[] | select(.status == "drift" and .diff == "")] | length' "$report")

# --- diffs and the dedupe key ------------------------------------------------
# The JSON diff headers carry no timestamps, so the diffs hash as they are.
jq -r '.cases[] | select(.status == "drift" and .diff != "") | "### \(.name)\n\n```diff\n\(.diff)```\n"' "$report" > "$out/diffs.md"
jq -r '.cases[] | select(.status == "drift" and .diff != "") | "\(.name)\n\(.diff)"' "$report" \
  | shasum -a 256 | cut -c1-16 > "$out/key"

# --- upstream fingerprint: before (committed) vs after (this run) -------------
fp="$out/fingerprint.md"
: > "$fp"
case "$backend" in
  ollama)
    slug=$("$here/scripts/host-baselines.sh" slug)
    before="$here/hosts/$slug/fingerprint.json"
    after="$out/fingerprint.after.json"
    "$here/scripts/fingerprint.sh" "$model" > "$after"
    printf 'Baseline set: `hosts/%s/` (baselines are per CPU SIMD class for this backend).\n\n' "$slug" >> "$fp"
    if [ -f "$before" ]; then
      if d=$(diff -u --label "before (committed)" --label "after (this run)" "$before" "$after"); then
        printf 'Unchanged. The model bytes, quantization, Ollama version and host are the same as when this set was recorded.\n\n```json\n%s\n```\n' "$(cat "$after")" >> "$fp"
      else
        printf 'Changed:\n\n```diff\n%s\n```\n' "$d" >> "$fp"
      fi
    else
      printf 'No committed fingerprint for this set. This run:\n\n```json\n%s\n```\n' "$(cat "$after")" >> "$fp"
    fi
    ;;
  *)
    # Hosted backends: the only identity Snapgate keeps is the model name the
    # endpoint reports. Compare the committed baseline with this run.
    printf '| case | model at record | model in this run |\n|---|---|---|\n' >> "$fp"
    for c in $(jq -r '.cases[] | .name' "$report"); do
      b=$(jq -r '.response.model // "?"' "$store/baselines/$c.json" 2>/dev/null || echo "?")
      a=$(jq -r --arg c "$c" '.cases[] | select(.name == $c) | .response_model // "?" | if . == "" then "?" else . end' "$report")
      mark=""; [ "$a" != "$b" ] && mark=" **(changed)**"
      printf '| `%s` | `%s` | `%s`%s |\n' "$c" "$b" "$a" "$mark" >> "$fp"
    done
    printf '\nSnapgate does not record `system_fingerprint`; see GAPS.md G1.\n' >> "$fp"
    ;;
esac

# --- per-case table ----------------------------------------------------------
table=$(jq -r '
  def score: if .score == null then "n/a" else (.score * 1000 | round / 1000 | tostring) end;
  def failing: [.samples[]?.checks[]? | select(.passed | not) | .type] | unique | join(", ");
  def note:
    if .status == "drift" and .diff == "" then "baseline itself fails: " + failing
    elif .status == "drift" then failing
    elif .status == "error" then (.error | gsub("\\|"; "\\|"))
    elif .status == "stale" then ((.fingerprint_changes // []) | join("; "))
    else "" end;
  .cases[]
  | "| `\(.name)` | \(.status) | \(score) | `\(.response_model | if . == "" then "?" else . end)` | \(note) |"
' "$report")

# --- assemble ----------------------------------------------------------------
{
  printf '<!-- snapgate-canary drift-key: %s:%s -->\n' "$backend" "$(cat "$out/key")"
  printf 'Nightly canary detected **upstream drift** on `%s` / `%s`.\n\n' "$backend" "$model"
  printf 'Nothing in this repository changed: every request fingerprint still matches its committed baseline. The answers did not.\n\n'
  [ -n "${RUN_URL:-}" ] && printf 'Run: %s\n\n' "$RUN_URL"
  printf '## Cases (%s of %s drifted)\n\n' "$ndrift" "$total"
  printf '| case | status | similarity | model reported | detail |\n|---|---|---|---|---|\n%s\n\n' "$table"
  printf '## Diffs\n\n'
  cat "$out/diffs.md"
  if [ "$nempty" != "0" ]; then
    printf '## Not drift: baselines that fail their own checks\n\n'
    printf 'These cases returned exactly the baseline answer, but a check rejects it. The recording is wrong, not the model; the job is failed for them and they are not part of the drift key.\n\n'
    jq -r '.cases[] | select(.status == "drift" and .diff == "") | "- `\(.name)`: " + ([.samples[]?.checks[]? | select(.passed | not) | "\(.type): \(.message)"] | join("; "))' "$report"
    printf '\n'
  fi
  printf '## Upstream fingerprint\n\n'
  cat "$fp"
  printf '\n## Next\n\n'
  printf -- '- Same diff tomorrow: this issue gets a "still drifted" comment instead of a new issue.\n'
  printf -- '- New output is acceptable: run the **record** workflow with `mode: accept`, `backend: %s`. It re-checks, promotes only the drifted cases, verifies them, and opens a PR with the new baselines and fingerprint.\n' "$backend"
  printf -- '- New output is wrong: keep the baselines; the issue stays open as the public record.\n'
} > "$out/body.md"

echo "drift-report: $ndrift/$total drifted, $nempty with empty diff, key $(cat "$out/key"), body $(wc -c < "$out/body.md" | tr -d ' ') bytes"
