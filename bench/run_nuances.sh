#!/usr/bin/env bash
# Host side for the nuance experiments. One container per experiment, each with the
# flags it needs. Works on the laptop (Git Bash / WSL) and on the VPS.
#
#   bash bench/run_nuances.sh                       # all experiments, RUNS=5
#   EXPS="import same" RUNS=1 bash bench/run_nuances.sh   # subset / smoke
#   OUT=/root/benchwerk-nuances CLEAN_IMAGE=1 bash run_nuances.sh   # VPS: results elsewhere, drop the image after
#
# cpu runs twice (1 and 2 cores); netem needs NET_ADMIN; disk_xdev mounts a tmpfs for uv's cache; stale sleeps 610 s per run (RUNS_STALE=3).
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
case $(uname -m) in
  aarch64) IMAGE="python:3.11-slim-bookworm@sha256:c31315ac2d5a3e36c7d40958a01f303a4dadd423710bb2cd62d1bab5220fac75" ;;
  *)       IMAGE="python:3.11-slim-bookworm@sha256:b1add8a6f2aca6bcfcf0b9c9b522352f7ce0d62a3d556a2f2f32511aa0cca250" ;;
esac
PIP_VERSION=26.2.1; UV_VERSION=0.12.15
CPUS=${CPUS:-4}; MEM=${MEM:-8g}; RUNS=${RUNS:-5}
EXPS=${EXPS:-"import same disk disk_xdev cpu mem netem stale sdist"}
N=$(nproc)   # cpusets use the LAST cores: vCPU 0 takes virtio/network IRQs on WSL2
OUT=${OUT:-results/$(date +%Y-%m-%d_%H%M)_nuances}; mkdir -p "$OUT"
abs() { if command -v cygpath >/dev/null 2>&1; then cygpath -ma "$1"; else realpath "$1"; fi; }   # Git Bash: Docker needs C:/... not /c/... or /tmp/...
BENCH=$(abs "$(pwd)/bench"); OUT_ABS=$(abs "$OUT")
[ -n "${CLEAN_IMAGE:-}" ] && trap 'docker image rm -f "$IMAGE" >/dev/null 2>&1 || true' EXIT

run() {  # run <EXP> [TAG] [extra docker args...]
  local exp=$1 tag=${2:-}; shift; shift || true
  echo "== $exp ${tag:+($tag)}"
  docker run --rm --cpus="$CPUS" --memory="$MEM" --cpu-shares=512 --name "benchwerk-nuance-$exp${tag:+-$tag}" "$@" \
    -e IMAGE="$IMAGE" -e CPUS="$CPUS" -e MEM="$MEM" -e PIP_VERSION="$PIP_VERSION" -e UV_VERSION="$UV_VERSION" -e RUNS="$RUNS" -e EXP="$exp" -e TAG="$tag" \
    -v "$BENCH:/bench:ro" -v "$OUT_ABS:/results" \
    "$IMAGE" bash /bench/nuances_inside.sh > "$OUT/console-$exp${tag:+-$tag}.txt" 2>&1 || echo "   $exp exited $? (see console)"
}

for exp in $EXPS; do
  case $exp in
    cpu)       run cpu 1cpu --cpuset-cpus=$((N-1)) -e CPUSET=1
               run cpu 2cpu --cpuset-cpus=$((N-2)),$((N-1)) -e CPUSET=2 ;;
    disk_xdev) run disk_xdev "" --tmpfs /xdev:rw,size=4g -e UV_CACHE_DIR=/xdev/cache-uv ;;
    netem)     run netem "" --cap-add NET_ADMIN ;;
    why)       run why "" --cap-add SYS_PTRACE ;;
    stale)     run stale "" -e RUNS_STALE="${RUNS_STALE:-3}" ;;
    *)         run "$exp" "" ;;
  esac
done
echo "done -> $OUT"
