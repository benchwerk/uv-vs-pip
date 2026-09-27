#!/usr/bin/env bash
# Same benchmark, run on a VPS instead of the laptop. Identical inside.sh, identical
# requirements, identical tool versions; only the image digest (arm64) and the
# resource limits differ, and both are recorded in env.json.
#
# The VPS hosts other services. This script: uses a throwaway work dir, runs the
# container with LOW CPU priority (--cpu-shares=512: it yields the moment anything
# else wants CPU; the cap itself is unchanged so the numbers stay comparable),
# never touches other containers, and removes the work dir and pulled image on exit.
# Results are ALWAYS kept, even from a failed run.
#
# Usage on the VPS (as a transient unit, so it survives the SSH session):
#   systemd-run --unit=benchwerk --collect -p WorkingDirectory=/root/benchwerk-bench \
#     --setenv=RUNS=5 --setenv=OUT=/root/benchwerk-results --setenv=HOME=/root bash run_vps.sh
set -euo pipefail
ARCH=$(uname -m)
case $ARCH in
  aarch64) IMAGE="python:3.11-slim-bookworm@sha256:c31315ac2d5a3e36c7d40958a01f303a4dadd423710bb2cd62d1bab5220fac75" ;;  # arm64/v8, pinned 2026-09-16
  x86_64)  IMAGE="python:3.11-slim-bookworm@sha256:b1add8a6f2aca6bcfcf0b9c9b522352f7ce0d62a3d556a2f2f32511aa0cca250" ;;  # amd64, same as run.sh
  *) echo "unsupported arch $ARCH"; exit 1 ;;
esac
PIP_VERSION=26.2.1; UV_VERSION=0.12.15
CPUS=${CPUS:-4}; MEM=${MEM:-8g}
WORK=$(mktemp -d /tmp/benchwerk-uvpip.XXXXXX)
OUT=${OUT:-$HOME/benchwerk-results-$(date +%Y-%m-%d_%H%M)}

cleanup() {  # keep whatever results exist (even from a failed run), then remove everything else
  if [ -d "$WORK/results" ]; then mkdir -p "$OUT"; cp -r "$WORK/results/." "$OUT/"; fi
  rm -rf "$WORK"
  docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
  echo "cleaned up work dir and image; results (if any) in $OUT"
}
trap cleanup EXIT

cp -r "$(dirname "$0")" "$WORK/bench"; mkdir -p "$WORK/results"
rc=0
docker run --rm --cpus="$CPUS" --memory="$MEM" --cpu-shares=512 --name benchwerk-uvpip \
  -e IMAGE="$IMAGE" -e CPUS="$CPUS" -e MEM="$MEM" -e PIP_VERSION="$PIP_VERSION" -e UV_VERSION="$UV_VERSION" -e RUNS="${RUNS:-5}" \
  -v "$WORK/bench:/bench:ro" -v "$WORK/results:/results" \
  "$IMAGE" bash /bench/inside.sh > "$WORK/results/console.txt" 2>&1 || rc=$?
echo "container exit code: $rc"
