#!/usr/bin/env bash
# Turn the exit code in a check report into a GitHub Actions annotation that
# says what to do. Used by the gate and canary workflows after a failure.
#
#   scripts/explain-exit.sh <backend>
set -euo pipefail

backend="${1:?usage: $0 <backend>}"
report="${REPORT_DIR:-.snapgate/reports}/$backend.json"

if [ ! -s "$report" ] || ! jq -e .cases "$report" >/dev/null 2>&1; then
  echo "::error::snapgate ($backend) produced no report: configuration or install error, see the log above"
  exit 0
fi

names() { jq -r --arg s "$1" '[.cases[] | select(.status == $s) | .name] | join(", ")' "$report"; }
fail=$(names fail); drift=$(names drift); error=$(names error)

[ -n "$error" ] && echo "::error title=provider error ($backend)::$error. Not drift: network, rate limit, key or config. See the log."
[ -n "$drift" ] && echo "::error title=stale baseline ($backend)::$drift. The prompt or parameters changed and the baseline was not re-recorded. Review the diff in the log, then run the record workflow with mode=accept, or locally: snapgate check <case> && snapgate accept <case>, and commit .snapgate/baselines/."
[ -n "$fail" ] && echo "::error title=output changed ($backend)::$fail. Same request, different answer than the committed baseline. Unified diffs are in the log above."
exit 0
