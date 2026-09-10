#!/usr/bin/env bash
# Run one case N times through Snapgate and report whether every response was
# identical. Local experiment only: nothing here is used by the workflows.
#
#   scripts/determinism.sh <case> [N]        default N=10
#
# The case is executed exactly as `snapgate check` would send it (same model,
# messages, temperature, seed, max_tokens), by running `check` in a scratch
# copy of the config and reading back the response Snapgate kept under
# .snapgate/last/. No baseline is needed: a missing baseline makes `check`
# exit 2 (status "missing"), which is fine here; the provider is still called.
#
# Set BEFORE_RUN to a command to execute before every request, for example
# BEFORE_RUN=scripts/ollama-serve.sh to restart the server so each request
# sees an empty prompt cache. Without it, run 1 is a cold prompt and runs
# 2..N are cache hits, which on the runner's CPU is a different answer.
#
# Exit 0 when all N responses match, 1 otherwise. Outputs are left under
# .determinism/<case>/ for inspection.
set -euo pipefail

case_name="${1:?usage: $0 <case> [N]}"
n="${2:-10}"
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.determinism/$case_name"

command -v snapgate >/dev/null || { echo "snapgate is not on PATH" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$here/snapgate.yaml" "$work/"
cp -R "$here/schemas" "$work/"
mkdir -p "$out"
rm -f "$out"/*.txt

for i in $(seq 1 "$n"); do
  if [ -n "${BEFORE_RUN:-}" ]; then
    $BEFORE_RUN >/dev/null
  fi
  # Exit 2 (missing baseline) is expected; only 3 means the provider failed.
  set +e
  snapgate --config "$work/snapgate.yaml" check --json "$case_name" > "$work/report.json"
  code=$?
  set -e
  if [ "$code" -eq 3 ]; then
    jq -r '.cases[0].error // "provider error"' "$work/report.json" >&2
    exit 2
  fi
  jq -r '.response.text' "$work/.snapgate/last/$case_name.json" > "$out/$i.txt"
  printf 'run %2d: %s\n' "$i" "$(shasum -a 256 "$out/$i.txt" | cut -c1-12)"
done

identical=0
for i in $(seq 1 "$n"); do
  if cmp -s "$out/1.txt" "$out/$i.txt"; then identical=$((identical + 1)); fi
done
echo "$identical/$n identical for $case_name"
if [ "$identical" -ne "$n" ]; then
  for i in $(seq 2 "$n"); do
    if ! cmp -s "$out/1.txt" "$out/$i.txt"; then
      echo "--- first mismatch: run 1 vs run $i ---"
      diff "$out/1.txt" "$out/$i.txt" || true
      break
    fi
  done
  exit 1
fi
