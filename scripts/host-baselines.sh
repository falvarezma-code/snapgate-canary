#!/usr/bin/env bash
# Baseline sets per SIMD class for the Ollama backend.
#
# On the runner's CPU path a local model's answer depends on which CPU
# kernels llama.cpp dispatches to, and that is decided by the instruction
# set the (virtual) machine exposes, not by the CPU model name. Measured
# 2026-09-10 on eight machines: every host exposing only AVX2 (AMD EPYC
# 7763 and 9V74 alike) gave one identical set of answers, every host
# exposing AVX-512 (AMD EPYC 9V45) gave another, and the two sets differ on
# the same 8 of 24 cases with similarity down to 0.35. Two VMs reporting
# the same CPU model can sit on different sides. For a local model the
# kernel class is part of the upstream, so baselines are kept per class
# under hosts/<class>/ and the matching set is copied into Snapgate's store
# before a comparison. Hosted backends are CPU-independent and stay in
# .snapgate/baselines/ directly.
#
# Classes, from the flags llama.cpp's dynamic dispatch keys on:
#   amx      avx512f plus AMX (Sapphire Rapids and later)
#   avx512   avx512f without AMX
#   avx2     avx2 only
#   baseline anything older
#
#   scripts/host-baselines.sh slug          print this machine's class
#   scripts/host-baselines.sh load [slug]   copy hosts/<slug>/baselines/ into .snapgate/baselines/
#                                           exit 1 when no set exists for the slug
#   scripts/host-baselines.sh save [slug]   move the backend's baselines and a fresh
#                                           fingerprint into hosts/<slug>/
#
# Environment:
#   SNAPGATE_CONFIG   config path (default snapgate.yaml)
#   BACKEND           provider whose cases are per-host (default ollama)
#   CPU_FLAGS         override flag detection (tests, or naming a set by hand)
set -euo pipefail

cmd="${1:?usage: $0 slug|load|save [slug]}"
config="${SNAPGATE_CONFIG:-snapgate.yaml}"
backend="${BACKEND:-ollama}"
here="$(cd "$(dirname "$0")/.." && pwd)"
store="$(cd "$(dirname "$config")" && pwd)/.snapgate/baselines"

detect_flags() {
  if [ -n "${CPU_FLAGS:-}" ]; then printf '%s' "$CPU_FLAGS"; return; fi
  case "$(uname -s)" in
    Linux)  sed -n 's/^flags[[:space:]]*: //p' /proc/cpuinfo | head -1 ;;
    Darwin) sysctl -n machdep.cpu.features machdep.cpu.leaf7_features 2>/dev/null | tr '\n' ' ' | tr '[:upper:]' '[:lower:]' ;;
    *)      echo "" ;;
  esac
}

has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

class_of() {
  local f="$1"
  if has "$f" avx512f && has "$f" amx_int8; then echo amx
  elif has "$f" avx512f; then echo avx512
  elif has "$f" avx2; then echo avx2
  else
    # Apple silicon and anything without x86 SIMD flags: one class per arch.
    case "$(uname -m)" in arm64|aarch64) uname -m ;; *) echo baseline ;; esac
  fi
}

slug="${2:-$(class_of "$(detect_flags)")}"
set_dir="$here/hosts/$slug"

cases() { yq -r ".cases[] | select(.provider == \"$backend\") | .name" "$config"; }

case "$cmd" in
  slug)
    printf '%s\n' "$slug"
    ;;
  load)
    if [ ! -d "$set_dir/baselines" ]; then
      echo "no baseline set for CPU class '$slug' (looked for hosts/$slug/baselines/)" >&2
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
    echo "loaded $n $backend baseline(s) for CPU class '$slug' from hosts/$slug/"
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
    echo "saved $n $backend baseline(s) and the fingerprint for CPU class '$slug' to hosts/$slug/"
    ;;
  *)
    echo "unknown command $cmd" >&2
    exit 2
    ;;
esac
