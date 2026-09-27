#!/usr/bin/env bash
# Runs INSIDE the pinned container (see run.sh). Measures wall-clock install time
# for pip and uv across cache states. One line of JSONL per run. Nothing else.
set -euo pipefail
REQ=/bench/requirements.txt; OUT=/results/raw.jsonl; RUNS=${RUNS:-5}; mkdir -p /results/logs
export PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PIP_QUIET=1 UV_NO_PROGRESS=1
export PIP_CACHE_DIR=/tmp/cache-pip UV_CACHE_DIR=/tmp/cache-uv
PY=$(command -v python)
python -m pip install -q "pip==$PIP_VERSION" "uv==$UV_VERSION"
awk 'NR%5' "$REQ" > /tmp/partial.txt                      # drops every 5th line: 26 of 134 pins
# Rough downlink so the cold number can be reproduced elsewhere: time one large pinned wheel (numpy). Untimed otherwise.
MBPS=$(python - <<'PY'
import re, time, urllib.request
try:
    idx = urllib.request.urlopen("https://pypi.org/simple/numpy/", timeout=30).read().decode()
    url = re.search(r'https://[^"#]*numpy-1\.23\.5-cp311-cp311-manylinux_2_17_x86_64\.manylinux2014_x86_64\.whl', idx).group(0)
    t = time.perf_counter(); n = len(urllib.request.urlopen(url, timeout=120).read()); print(round(n * 8 / 1e6 / (time.perf_counter() - t)))
except Exception: print(0)
PY
)
python - <<EOF > /results/env.json
import json, platform, subprocess as sp, os
v = lambda c: sp.run(c, shell=True, capture_output=True, text=True).stdout.strip()
json.dump({"python": platform.python_version(), "python_path": "$PY", "pip": v("pip --version").split()[1], "uv": v("uv --version").split()[1],
  "os": v("cat /etc/os-release | grep PRETTY | cut -d= -f2"), "kernel": platform.release(), "host_cpus": int(v("nproc")),
  "cpu_cap": os.environ.get("CPUS"), "mem_cap": os.environ.get("MEM"), "tmp_filesystem": v("stat -f -c %T /tmp"),
  "image": os.environ.get("IMAGE"), "requirements_sha256": v("sha256sum $REQ").split()[0], "pins": int(v("grep -c '^[^#].*==' $REQ")),
  "partial_pins": int(v("grep -c '^[^#].*==' /tmp/partial.txt")), "partial_dropped": v("awk 'NR%5==0' $REQ | grep '^[^#].*==' | cut -d= -f1").split(),
  "runs_per_config": int(os.environ.get("RUNS", 5)), "index": "https://pypi.org/simple", "downlink_mbps_estimate": int("$MBPS" or 0),
  "pip_bytecode": "default (compiles .pyc on install)", "uv_bytecode": "default (does not compile)", "uv_interface": "uv pip install",
  "started_utc": v("date -u +%FT%TZ")}, open("/dev/stdout", "w"), indent=1)
EOF
: > "$OUT"

venv() { rm -rf /tmp/venv; if [ "$1" = pip ]; then python -m venv /tmp/venv && /tmp/venv/bin/pip install -q "pip==$PIP_VERSION"; else uv venv -q --python "$PY" /tmp/venv; fi; }
install() {  # $1 tool  $2 requirements file  [$3 extra flags]   — this is the timed command
  if [ "$1" = pip ]; then /tmp/venv/bin/pip install -q ${3:-} -r "$2"; else uv pip install -q --python /tmp/venv/bin/python ${3:-} -r "$2"; fi; }
prep_install() { local i; for i in 1 2 3; do install "$@" && return 0; echo "prepare retry $i: $*" >&2; sleep 15; done; return 1; }  # untimed; survive a PyPI blip

prepare() {  # put the machine in state $2 for tool $1, then leave a FRESH venv unless the state says otherwise
  case $2 in
    cold)           rm -rf /tmp/cache-$1; venv "$1" ;;
    warm|frozen|warm_nocompile) venv "$1"; prep_install "$1" "$REQ"; venv "$1" ;;          # cache full, venv empty
    partial)        rm -rf /tmp/cache-$1; venv "$1"; prep_install "$1" /tmp/partial.txt; venv "$1" ;;   # cache has 108 of 134
    noop)           venv "$1"; prep_install "$1" "$REQ" ;;                                 # venv already complete; install again
  esac; }

for tool in pip uv; do prepare "$tool" cold; prep_install "$tool" "$REQ" >/dev/null 2>&1 || true; done   # throwaway: warms CDN/DNS for both before any timing

for run in $(seq "$RUNS"); do
  [ $((run % 2)) -eq 1 ] && tools="pip uv" || tools="uv pip"          # alternate order per run: neither tool is always second
  for state in cold warm partial frozen noop warm_nocompile; do
    for tool in $tools; do
      prepare "$tool" "$state"
      flags=""; [ "$state" = frozen ] && flags="--no-deps"
      [ "$state" = warm_nocompile ] && [ "$tool" = pip ] && flags="--no-compile"   # uv: identical to warm; pip: skip .pyc compilation
      log="/results/logs/$tool-$state-$run.txt"; sync
      t0=$EPOCHREALTIME; install "$tool" "$REQ" "$flags" >"$log" 2>&1 && rc=0 || rc=$?; t1=$EPOCHREALTIME
      printf '{"tool":"%s","state":"%s","run":%d,"seconds":%.3f,"exit":%d,"t0":%.0f}\n' "$tool" "$state" "$run" "$(awk "BEGIN{print $t1-$t0}")" "$rc" "$t0" | tee -a "$OUT"
      if [ "$tool$state$run" = uvwarm1 ]; then   # did uv hardlink from cache, or fall back to copying? count link-counts across site-packages
        linked=$(find /tmp/venv/lib -path '*site-packages/*' -type f -links +1 | wc -l); single=$(find /tmp/venv/lib -path '*site-packages/*' -type f -links 1 | wc -l)
        printf '{"uv_hardlinked":%s,"files_hardlinked":%s,"files_copied_or_generated":%s}\n' "$([ "$linked" -gt "$single" ] && echo true || echo false)" "$linked" "$single" > /results/checks.json || true
      fi
    done
  done
done
