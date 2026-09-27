#!/usr/bin/env bash
# The nuance experiments. Runs INSIDE the pinned container; EXP selects which one.
# Same helpers, same workload, same tool versions as inside.sh. Output: /results/<EXP>[_<TAG>]/.
# Revised after two independent reviews (see editorial_log.md 2026-09-16).
#
#   import    install + FIRST import (11 heavy modules) for pip / uv / uv --compile-bytecode, plus a serial
#             `compileall -j1` reference so the deferred bytecode cost has a lower and an upper bound
#   same      did both tools install the same thing? venv baseline subtracted; RECORD content hashes diffed;
#             entry-point targets compared, not wrapper bytes
#   disk      venv and cache footprint per tool, bootstrap (pip/setuptools) excluded, .pyc bytes separated
#   disk_xdev uv with its cache on another filesystem (host --tmpfs): copies instead of hardlinks (a LOWER bound)
#   cpu       warm + cold + uv --compile-bytecode under a cpuset (host --cpuset-cpus; TAG=1cpu/2cpu)
#   mem       peak RSS of the largest process in the installer's tree (ru_maxrss), warm + cold
#   netem     cold installs with +0/+50/+150 ms one-way egress delay, interleaved per run, queue limit raised
#   stale     warm cache older than PyPI's 600 s index max-age: both tools revalidate 134 index pages (CI-shaped)
#   sdist     cold install of ONLY the four sdist-only pins in the workload, both tools: the build-isolation share
#   why       evidence for each mechanism: startup cost, cpu/wall + threads + connections, strace syscall census,
#             HTTP request census, cProfile of pip's non-bytecode time, uv's own phase timings (host: --cap-add SYS_PTRACE)
set -euo pipefail
EXP=${EXP:?set EXP}; TAG=${TAG:-}; REQ=/bench/requirements.txt; RUNS=${RUNS:-5}
OUT=/results/$EXP${TAG:+_$TAG}; mkdir -p "$OUT/logs"; : > "$OUT/raw.jsonl"
export PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 UV_NO_PROGRESS=1
export PIP_CACHE_DIR=/tmp/cache-pip UV_CACHE_DIR=${UV_CACHE_DIR:-/tmp/cache-uv}
PY=$(command -v python)
python -m pip install -q "pip==$PIP_VERSION" "uv==$UV_VERSION"; rm -rf /tmp/cache-pip   # pip's cache must not contain uv's wheel
BOOT='site-packages/(pip|setuptools|pkg_resources|_distutils_hack|wheel)(-|/|\.)|distutils-precedence\.pth|_virtualenv\.(pth|py)'
python - <<EOF > "$OUT/env.json"
import json, platform, subprocess as sp, os
v = lambda c: sp.run(c, shell=True, capture_output=True, text=True).stdout.strip()
json.dump({"exp": "$EXP", "tag": "$TAG", "python": platform.python_version(), "pip": v("pip --version").split()[1], "uv": v("uv --version").split()[1],
  "kernel": platform.release(), "arch": platform.machine(), "nproc_visible": int(v("nproc")), "affinity_cpus": len(os.sched_getaffinity(0)),
  "cgroup_cpu_max": v("cat /sys/fs/cgroup/cpu.max"), "cgroup_cpuset": v("cat /sys/fs/cgroup/cpuset.cpus.effective"),
  "cpu_cap": os.environ.get("CPUS"), "cpuset": os.environ.get("CPUSET"), "mem_cap": os.environ.get("MEM"),
  "uv_cache_dir": os.environ.get("UV_CACHE_DIR"), "uv_cache_fs": v("mkdir -p \$UV_CACHE_DIR; stat -f -c %T \$UV_CACHE_DIR"), "tmp_fs": v("stat -f -c %T /tmp"),
  "image": os.environ.get("IMAGE"), "requirements_sha256": v("sha256sum $REQ").split()[0], "runs": int(os.environ.get("RUNS", 5)),
  "sdist_only_pins": ["func-timeout==4.3.5", "pgsanity==0.2.9", "shortid==0.1.2", "wtforms-json==0.3.5"],
  "started_utc": v("date -u +%FT%TZ")}, open("/dev/stdout", "w"), indent=1)
EOF

venv() { rm -rf /tmp/venv; if [ "$1" = pip ]; then python -m venv /tmp/venv && /tmp/venv/bin/pip install -q "pip==$PIP_VERSION"; else uv venv -q --python "$PY" /tmp/venv; fi; }
install() { if [ "$1" = pip ]; then /tmp/venv/bin/pip install ${3:-} -r "$2"; else uv pip install --python /tmp/venv/bin/python ${3:-} -r "$2"; fi; }   # not -q: logs must be auditable
prep_install() { local i; for i in 1 2 3; do install "$@" >/dev/null 2>&1 && return 0; echo "prepare retry $i: $*" >&2; sleep 15; done; return 1; }
warm_caches() { for t in "$@"; do venv "$t"; prep_install "$t" "$REQ"; done; }
timed() {  # timed <logname> <cmd...>  -> prints "<seconds> <exit>"; never aborts the script
  # The log is written to the container's own filesystem while the clock runs and moved to /results afterwards:
  # /results may be a bind mount (measured: 0.47 s for 137 lines through virtiofs on Docker Desktop).
  local log="$OUT/logs/$1.txt" tmp="/tmp/timed.$$.log" rc=0; shift; sync
  local t0=$EPOCHREALTIME; "$@" >"$tmp" 2>&1 || rc=$?; local t1=$EPOCHREALTIME; mv -f "$tmp" "$log"; printf '%s %d\n' "$(awk "BEGIN{print $t1-$t0}")" "$rc"; }   # ONE line: "<seconds> <exit>"
now() { printf '%.0f' "$EPOCHREALTIME"; }
pycs()  { find /tmp/venv/lib -name '*.pyc' | { grep -vE "$BOOT" || true; } | wc -l; }
links() { find /tmp/venv/lib -path '*site-packages/*' -type f -links +1 | wc -l; }
order() { [ $(( $1 % 2 )) -eq 1 ] && echo "pip uv" || echo "uv pip"; }   # alternate tool order per run

IMPORTS="import numpy, pandas, pyarrow, sqlalchemy, celery, flask, cryptography, redis, marshmallow, jsonschema, wtforms"
SDISTS=$'func-timeout==4.3.5\npgsanity==0.2.9\nshortid==0.1.2\nwtforms-json==0.3.5'

case $EXP in

import)  # ---- the honest total: install + first import. Bytecode is paid by someone, sometime.
  warm_caches pip uv
  for run in $(seq "$RUNS"); do
    for cfg in pip uv uv_compile; do
      tool=${cfg%%_*}; flags=""; [ "$cfg" = uv_compile ] && flags="--compile-bytecode"
      venv "$tool"
      read -r inst rci < <(timed "$cfg-install-$run" install "$tool" "$REQ" "$flags"); p0=$(pycs)
      read -r imp1 rc1 < <(timed "$cfg-import1-$run" /tmp/venv/bin/python -c "$IMPORTS"); p1=$(pycs)
      read -r imp2 rc2 < <(timed "$cfg-import2-$run" /tmp/venv/bin/python -c "$IMPORTS")
      printf '{"cfg":"%s","run":%d,"install_s":%.3f,"first_import_s":%.3f,"second_import_s":%.3f,"total_s":%.3f,"pyc_after_install":%d,"pyc_after_first_import":%d,"exit_install":%d,"exit_import1":%d,"exit_import2":%d,"t0":%s}\n' \
        "$cfg" "$run" "$inst" "$imp1" "$imp2" "$(awk "BEGIN{print $inst+$imp1}")" "$p0" "$p1" "$rci" "$rc1" "$rc2" "$(now)" | tee -a "$OUT/raw.jsonl"
    done
    # upper bound on the deferred cost: compile EVERYTHING, serially, on a fresh uv venv (what pip does at install)
    venv uv; prep_install uv "$REQ"
    read -r ca rca < <(timed "compileall-j1-$run" /tmp/venv/bin/python -m compileall -q -j1 /tmp/venv/lib/python3.11/site-packages)
    printf '{"cfg":"compileall_j1_serial","run":%d,"install_s":0,"first_import_s":%.3f,"second_import_s":0,"total_s":%.3f,"pyc_after_install":0,"pyc_after_first_import":%d,"exit_install":0,"exit_import1":%d,"exit_import2":0,"t0":%s}\n' \
      "$run" "$ca" "$ca" "$(pycs)" "$rca" "$(now)" | tee -a "$OUT/raw.jsonl"
  done ;;

same)  # ---- did they install the same thing? subtract the empty-venv baseline, compare content not paths
  warm_caches pip uv
  snap() {  # $1 tool  $2 phase(base|full)
    (cd /tmp/venv && find lib bin -type f ! -type l ! -name '*.pyc' ! -path '*__pycache__*' | sort) > "$OUT/$1.$2.paths.txt"
    if [ "$2" = full ]; then
      # per-package content: every RECORD line except installer-specific ones (RECORD/INSTALLER/REQUESTED/direct_url/uv_build), .pyc entries (pip compiles, uv doesn't) and bin/ scripts (wrapper templates differ), sorted -> one hash per dist
      for d in /tmp/venv/lib/python3.11/site-packages/*.dist-info; do n=$(basename "$d"); echo "$n" | grep -qE '^(pip|setuptools|wheel|pkg_resources)-' && continue
        printf '%s %s\n' "$n" "$(grep -vE '^[^,]*(RECORD|INSTALLER|REQUESTED|direct_url\.json|uv_build\.json),|\.pyc,|^\.\./\.\./\.\./bin/' "$d/RECORD" | tr -d '\r' | sort | sha256sum | cut -c1-16)"; done | sort > "$OUT/$1.records.txt"   # pip writes RECORD with CRLF (csv module), uv with LF
      cat /tmp/venv/lib/python3.11/site-packages/flask-*.dist-info/INSTALLER > "$OUT/$1.installer.txt" 2>/dev/null || true
      # entry points: name -> target ("from X import Y" line), not the wrapper template
      for f in /tmp/venv/bin/*; do { [ -f "$f" ] && [ ! -L "$f" ] && t=$(head -c 4000 "$f" | grep -aE -m1 '^from .* import ') && echo "$(basename "$f") $t"; } || true; done | sort > "$OUT/$1.entrypoints.txt"
      if [ "$1" = pip ]; then /tmp/venv/bin/pip freeze 2>/dev/null | grep -viE '^(pip|setuptools|wheel)==' | sort > "$OUT/$1.freeze.txt"
      else uv pip freeze --python /tmp/venv/bin/python 2>/dev/null | sort > "$OUT/$1.freeze.txt"; fi
    fi; }
  venv pip; snap pip base; read -r s rc < <(timed same-pip-install install pip "$REQ"); snap pip full; echo "{\"tool\":\"pip\",\"install_s\":$s,\"exit\":$rc}" >> "$OUT/raw.jsonl"
  venv uv;  snap uv base;  read -r s rc < <(timed same-uv-install  install uv  "$REQ"); snap uv full;  echo "{\"tool\":\"uv\",\"install_s\":$s,\"exit\":$rc}"  >> "$OUT/raw.jsonl"
  python - "$OUT" <<'PY'
import json, sys, pathlib, re
o = pathlib.Path(sys.argv[1]); rd = lambda n: [l for l in open(o / n, encoding="utf-8", errors="replace").read().splitlines() if l.strip()]
normname = lambda l: re.sub(r"[-_.]+", "-", l.split("==")[0]).lower() + "==" + l.split("==")[1] if "==" in l else l
paths = {t: set(rd(f"{t}.full.paths.txt")) - set(rd(f"{t}.base.paths.txt")) for t in ("pip", "uv")}
recs = {t: dict(l.split(" ", 1) for l in rd(f"{t}.records.txt")) for t in ("pip", "uv")}
eps = {t: {k: v for k, v in (l.split(" ", 1) for l in rd(f"{t}.entrypoints.txt")) if not re.match(r"^(pip|activate)", k)} for t in ("pip", "uv")}   # venv bootstrap, not workload
frz = {t: {normname(l) for l in rd(f"{t}.freeze.txt")} for t in ("pip", "uv")}
boot = re.compile(r"site-packages/(pip|setuptools|pkg_resources|_distutils_hack|wheel)(-|/|\.)|distutils-precedence\.pth|_virtualenv\.(pth|py)")
pp, pu = {p for p in paths["pip"] if not boot.search(p)}, {p for p in paths["uv"] if not boot.search(p)}
common = set(recs["pip"]) & set(recs["uv"])
r = {"freeze_identical": frz["pip"] == frz["uv"], "freeze_only_pip": sorted(frz["pip"] - frz["uv"]), "freeze_only_uv": sorted(frz["uv"] - frz["pip"]),
     "dists_pip": len(recs["pip"]), "dists_uv": len(recs["uv"]), "dists_only_pip": sorted(set(recs["pip"]) - common), "dists_only_uv": sorted(set(recs["uv"]) - common),
     "dists_same_content": sum(1 for d in common if recs["pip"][d] == recs["uv"][d]), "dists_different_content": sorted(d for d in common if recs["pip"][d] != recs["uv"][d]),
     "files_installed_pip": len(pp), "files_installed_uv": len(pu), "files_only_pip": sorted(pp - pu)[:100], "files_only_pip_n": len(pp - pu), "files_only_uv": sorted(pu - pp)[:100], "files_only_uv_n": len(pu - pp),
     "entrypoints_pip": len(eps["pip"]), "entrypoints_uv": len(eps["uv"]), "entrypoints_only_pip": sorted(set(eps["pip"]) - set(eps["uv"])), "entrypoints_only_uv": sorted(set(eps["uv"]) - set(eps["pip"])),
     "entrypoints_different_target": sorted(k for k in set(eps["pip"]) & set(eps["uv"]) if eps["pip"][k] != eps["uv"][k]),
     "installer_field": {t: open(o / f"{t}.installer.txt").read().strip() for t in ("pip", "uv")},
     "note": "freeze equality is a tautology for a fully pinned file; the content test is dists_different_content"}
json.dump(r, open(o / "same_thing.json", "w"), indent=1); print(json.dumps({k: (v if isinstance(v, (int, bool, dict)) else len(v)) for k, v in r.items()}))
PY
  ;;

disk|disk_xdev)  # ---- footprint; xdev has UV_CACHE_DIR on a tmpfs (fastest possible copy source -> a lower bound on the penalty)
  tools="pip uv"; [ "$EXP" = disk_xdev ] && tools="uv"
  warm_caches $tools
  X="--exclude=pip --exclude=pip-* --exclude=setuptools --exclude=setuptools-* --exclude=pkg_resources --exclude=_distutils_hack --exclude=wheel-*"
  for run in $(seq "$RUNS"); do
    for tool in $tools; do
      venv "$tool"; read -r s rc < <(timed "$tool-warm-$run" install "$tool" "$REQ")
      c=/tmp/cache-$tool; [ "$tool" = uv ] && c=$UV_CACHE_DIR
      pycb=$(find /tmp/venv/lib -name '*.pyc' | { grep -vE "$BOOT" || true; } | xargs -r stat -c %s | awk '{s+=$1} END{print s+0}')
      printf '{"tool":"%s","run":%d,"warm_install_s":%.3f,"exit":%d,"venv_apparent_bytes":%d,"venv_actual_bytes":%d,"venv_pyc_bytes":%d,"cache_bytes":%d,"venv_plus_cache_actual_bytes":%d,"hardlinked_files":%d,"cache_fs":"%s","venv_fs":"%s","t0":%s}\n' \
        "$tool" "$run" "$s" "$rc" "$(du -sb $X /tmp/venv | cut -f1)" "$(du -s -B1 $X /tmp/venv | cut -f1)" "$pycb" "$(du -s -B1 "$c" | cut -f1)" "$(du -sc -B1 $X /tmp/venv "$c" | tail -1 | cut -f1)" "$(links)" "$(stat -f -c %T "$c")" "$(stat -f -c %T /tmp/venv)" "$(now)" | tee -a "$OUT/raw.jsonl"
    done
  done ;;

cpu)  # ---- warm, cold and uv --compile-bytecode under the host's cpuset; the compile is where core count bites
  warm_caches pip uv
  for run in $(seq "$RUNS"); do
    for state in warm cold; do
      for tool in $(order "$run"); do
        [ "$state" = cold ] && rm -rf "/tmp/cache-$tool"; venv "$tool"
        read -r s rc < <(timed "$tool-$state-$run" install "$tool" "$REQ")
        printf '{"cpuset":"%s","cfg":"%s","state":"%s","run":%d,"seconds":%.3f,"exit":%d,"t0":%s}\n' "${CPUSET:-all}" "$tool" "$state" "$run" "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
      done
    done
    venv uv; read -r s rc < <(timed "uv_compile-warm-$run" install uv "$REQ" --compile-bytecode)
    printf '{"cpuset":"%s","cfg":"uv_compile","state":"warm","run":%d,"seconds":%.3f,"exit":%d,"t0":%s}\n' "${CPUSET:-all}" "$run" "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
  done ;;

mem)  # ---- peak RSS of the largest process in the installer's tree (ru_maxrss of RUSAGE_CHILDREN), not container memory
  cat > /tmp/peakrss.py <<'PY'
import resource, subprocess, sys, time
t = time.perf_counter(); rc = subprocess.run(sys.argv[1:], stdout=sys.stderr).returncode
print(f"{time.perf_counter()-t:.3f} {resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss} {rc}")
PY
  warm_caches pip uv
  for run in $(seq "$RUNS"); do
    for state in warm cold; do
      for tool in $(order "$run"); do
        [ "$state" = cold ] && rm -rf "/tmp/cache-$tool"; venv "$tool"
        if [ "$tool" = pip ]; then cmd=(/tmp/venv/bin/pip install -r "$REQ"); else cmd=(uv pip install --python /tmp/venv/bin/python -r "$REQ"); fi
        read -r s kb rc < <(python /tmp/peakrss.py "${cmd[@]}" 2>/tmp/mem.log || echo "0 0 99"); mv -f /tmp/mem.log "$OUT/logs/$tool-$state-$run.txt"
        printf '{"tool":"%s","state":"%s","run":%d,"seconds":%.3f,"peak_rss_largest_process_mb":%.1f,"exit":%d,"t0":%s}\n' "$tool" "$state" "$run" "$s" "$(awk "BEGIN{print $kb/1024}")" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
      done
    done
  done ;;

netem)  # ---- cold installs with added one-way egress delay; delays interleaved per run; queue limit raised so nothing drops
  apt-get -qq update >/dev/null && apt-get -qq install -y iproute2 >/dev/null
  IP=$(python -c "import socket;print(socket.getaddrinfo('files.pythonhosted.org',443)[0][4][0])")
  tcp_ms() { python -c "
import socket,time,statistics
xs=[]
for _ in range(5):
    t=time.perf_counter(); socket.create_connection(('$IP',443),timeout=10).close(); xs.append((time.perf_counter()-t)*1000)
print(round(statistics.median(xs),1))" 2>/dev/null || echo -1; }
  for tool in pip uv; do rm -rf "/tmp/cache-$tool"; venv "$tool"; prep_install "$tool" "$REQ" || true; done   # throwaway: warm CDN/DNS
  for run in $(seq "$RUNS"); do
    for delay in 0 50 150; do
      tc qdisc replace dev eth0 root netem delay "${delay}ms" limit 1000000; ms=$(tcp_ms)
      for tool in $(order "$run"); do
        rm -rf "/tmp/cache-$tool"; venv "$tool"
        read -r s rc < <(timed "$tool-delay$delay-$run" install "$tool" "$REQ")
        tc -s qdisc show dev eth0 >> "$OUT/logs/tc-delay$delay-$run.txt"
        printf '{"added_delay_ms":%d,"tcp_connect_ms":%s,"tool":"%s","run":%d,"seconds":%.3f,"exit":%d,"t0":%s}\n' "$delay" "$ms" "$tool" "$run" "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
      done
    done
  done
  tc qdisc del dev eth0 root || true ;;

stale)  # ---- CI-shaped warm: cache populated, then left longer than PyPI's index max-age (600 s) before the timed install
  RUNS=${RUNS_STALE:-3}
  for run in $(seq "$RUNS"); do
    for tool in pip uv; do venv "$tool"; prep_install "$tool" "$REQ"; venv "$tool"; done   # both caches fresh, both venvs empty
    echo "sleeping 610 s (run $run)"; sleep 610
    for tool in $(order "$run"); do
      venv "$tool"   # untimed; /tmp/venv is shared, so each tool gets its own fresh venv right before timing
      read -r s rc < <(timed "$tool-stale-$run" install "$tool" "$REQ")
      printf '{"tool":"%s","state":"stale_610s","run":%d,"seconds":%.3f,"exit":%d,"t0":%s}\n' "$tool" "$run" "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
    done
  done ;;

sdist)  # ---- how much of a cold install is the four sdist-only pins (PEP 517 build isolation), both tools
  printf '%s\n' "$SDISTS" > /tmp/sdists.txt
  for tool in pip uv; do rm -rf "/tmp/cache-$tool"; venv "$tool"; prep_install "$tool" /tmp/sdists.txt || true; done   # throwaway
  for run in $(seq "$RUNS"); do
    for state in cold warm; do
      for tool in $(order "$run"); do
        [ "$state" = cold ] && rm -rf "/tmp/cache-$tool"; venv "$tool"
        read -r s rc < <(timed "$tool-sdist-$state-$run" install "$tool" /tmp/sdists.txt)
        printf '{"tool":"%s","state":"%s","pins":4,"run":%d,"seconds":%.3f,"exit":%d,"t0":%s}\n' "$tool" "$state" "$run" "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
      done
    done
  done ;;

why)  # ---- WHY: evidence for each claimed mechanism. Needs strace (apt) and --cap-add SYS_PTRACE from the host.
  # Revised after the independent WHY review (editorial_log.md 2026-09-17): child rusage via wait4 (not polluted by the
  # sampler's own forks), exit stamped by a waiter thread, process tree via task/*/children, strace totals de-duplicated,
  # pip --no-compile census, request census counts uv's own "Sending fresh GET request" lines, profiler-free phase timings.
  apt-get -qq update >/dev/null && apt-get -qq install -y strace iproute2 >/dev/null
  cat > /tmp/probe.py <<'PY'
# Runs a command; samples thread count (whole tree) and established :443 sockets while it runs; rusage of THAT child only.
import subprocess, sys, time, glob, re, os, threading
cmd = sys.argv[1:]; t0 = time.perf_counter(); p = subprocess.Popen(cmd, stdout=sys.stderr, stderr=sys.stderr)
done = {}
def waiter():
    _, status, ru = os.wait4(p.pid, 0); done["t"] = time.perf_counter(); done["st"] = status; done["ru"] = ru
threading.Thread(target=waiter, daemon=True).start()
def tree(pid):
    yield pid
    for f in glob.glob(f"/proc/{pid}/task/*/children"):
        try:
            for c in open(f).read().split(): yield from tree(int(c))
        except Exception: pass
def threads():
    n = 0
    for pid in tree(p.pid):
        try: n += int(re.search(r"Threads:\s+(\d+)", open(f"/proc/{pid}/status").read()).group(1))
        except Exception: pass
    return n
def conns():
    try: return subprocess.run(["ss", "-Htn", "state", "established", "( dport = :443 )"], capture_output=True, text=True).stdout.count("\n")
    except Exception: return 0
tm = cm = 0
while "t" not in done:
    tm = max(tm, threads()); cm = max(cm, conns()); time.sleep(0.05)
ru = done["ru"]; wall = done["t"] - t0; rc = os.waitstatus_to_exitcode(done["st"])
print(f"{wall:.3f} {ru.ru_utime:.3f} {ru.ru_stime:.3f} {tm} {cm} {ru.ru_maxrss} {rc}")
PY
  cat > /tmp/phases.py <<'PY'
# Profiler-free phase split: run pip with -v, stamp the wall clock when "Installing collected packages" appears.
import subprocess, sys, time
t0 = time.perf_counter(); mark = None
p = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
for line in p.stdout:
    if mark is None and line.startswith("Installing collected packages"): mark = time.perf_counter()
p.wait(); t1 = time.perf_counter()
print(f"{t1-t0:.3f} {(mark-t0) if mark else -1:.3f} {(t1-mark) if mark else -1:.3f} {p.returncode}")
PY
  probe() {  # probe <label> <state> <tool> [flags...]
    local label=$1 state=$2 tool=$3; shift 3
    [ "$state" = cold ] && rm -rf "/tmp/cache-$tool"; venv "$tool"
    local -a cmd; if [ "$tool" = pip ]; then cmd=(/tmp/venv/bin/pip install "$@" -r "$REQ"); else cmd=(uv pip install --python /tmp/venv/bin/python "$@" -r "$REQ"); fi
    sync; read -r wall ut st thr con rss rc < <(python /tmp/probe.py "${cmd[@]}" 2>/tmp/probe.log || echo "0 0 0 0 0 0 99"); mv -f /tmp/probe.log "$OUT/logs/$label.txt"
    printf '{"probe":"%s","tool":"%s","state":"%s","wall_s":%.3f,"cpu_user_s":%.3f,"cpu_sys_s":%.3f,"cpu_per_wall":%.2f,"peak_threads":%d,"peak_tcp443_conns":%d,"exit":%d,"t0":%s}\n' \
      "$label" "$tool" "$state" "$wall" "$ut" "$st" "$(awk "BEGIN{w=$wall; print ($ut+$st)/(w>0?w:1)}")" "$thr" "$con" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"; }

  # (a) startup: interpreter alone, pip's CLI, uv's binary
  venv pip
  for i in 1 2 3 4 5; do
    read -r s rc < <(timed "startup-python-$i" /tmp/venv/bin/python -c pass); printf '{"probe":"startup","tool":"python","state":"-","wall_s":%.3f,"exit":%d,"t0":%s}\n' "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
    read -r s rc < <(timed "startup-pip-$i" /tmp/venv/bin/pip --version); printf '{"probe":"startup","tool":"pip","state":"-","wall_s":%.3f,"exit":%d,"t0":%s}\n' "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
    read -r s rc < <(timed "startup-uv-$i" uv --version);              printf '{"probe":"startup","tool":"uv","state":"-","wall_s":%.3f,"exit":%d,"t0":%s}\n' "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
  done
  # (b,c) parallelism: cpu/wall, threads, connections — warm and cold, RUNS runs, alternating order
  warm_caches pip uv
  for run in $(seq "$RUNS"); do
    for state in warm cold; do for tool in $(order "$run"); do probe "par-$tool-$state-$run" "$state" "$tool"; done; done
  done
  # (d) syscall census: pip default, pip --no-compile, uv — warm and cold (strace -f -c; never on a timed path)
  strace_it() { local name=$1 state=$2 tool=$3; shift 3; local -a cmd
    if [ "$tool" = pip ]; then cmd=(/tmp/venv/bin/pip install "$@" -r "$REQ"); else cmd=(uv pip install --python /tmp/venv/bin/python "$@" -r "$REQ"); fi
    [ "$state" = cold ] && rm -rf "/tmp/cache-$tool"; venv "$tool"; strace -f -c -o "/tmp/strace.txt" "${cmd[@]}" >/dev/null 2>&1 || true; mv -f /tmp/strace.txt "$OUT/strace-$name-$state.txt"; }
  for state in warm cold; do strace_it pip $state pip; strace_it pip-nocompile $state pip --no-compile; strace_it uv $state uv; done
  # (e) request census: verbose logs of a cold install (pip -vv logs every GET; uv -vv logs "Sending fresh GET request for:")
  for tool in pip uv; do
    rm -rf "/tmp/cache-$tool"; venv "$tool"
    if [ "$tool" = pip ]; then /tmp/venv/bin/pip install -vv -r "$REQ" > /tmp/verbose.log 2>&1 || true
    else uv pip install -vv --python /tmp/venv/bin/python -r "$REQ" > /tmp/verbose.log 2>&1 || true; fi
    mv -f /tmp/verbose.log "$OUT/verbose-$tool-cold.txt"
  done
  # (f) profiler-free phase timings for pip warm --no-compile: (i) -v with the "Installing collected packages" boundary,
  #     (ii) --dry-run = resolve + prepare only, (iii) --no-index --find-links wheelhouse = no index-page parsing at all
  venv pip; /tmp/venv/bin/pip wheel -q -w /tmp/wheelhouse -r "$REQ" --no-deps >/dev/null 2>&1 || true   # untimed; builds the 4 sdists into wheels so (iii) needs no index
  for run in $(seq "$RUNS"); do
    venv pip; sync; read -r tot pre post rc < <(python /tmp/phases.py /tmp/venv/bin/pip install --no-compile -v -r "$REQ" 2>/dev/null || echo "0 -1 -1 99")
    printf '{"probe":"phases-nocompile","tool":"pip","state":"warm","run":%d,"total_s":%.3f,"before_install_s":%.3f,"install_s":%.3f,"exit":%d,"t0":%s}\n' "$run" "$tot" "$pre" "$post" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
    venv pip; read -r s rc < <(timed "dryrun-$run" /tmp/venv/bin/pip install --dry-run --no-compile -r "$REQ")
    printf '{"probe":"dryrun","tool":"pip","state":"warm","run":%d,"wall_s":%.3f,"exit":%d,"t0":%s}\n' "$run" "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
    venv pip; read -r s rc < <(timed "noindex-$run" /tmp/venv/bin/pip install --no-compile --no-index --find-links /tmp/wheelhouse -r "$REQ")
    printf '{"probe":"noindex-nocompile","tool":"pip","state":"warm","run":%d,"wall_s":%.3f,"exit":%d,"t0":%s}\n' "$run" "$s" "$rc" "$(now)" | tee -a "$OUT/raw.jsonl"
  done
  # (g) cProfile of pip warm --no-compile — kept for the function-level picture, labelled as inflated; phases come from (f)
  venv pip; /tmp/venv/bin/python -m cProfile -o /tmp/pip.prof -m pip install --no-compile -r "$REQ" >/dev/null 2>&1 || true
  cp -f /tmp/pip.prof "$OUT/pip.prof" || true
  # (h) uv's own phase timings
  venv uv; uv pip install -v --python /tmp/venv/bin/python -r "$REQ" > /tmp/uvv.log 2>&1 || true; mv -f /tmp/uvv.log "$OUT/verbose-uv-warm.txt"
  grep -aE "^(Resolved|Prepared|Installed|Audited|Uninstalled)" "$OUT/verbose-uv-warm.txt" > "$OUT/uv-phases-warm.txt" || true
  python - "$OUT" <<'PY'
import re, sys, json, pathlib, pstats, collections
o = pathlib.Path(sys.argv[1]); out = {}
pipv = open(o / "verbose-pip-cold.txt", encoding="utf-8", errors="replace").read()
uvv = open(o / "verbose-uv-cold.txt", encoding="utf-8", errors="replace").read()
gets = re.findall(r'"GET (/[^ ]*) HTTP', pipv)
out["pip_requests_cold"] = {"total": len(gets), "index_pages": sum(g.startswith("/simple/") for g in gets), "metadata_files": sum(g.endswith(".metadata") for g in gets),
                           "wheels": sum(g.endswith(".whl") for g in gets), "sdists": sum(g.endswith(".tar.gz") for g in gets),
                           "new_https_connections": len(re.findall(r"Starting new HTTPS connection", pipv)),
                           "candidate_links_found": len(re.findall(r"\bFound link ", pipv)), "candidate_links_skipped": len(re.findall(r"\bSkipping link\b", pipv))}
uvg = re.findall(r"Sending fresh GET request for: (\S+)", uvv)
out["uv_requests_cold"] = {"total": len(uvg), "index_pages": sum("/simple/" in g for g in uvg), "metadata_files": sum(g.endswith(".metadata") for g in uvg),
                          "wheels": sum(g.endswith(".whl") for g in uvg), "sdists": sum(g.endswith(".tar.gz") for g in uvg)}
keep = ["read", "pread64", "write", "pwrite64", "openat", "linkat", "rename", "renameat2", "unlink", "unlinkat", "mkdir", "clone", "clone3", "vfork", "execve",
        "connect", "sendto", "recvfrom", "futex", "mmap", "fsync", "fdatasync", "copy_file_range", "sendfile", "statx", "newfstatat"]
for f in sorted(o.glob("strace-*.txt")):
    rows = {}
    for line in open(f):
        m = re.match(r"\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)\s+(?:\d+\s+)?(\w+)\s*$", line.rstrip())
        if m and m.group(2) != "total": rows[m.group(2)] = int(m.group(1))
    out[f.stem] = {k: rows[k] for k in keep if k in rows}; out[f.stem]["total_calls"] = sum(rows.values())
# cProfile: function-level only; proportions are inflated for Python-heavy code (link parsing) vs C-heavy (zlib, fsync). Labelled.
try:
    st = pstats.Stats(str(o / "pip.prof")); by_self = collections.Counter(); cum = {}
    for (file, line, func), (cc, nc, tt, ct, callers) in st.stats.items():
        base = file.replace("\\", "/").rsplit("/", 1)[-1]; key = f"builtin {func}" if file == "~" else f"{base}:{func}"; by_self[key] += tt; cum[key] = max(cum.get(key, 0), ct)
    out["pip_cprofile_warm_nocompile"] = {"note": "cProfile roughly doubles wall time and inflates Python-heavy phases; use the phases-nocompile/dryrun/noindex rows for proportions",
        "profiled_total_s": round(st.total_tt, 2), "calls": st.total_calls,
        "cum_s": {k: round(cum[k], 2) for k in ("install.py:run", "resolver.py:resolve", "prepare.py:prepare_linked_requirements_more", "wheel.py:install_wheel", "collector.py:process_project_url", "package_finder.py:evaluate_link", "link.py:from_json") if k in cum},
        "top_selftime": [{"self_s": round(v, 3), "fn": k} for k, v in by_self.most_common(20)]}
except Exception as e: out["pip_cprofile_warm_nocompile"] = {"error": str(e)}
json.dump(out, open(o / "census.json", "w"), indent=1)
print(json.dumps({"pip_req": out["pip_requests_cold"]["total"], "uv_req": out["uv_requests_cold"]["total"], **{k: v["total_calls"] for k, v in out.items() if k.startswith("strace")}}))
PY
  ;;

*) echo "unknown EXP $EXP"; exit 2 ;;
esac
echo "nuance $EXP done -> $OUT"
