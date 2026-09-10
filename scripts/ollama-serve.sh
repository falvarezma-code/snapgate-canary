#!/usr/bin/env bash
# Start (or restart) an Ollama server with the settings this canary pins,
# and wait until it answers. Used by the setup-ollama action once, and then
# by every Ollama job before every case (BEFORE_CASE in scripts/check.sh,
# the record loop in record.yml), so each request sees an empty prompt
# cache.
#
#   scripts/ollama-serve.sh
#
# Environment (defaults are the canary's pinned values):
#   OLLAMA_CONTEXT_LENGTH   default 2048
#   OLLAMA_NUM_PARALLEL     default 1
#   OLLAMA_KEEP_ALIVE       default 5m
#   OLLAMA_MODELS           default ~/.ollama/models
#   OLLAMA_LOG              default $RUNNER_TEMP/ollama.log or /tmp/ollama.log
#
# Why the cache matters: on the runner's CPU path the model's answer to a
# prompt depends on what the server's KV cache already holds. Measured with
# the determinism workflow: a prompt sent to a server whose cache holds a
# different prompt can decode differently from the same prompt sent to an
# empty cache, while the empty-cache answer was identical across ten
# restarts and across Intel and AMD runners. A restart costs a few seconds
# per case and buys an answer that does not depend on ordering.
set -euo pipefail

export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-2048}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-5m}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-$HOME/.ollama/models}"
log="${OLLAMA_LOG:-${RUNNER_TEMP:-/tmp}/ollama.log}"
host="${OLLAMA_HOST_URL:-http://localhost:11434}"

command -v ollama >/dev/null || { echo "ollama is not installed" >&2; exit 2; }
mkdir -p "$OLLAMA_MODELS"

# Stop a server started earlier by this script (or any `ollama serve`), and
# wait for the port to go quiet so the new process does not race it.
if pgrep -f "ollama serve" >/dev/null 2>&1; then
  pkill -f "ollama serve" || true
  for _ in $(seq 1 30); do
    curl -sf "$host/api/version" >/dev/null 2>&1 || break
    sleep 1
  done
fi

nohup ollama serve > "$log" 2>&1 &
for _ in $(seq 1 60); do
  if curl -sf "$host/api/version" >/dev/null 2>&1; then
    echo "ollama $(curl -sf "$host/api/version" | jq -r .version) ready: context_length=$OLLAMA_CONTEXT_LENGTH num_parallel=$OLLAMA_NUM_PARALLEL keep_alive=$OLLAMA_KEEP_ALIVE"
    exit 0
  fi
  sleep 1
done
echo "ollama did not become ready; log follows" >&2
cat "$log" >&2
exit 1
