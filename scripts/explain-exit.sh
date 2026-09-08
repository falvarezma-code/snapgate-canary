#!/usr/bin/env bash
# Turn a check report into GitHub Actions annotations that say what to do,
# one per status. Used by the gate and canary workflows after a failure.
#
#   scripts/explain-exit.sh <backend>
set -euo pipefail

backend="${1:?usage: $0 <backend>}"
report="${REPORT_DIR:-.snapgate/reports}/$backend.json"

if [ ! -s "$report" ] || ! jq -e .cases "$report" >/dev/null 2>&1; then
  echo "::error::snapgate ($backend) produced no report: configuration or install error, see the log above"
  exit 0
fi

names() { jq -r "[.cases[] | select($1) | .name] | join(\", \")" "$report"; }
error=$(names '.status == "error"')
stale=$(names '.status == "stale"')
missing=$(names '.status == "missing"')
drift=$(names '.status == "drift" and .diff != ""')
empty=$(names '.status == "drift" and .diff == ""')

[ -n "$error" ]   && echo "::error title=provider error ($backend)::$error. Not drift: network, rate limit, key or config. See the log."
[ -n "$stale" ]   && echo "::error title=stale baseline ($backend)::$stale. The prompt, parameters or checks changed and the baseline was not re-recorded. Run the record workflow with mode=accept, or locally: snapgate check <case> && snapgate accept <case>, then commit .snapgate/baselines/."
[ -n "$missing" ] && echo "::error title=missing baseline ($backend)::$missing. No baseline recorded. Run the record workflow with mode=record."
[ -n "$empty" ]   && echo "::error title=baseline fails its own checks ($backend)::$empty. The answer is unchanged but a check rejects it. Fix the check or the prompt, then re-record. Not upstream drift."
[ -n "$drift" ]   && echo "::error title=upstream drift ($backend)::$drift. Same request, different answer than the committed baseline. Unified diffs are in the log above; accept with the record workflow (mode=accept) if the new answer is right."
exit 0
