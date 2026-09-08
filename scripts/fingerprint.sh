#!/usr/bin/env bash
# Print the upstream fingerprint of an Ollama model as one JSON object:
# what the model is (tag, digest, quantization, size, architecture), what is
# running it (Ollama version, context length, parallelism, CPU or GPU) and
# where (OS, arch, CPU model). Snapgate records none of this, so the canary
# commits it next to the baselines and diffs it on every run. Keys are sorted
# and volatile values (pull time, expiry) are left out so two runs on the same
# upstream produce byte-identical output.
#
#   scripts/fingerprint.sh [model] [host]     default qwen2.5:1.5b, http://localhost:11434
set -euo pipefail

model="${1:-qwen2.5:1.5b}"
host="${2:-http://localhost:11434}"

need() { command -v "$1" >/dev/null || { echo "$1 is required" >&2; exit 2; }; }
need curl; need jq

version="$(curl -sf "$host/api/version" | jq -r .version)"
tags="$(curl -sf "$host/api/tags")"
digest="$(printf '%s' "$tags" | jq -r --arg m "$model" '.models[] | select(.name == $m) | .digest')"
if [ -z "$digest" ]; then
  echo "model $model is not pulled on $host" >&2
  exit 1
fi
show="$(curl -sf "$host/api/show" -d "$(jq -cn --arg m "$model" '{model: $m}')")"

# Load the model with an empty prompt so /api/ps reports where it landed.
curl -sf "$host/api/generate" -d "$(jq -cn --arg m "$model" '{model: $m, keep_alive: "5m"}')" >/dev/null
ps="$(curl -sf "$host/api/ps")"
size_vram="$(printf '%s' "$ps" | jq -r --arg m "$model" '[.models[] | select(.name == $m) | .size_vram] | first // 0')"
size_total="$(printf '%s' "$ps" | jq -r --arg m "$model" '[.models[] | select(.name == $m) | .size] | first // 0')"
if [ "$size_vram" = "0" ]; then backend=cpu
elif [ "$size_vram" = "$size_total" ]; then backend=gpu
else backend=mixed
fi

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux)  cpu="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)" ;;
  Darwin) cpu="$(sysctl -n machdep.cpu.brand_string)" ;;
  *)      cpu="unknown" ;;
esac
cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"

jq -Sn \
  --arg model "$model" \
  --arg digest "$digest" \
  --argjson show "$show" \
  --arg version "$version" \
  --arg ctx "${OLLAMA_CONTEXT_LENGTH:-default}" \
  --arg par "${OLLAMA_NUM_PARALLEL:-default}" \
  --arg backend "$backend" \
  --arg os "$os" --arg arch "$arch" --arg cpu "$cpu" --argjson cores "$cores" \
  '{
    model: {
      tag: $model,
      digest: $digest,
      family: $show.details.family,
      parameter_size: $show.details.parameter_size,
      quantization_level: $show.details.quantization_level,
      format: $show.details.format,
      architecture: $show.model_info["general.architecture"],
      parameter_count: $show.model_info["general.parameter_count"],
      context_length: ($show.model_info | to_entries | map(select(.key | endswith(".context_length"))) | first | .value)
    },
    runtime: {
      ollama_version: $version,
      context_length: $ctx,
      num_parallel: $par,
      backend: $backend
    },
    host: {
      os: $os,
      arch: $arch,
      cpu: $cpu,
      cores: $cores
    }
  }'
