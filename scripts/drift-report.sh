#!/usr/bin/env bash
# Build the body of a drift issue from a check report.
#
#   scripts/drift-report.sh <backend> <report.json> <outdir>
#
# Writes into <outdir>:
#   body.md   issue body: per-case table with similarity scores, unified
#             diffs, and the upstream fingerprint before (committed) and
#             after (this run)
#   key       hex digest of the diffs with volatile headers removed; two runs
#             that produce the same diffs produce the same key
#   model     the model name as configured for this backend
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

for t in snapgate yq jq; do
  command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 3; }
done
mkdir -p "$out"

model=$(yq -r ".cases[] | select(.provider == \"$backend\") | .model" "$config" | sort -u | head -1)
printf '%s\n' "$model" > "$out/model"

failed=$(jq -r '.cases[] | select(.status == "fail") | .name' "$report")
total=$(jq -r '.cases | length' "$report")
nfail=$(printf '%s' "$failed" | grep -c . || true)

# --- diffs and the dedupe key ------------------------------------------------
diffs="$out/diffs.md"
: > "$diffs"
: > "$out/key.input"
for c in $failed; do
  d=$(snapgate --config "$config" diff "$c" 2>&1 || true)
  printf '### %s\n\n```diff\n%s\n```\n\n' "$c" "$d" >> "$diffs"
  # Drop the ---/+++ header lines: they carry record and check timestamps.
  printf '%s\n' "$c" >> "$out/key.input"
  printf '%s\n' "$d" | grep -vE '^(---|\+\+\+) ' >> "$out/key.input" || true
done
shasum -a 256 "$out/key.input" | cut -c1-16 > "$out/key"
rm -f "$out/key.input"

# --- upstream fingerprint: before (committed) vs after (this run) -------------
fp="$out/fingerprint.md"
: > "$fp"
case "$backend" in
  ollama)
    before="$here/fingerprints/ollama.json"
    after="$out/fingerprint.after.json"
    "$here/scripts/fingerprint.sh" "$model" > "$after"
    if [ -f "$before" ]; then
      if d=$(diff -u --label "before (committed)" --label "after (this run)" "$before" "$after"); then
        printf 'Unchanged. The model bytes, quantization, Ollama version and host are the same as when the baselines were recorded.\n\n```json\n%s\n```\n' "$(cat "$after")" >> "$fp"
      else
        printf 'Changed:\n\n```diff\n%s\n```\n' "$d" >> "$fp"
      fi
    else
      printf 'No committed fingerprint (`fingerprints/ollama.json` missing). This run:\n\n```json\n%s\n```\n' "$(cat "$after")" >> "$fp"
    fi
    ;;
  *)
    # Hosted backends: the only identity Snapgate keeps is response.model.
    printf '| case | model at record | model in this run |\n|---|---|---|\n' >> "$fp"
    for c in $(jq -r '.cases[] | .name' "$report"); do
      b=$(jq -r '.response.model // "?"' "$store/baselines/$c.json" 2>/dev/null || echo "?")
      a=$(jq -r '.response.model // "?"' "$store/last/$c.json" 2>/dev/null || echo "?")
      mark=""; [ "$a" != "$b" ] && mark=" **(changed)**"
      printf '| %s | `%s` | `%s`%s |\n' "$c" "$b" "$a" "$mark" >> "$fp"
    done
    printf '\nSnapgate does not record `system_fingerprint`; see GAPS.md.\n' >> "$fp"
    ;;
esac

# --- per-case table ----------------------------------------------------------
table=$(jq -r '
  def score:
    [.samples[]?.checks[]? | select(.type == "similarity")] as $s
    | if ($s | length) == 0 then "n/a"
      elif ($s[0].passed) then "≥ threshold"
      else ($s[0].message | capture("is (?<v>[0-9.]+),") | .v) end;
  def failing: [.samples[]?.checks[]? | select(.passed | not) | .type] | unique | join(", ");
  .cases[]
  | "| `\(.name)` | \(.status) | \(score) | \(if .status == "fail" then failing elif .status == "error" then (.error | gsub("\\|"; "\\|")) else "" end) |"
' "$report")

# --- assemble ----------------------------------------------------------------
{
  printf '<!-- snapgate-canary drift-key: %s:%s -->\n' "$backend" "$(cat "$out/key")"
  printf 'Nightly canary detected **upstream drift** on `%s` / `%s`.\n\n' "$backend" "$model"
  printf 'Nothing in this repository changed: every request fingerprint still matches its committed baseline. The answers did not.\n\n'
  [ -n "${RUN_URL:-}" ] && printf 'Run: %s\n\n' "$RUN_URL"
  printf '## Cases (%s of %s drifted)\n\n' "$nfail" "$total"
  printf '| case | status | similarity to baseline | failing checks / error |\n|---|---|---|---|\n%s\n\n' "$table"
  printf '## Diffs\n\n'
  cat "$diffs"
  printf '## Upstream fingerprint\n\n'
  cat "$fp"
  printf '\n## Next\n\n'
  printf -- '- Same diff tomorrow: this issue gets a "still drifted" comment instead of a new issue.\n'
  printf -- '- New output is acceptable: run the **record** workflow with `mode: accept`, `backend: %s`. It re-checks, promotes only the drifted cases, and opens a PR with the new baselines and fingerprint.\n' "$backend"
  printf -- '- New output is wrong: keep the baselines; the issue stays open as the public record.\n'
} > "$out/body.md"

echo "drift-report: $nfail/$total failed, key $(cat "$out/key"), body $(wc -c < "$out/body.md" | tr -d ' ') bytes"
