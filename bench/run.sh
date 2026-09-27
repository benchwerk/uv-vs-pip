#!/usr/bin/env bash
# Host side. Runs the benchmark in a pinned container and writes results/<date>/.
# Usage:  bash bench/run.sh            (RUNS=5 default; RUNS=1 for a smoke test)
# Works from Git Bash (MSYS_NO_PATHCONV stops path mangling of the volume mounts) and from WSL.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
IMAGE="python:3.11-slim-bookworm@sha256:b1add8a6f2aca6bcfcf0b9c9b522352f7ce0d62a3d556a2f2f32511aa0cca250"  # amd64, pinned 2026-09-15
PIP_VERSION=26.2.1   # latest on PyPI 2026-09-15
UV_VERSION=0.12.15   # latest on PyPI 2026-09-15
CPUS=4; MEM=8g
OUT="results/$(date +%Y-%m-%d_%H%M)"; mkdir -p "$OUT"          # results are immutable: new run, new directory
docker run --rm --cpus="$CPUS" --memory="$MEM"   -e IMAGE="$IMAGE" -e CPUS="$CPUS" -e MEM="$MEM" -e PIP_VERSION="$PIP_VERSION" -e UV_VERSION="$UV_VERSION" -e RUNS="${RUNS:-5}"   -v "$(pwd)/bench:/bench:ro" -v "$(pwd)/$OUT:/results"   "$IMAGE" bash /bench/inside.sh
echo "done -> $OUT"
