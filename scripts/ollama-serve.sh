#!/usr/bin/env bash
# Start (or restart) an Ollama server with the settings this canary pins,
# and wait until it answers. Used by the setup-ollama action and by the
# record workflow, which restarts the server between its record and verify
# passes so both see the same empty prompt cache.
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
# prompt depends on whether that prompt (or a prefix of it) is already in
# the server's KV cache. The first request processes the prompt in one
# batch; a repeat reuses cached state and takes a different numeric path,
# and greedy decoding can then diverge. Answers are identical whenever the
# server history is identical, so every comparison in this repo starts from
# a fresh server and sends the cases once, in config order.
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
