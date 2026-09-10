#!/usr/bin/env bash
# Per-CPU baseline sets for the Ollama backend.
#
# On the runner's CPU path a local model's answer depends on the CPU model:
# the same prompt on a fresh server is reproducible on one CPU and differs
# on another (measured 2026-09-10: 8 of 24 cases between an AMD EPYC 7763
# and an Intel Xeon Platinum 8370C, similarity down to 0.35). For a local
# model the CPU is part of the upstream, so baselines are kept per CPU
# under hosts/<slug>/ and the matching set is copied into Snapgate's store
# before a comparison. Hosted backends are CPU-independent and stay in
# .snapgate/baselines/ directly.
#
#   scripts/host-baselines.sh slug          print this machine's CPU slug
#   scripts/host-baselines.sh load [slug]   copy hosts/<slug>/baselines/ into .snapgate/baselines/
#                                           exit 1 when no set exists for the slug
#   scripts/host-baselines.sh save [slug]   move the backend's baselines and a fresh
#                                           fingerprint into hosts/<slug>/
#
# Environment:
#   SNAPGATE_CONFIG   config path (default snapgate.yaml)
#   BACKEND           provider whose cases are per-host (default ollama)
#   CPU_MODEL         override CPU detection (tests, or naming a set by hand)
set -euo pipefail

cmd="${1:?usage: $0 slug|load|save [slug]}"
config="${SNAPGATE_CONFIG:-snapgate.yaml}"
backend="${BACKEND:-ollama}"
here="$(cd "$(dirname "$0")/.." && pwd)"
store="$(cd "$(dirname "$config")" && pwd)/.snapgate/baselines"

detect_cpu() {
  if [ -n "${CPU_MODEL:-}" ]; then printf '%s' "$CPU_MODEL"; return; fi
  case "$(uname -s)" in
    Linux)  sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1 ;;
    Darwin) sysctl -n machdep.cpu.brand_string ;;
    *)      echo unknown ;;
  esac
}

# "Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz" -> intel-xeon-platinum-8370c
# "AMD EPYC 7763 64-Core Processor"                -> amd-epyc-7763
slug_of() {
  printf '%s' "$1" \
    | sed -E 's/\((R|TM|tm|r)\)//g; s/ CPU @ [0-9.]+ ?GHz//; s/ [0-9]+-Core//; s/ Processor//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

slug="${2:-$(slug_of "$(detect_cpu)")}"
set_dir="$here/hosts/$slug"

cases() { yq -r ".cases[] | select(.provider == \"$backend\") | .name" "$config"; }

case "$cmd" in
  slug)
    printf '%s\n' "$slug"
    ;;
  load)
    if [ ! -d "$set_dir/baselines" ]; then
      echo "no baseline set for CPU '$slug' (looked for hosts/$slug/baselines/)" >&2
      exit 1
    fi
    mkdir -p "$store"
    n=0
    for c in $(cases); do
      rm -f "$store/$c.json"
      if [ -f "$set_dir/baselines/$c.json" ]; then
        cp "$set_dir/baselines/$c.json" "$store/$c.json"
        n=$((n + 1))
      fi
    done
    echo "loaded $n $backend baseline(s) for CPU '$slug' from hosts/$slug/"
    ;;
  save)
    mkdir -p "$set_dir/baselines"
    n=0
    for c in $(cases); do
      if [ -f "$store/$c.json" ]; then
        mv "$store/$c.json" "$set_dir/baselines/$c.json"
        n=$((n + 1))
      fi
    done
    "$here/scripts/fingerprint.sh" > "$set_dir/fingerprint.json"
    echo "saved $n $backend baseline(s) and the fingerprint for CPU '$slug' to hosts/$slug/"
    ;;
  *)
    echo "unknown command $cmd" >&2
    exit 2
    ;;
esac
