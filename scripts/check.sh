#!/usr/bin/env bash
# Run `snapgate check` for one backend's cases and retry transient provider
# errors without re-spending the whole request budget.
#
#   scripts/check.sh <backend>            backend is a provider name in snapgate.yaml
#
# Environment:
#   SNAPGATE_CONFIG      config path (default snapgate.yaml)
#   CASES                space-separated case names to run instead of every
#                        case of the backend
#   BEFORE_CASE          a command to run before every case; when set, cases
#                        are sent one at a time and the reports merged. The
#                        Ollama jobs set it to scripts/ollama-serve.sh so each
#                        request sees an empty prompt cache, the only state in
#                        which the runner's answers were measured reproducible
#   REPORT_DIR           where the merged JSON report goes (default .snapgate/reports)
#   RETRY_BUDGET         max provider calls spent on retries (default 4)
#   RETRY_DELAYS         backoff in seconds between rounds (default "30 60 120")
#
# Writes $REPORT_DIR/<backend>.json in the same shape as `snapgate check --json`
# and exits with Snapgate's exit code for the merged result: 0 pass, 1 drift
# (request unchanged, response differs), 2 stale or missing baseline,
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

if [ -n "${CASES:-}" ]; then
  # shellcheck disable=SC2086  # CASES is a space-separated list on purpose
  cases=$(printf '%s\n' $CASES)
else
  cases=$(yq -r ".cases[] | select(.provider == \"$backend\") | .name" "$config")
fi
[ -n "$cases" ] || { echo "no cases use provider $backend" >&2; exit 3; }

# Recompute the run status and exit code from the cases with Snapgate's
# severity order (ADR 0004): error > stale > missing > drift > pass.
# shellcheck disable=SC2016  # $sev and $exit are jq variables
recompute='
  ({pass: 0, drift: 1, missing: 2, stale: 3, error: 4}) as $sev
  | ({pass: 0, drift: 1, missing: 2, stale: 2, error: 3}) as $exit
  | .status = ([.cases[].status] | max_by($sev[.]) // "pass")
  | .exit_code = $exit[.status]'

# run_check <names> <out>: one `snapgate check --json` for all names, or,
# with BEFORE_CASE set, the hook and one check per case, appended into out.
run_check() {
  if [ -z "${BEFORE_CASE:-}" ]; then
    # shellcheck disable=SC2086
    snapgate --config "$config" check --json $1 > "$2" || true
    return
  fi
  rm -f "$2"
  for c in $1; do
    $BEFORE_CASE >/dev/null
    snapgate --config "$config" check --json "$c" > "$2.one" || true
    if [ ! -s "$2" ] || ! jq -e .cases "$2.one" >/dev/null 2>&1; then
      mv "$2.one" "$2"          # first case, or a config error to surface
      jq -e .cases "$2" >/dev/null 2>&1 || return 0
      continue
    fi
    jq -s ".[0] as \$a | .[1] as \$b | \$a | .cases += \$b.cases | $recompute" "$2" "$2.one" > "$2.tmp" \
      && mv "$2.tmp" "$2"
    rm -f "$2.one"
  done
}

# merge <report> <partial>: replace matching cases, recompute run status.
merge() {
  jq -s "
    .[0] as \$a | .[1] as \$b
    | (\$b.cases | map({key: .name, value: .}) | from_entries) as \$new
    | \$a | .cases |= map(\$new[.name] // .) | $recompute
  " "$1" "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

transient='HTTP (429|5[0-9][0-9])|timed out|connection refused|connection reset|EOF'

echo "check: $backend ($(echo "$cases" | wc -l | tr -d ' ') cases${BEFORE_CASE:+, one at a time after: $BEFORE_CASE})"
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

# Human summary in Snapgate's own vocabulary. Passing cases are one line;
# everything else says why and what fixes it.
jq -r '
  def failing: [.samples[]?.checks[]? | select(.passed | not) | "\n      \(.type): \(.message)"] | join("");
  .cases[]
  | "\(.status | ascii_upcase | . + " " * (7 - length))  \(.name)"
    + (if .status == "pass" then ""
       elif .status == "drift" and .diff == "" then "  baseline itself fails a check; fix the check or the prompt, then re-record" + failing
       elif .status == "drift" then "  response changed, request unchanged" + failing
       elif .status == "stale" then "  request or checks changed since baseline" + ((.fingerprint_changes // []) | map("\n      " + .) | join(""))
       elif .status == "missing" then "  no baseline recorded"
       else "\n      " + .error end)
' "$report"
jq -r '
  def n(s): [.cases[] | select(.status == s)] | length;
  "\n\(.cases | length) cases: \(n("pass")) passed, \(n("drift")) drifted, \(n("stale")) stale, \(n("missing")) missing, \(n("error")) errors (exit \(.exit_code))"
' "$report"

# The diffs of every drifted case, so a PR log or a nightly log is
# self-contained.
jq -r '.cases[] | select(.status == "drift" and .diff != "") | "\n" + .diff' "$report"

exit "$(jq -r .exit_code "$report")"
