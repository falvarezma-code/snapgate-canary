#!/usr/bin/env bash
# Run `snapgate check` for one backend's cases and retry transient provider
# errors without re-spending the whole request budget.
#
#   scripts/check.sh <backend>            backend is a provider name in snapgate.yaml
#
# Environment:
#   SNAPGATE_CONFIG      config path (default snapgate.yaml)
#   REPORT_DIR           where the merged JSON report goes (default .snapgate/reports)
#   RETRY_BUDGET         max provider calls spent on retries (default 4)
#   RETRY_DELAYS         backoff in seconds between rounds (default "30 60 120")
#
# Writes $REPORT_DIR/<backend>.json in the same shape as `snapgate check --json`
# and exits with Snapgate's exit code for the merged result: 0 pass, 1 a check
# failed (upstream drift), 2 stale or missing baseline (definition drift),
# 3 provider error. Only cases whose error looks transient (HTTP 429, 5xx, a
# timeout, a refused connection) are retried; each retry round re-runs just
# those cases and their results replace the originals in the report.
set -euo pipefail

backend="${1:?usage: $0 <backend>}"
config="${SNAPGATE_CONFIG:-snapgate.yaml}"
report_dir="${REPORT_DIR:-.snapgate/reports}"
budget="${RETRY_BUDGET:-4}"
delays="${RETRY_DELAYS:-30 60 120}"

for t in snapgate yq jq; do
  command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 3; }
done

report="$report_dir/$backend.json"
mkdir -p "$report_dir"

# An unknown backend is a usage error, not an empty run.
yq -e ".providers.\"$backend\"" "$config" >/dev/null 2>&1 \
  || { echo "no provider named $backend in $config" >&2; exit 3; }

cases=$(yq -r ".cases[] | select(.provider == \"$backend\") | .name" "$config")
[ -n "$cases" ] || { echo "no cases use provider $backend" >&2; exit 3; }

# shellcheck disable=SC2086
run_check() { snapgate --config "$config" check --json $1 > "$2" || true; }

# merge <report> <partial>: replace matching cases, recompute run status.
merge() {
  jq -s '
    ({pass: 0, fail: 1, drift: 2, error: 3}) as $sev
    | (.[1].cases | map({key: .name, value: .}) | from_entries) as $new
    | .[0]
    | .cases |= map($new[.name] // .)
    | .exit_code = ([.cases[].status | $sev[.]] | max // 0)
    | .status = (($sev | to_entries | map({key: (.value|tostring), value: .key}) | from_entries)[.exit_code|tostring])
  ' "$1" "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

transient='HTTP (429|5[0-9][0-9])|timed out|connection refused|connection reset|EOF'

echo "check: $backend ($(echo "$cases" | wc -l | tr -d ' ') cases)"
run_check "$(echo "$cases" | tr '\n' ' ')" "$report"
# A config error exits 3 before any JSON is written; the message is on stderr.
jq -e .cases "$report" >/dev/null 2>&1 || { echo "snapgate wrote no report; see the error above" >&2; exit 3; }

round=0
for delay in $delays; do
  retry=$(jq -r --arg re "$transient" \
    '.cases[] | select(.status == "error" and (.error | test($re))) | .name' "$report")
  [ -n "$retry" ] || break
  n=$(echo "$retry" | wc -l | tr -d ' ')
  if [ "$n" -gt "$budget" ]; then
    echo "retry budget exhausted: $n transient errors, $budget calls left" >&2
    break
  fi
  round=$((round + 1))
  budget=$((budget - n))
  echo "retry round $round: $n transient error(s), sleeping ${delay}s"
  sleep "$delay"
  run_check "$(echo "$retry" | tr '\n' ' ')" "$report_dir/$backend.retry.json"
  merge "$report" "$report_dir/$backend.retry.json"
done
rm -f "$report_dir/$backend.retry.json"

# Human summary. Passing cases are one line; everything else says why.
jq -r '
  .cases[]
  | "\(.status | ascii_upcase | .[0:5] | . + " " * (5 - length))  \(.name)"
    + (if .status == "error" then "\n      " + .error
       elif .status == "drift" then
         (if .fingerprint.expected == null then "\n      no baseline recorded"
          else "\n      " + ((.drift // []) | join("\n      ")) end)
       else "" end)
    + ([.samples[]?.checks[]? | select(.passed | not) | "\n      \(.type): \(.message)"] | join(""))
' "$report"
jq -r '"\n\(.cases | length) cases: \([.cases[] | select(.status=="pass")] | length) passed, "
  + "\([.cases[] | select(.status=="fail")] | length) failed, "
  + "\([.cases[] | select(.status=="drift")] | length) stale, "
  + "\([.cases[] | select(.status=="error")] | length) errors (exit \(.exit_code))"' "$report"

# Show what changed for every failed case, so a PR log or a nightly log is
# self-contained.
for c in $(jq -r '.cases[] | select(.status == "fail") | .name' "$report"); do
  echo
  snapgate --config "$config" diff "$c" || true
done

exit "$(jq -r .exit_code "$report")"
