# Methodology: uv vs pip, five cache states

## The question

How much faster is uv than pip at installing a real, fully pinned dependency set, and how does the answer change with
the state of the package cache?

## What is measured

**One metric:** wall-clock seconds for the install command, from process start to exit. Nothing else is timed: not venv
creation, not the tool's own installation, not cache preparation.

**Two tools:** `pip 26.2.1` and `uv 0.12.15`, the latest releases on PyPI on 2026-09-15, installed from PyPI into the
container at those exact versions.

**Five cache states**, each starting from a *fresh, empty virtualenv* unless stated:

| State | Tool cache | Venv | Install flags | What it models |
| :-- | :-- | :-- | :-- | :-- |
| `cold` | empty | empty | — | A first install ever; the number most comparisons quote. |
| `warm` | full (a prior install of this exact file) | empty | — | **CI with a cache step.** |
| `partial` | 108 of 134 pins (every 5th line of the file dropped; the 26 dropped names are in `env.json`) | empty | — | CI after a dependency bump. The prepare install resolves the 26 missing packages unpinned, so the cache holds *newer* versions than the lock: the same effect as a bump, in the opposite direction. |
| `frozen` | full | empty | `--no-deps` | Install with resolution skipped entirely. |
| `noop` | full | **already complete** | — | Re-running install on a finished environment. |
| `warm_nocompile` | full | empty | pip: `--no-compile` | `warm` with pip's bytecode compilation switched off: isolates how much of pip's warm time is `.pyc` generation. uv unchanged. |

**5 runs per configuration**, medians reported, minimum and maximum published. 2 tools × 6 states × 5 runs = **60 timed
installs**, roughly 30–70 minutes.

**Interleaving and order:** run 1 of every configuration completes before run 2 begins. Within a state the two tools run
back to back, and **the order alternates every run** (pip first on odd runs, uv first on even), so neither tool is
systematically second: the second tool to fetch a wheel benefits from CDN edge caches and DNS warmed by the first.
Before any timing, one throwaway cold install of each tool warms those caches for both.

## The workload

`apache/superset` 4.1.0, `requirements/base.txt`, verbatim minus the `-e file:.` line (the project itself) and minus
`python-geohash` (see below). **134 pinned packages**, including pandas, numpy, pyarrow, cryptography, SQLAlchemy,
Celery and Flask, compiled by pip-compile-multi. SHA-256 recorded in `env.json`.

**Why this file:** it is a real production dependency set from a project neither tool's authors wrote; it is fully
pinned, so *resolution is not under test, only install*; and it has enough compiled wheels that download and unpack
dominate, which is the case people actually feel.

## Environment

* `python:3.11-slim-bookworm`, pinned by digest (`env.json`). Python 3.11 because Superset 4.1 pins numpy 1.23.5, which
  has no 3.12 wheels.
* Docker Desktop on Windows 11, WSL2 backend. Container limited to **4 CPUs, 8 GB**.
* Index: `https://pypi.org/simple`, live, over a home internet connection.
* Versions, image digest, kernel, CPU cap, `/tmp` filesystem type, an estimated downlink (one numpy wheel timed before
  the loop), the requirements hash and the partial-state drop list are captured automatically into `env.json`. Every
  install's stdout and stderr is captured in `results/<run>/logs/`; in the main runs both installers run quietly (`-q`),
  so those logs are empty and each row records the exit code and time. The nuance and "why" runs keep verbose logs.
  Nothing is recorded by hand.

## What this workload favours

1. **It favours uv on `cold`, by an amount that depends on the link.** uv downloads in parallel; pip downloads in
   sequence. On a slow or saturated link both tools wait for bytes and the ratio collapses toward 1 (home connection:
   1.5–2.7x); on a fast link pip's fixed CPU work dominates and the ratio converges toward the warm number (datacenter:
   14.7x, where 69% of pip's cold time is its warm work and 41% is bytecode). The cold ratio is a property of the
   network, not of the tools, so it is never presented as a single number.
2. **It favours uv on `noop`.** uv's no-op is designed to be near-instant; pip re-checks every requirement. The ratio is
   large and means little in practice.
3. **It slightly favours pip on `frozen`.** With a fully pinned file there is nothing to resolve, so `--no-deps` does
   not remove resolution; it removes pip's per-package dependency-metadata check after download. uv's install path is
   essentially the same with or without it.
4. **pip compiles bytecode at install; uv compiles at first import, or on request.** Both are defaults: a difference in
   defaults, not a fault. pip's installer writes `.pyc` files for every package (`PYTHONDONTWRITEBYTECODE` does not stop
   it); uv skips this unless `--compile-bytecode` / `UV_COMPILE_BYTECODE=1` is set, and then compiles **in parallel**
   across the CPU quota, where pip compiles serially. Measured: 55% of pip's warm time on x86, 59% on ARM. There are
   therefore several honest ratios, and every result names which one it quotes (defined once, with sources, in
   [`NUANCES.md`](NUANCES.md) §0): **out of the box** (pip default vs uv default, 120x on x86), **install only** (pip
   `--no-compile` vs uv default, 54x), and ratios that include bytecode (the `import` and `cpu` experiments). The
   deferred cost is real: in the common Docker pattern (install as root, then run as a non-root user or on a read-only
   filesystem) uv's deferred `.pyc` is paid on *every* process start and never cached. That is what `--compile-bytecode`
   is for.
5. **130 of the 134 pins are binary wheels; four are source distributions only:** `func-timeout`, `pgsanity`, `shortid`
   and `wtforms-json`, all small pure-Python packages that ship only a `.tar.gz`. *Correction: an earlier version of
   this document said "all binary wheels" and "exactly one sdist"; review found the four sdists from the `uv_build.json`
   markers in uv's venv.* Every **cold** install therefore includes four PEP 517 builds, each in a build-isolation
   environment with its own `setuptools`: pip builds them serially, uv concurrently with a cached build environment.
   Part of the cold ratio is build-isolation overhead rather than download and unpack; the `sdist` experiment measures
   that part. `warm`, `frozen` and `noop` are unaffected: both tools cache the built wheel. The one package that needed
   a *compiler*, `python-geohash`, was removed rather than adding a C++ compiler to the image: compiling C++ identically
   for both tools adds a constant that compresses every ratio and measures something outside this study. The removed
   line stays in `requirements.txt` as a comment.

## What is not controlled

* **Network.** PyPI and its CDN vary minute to minute. `cold` and `partial` are exposed; `warm`, `frozen` and `noop` are
  not. Mitigation: 5 runs, medians, interleaving. The spread is published; a cold spread above 30% of the median is
  reported as a network artefact, not hidden.
* **Host background load.** Docker Desktop shares the machine with Windows. No other work was run during the benchmark;
  three unrelated containers on the host were idle (listed for run 2 in `results/neighbours-run2.txt`).
* **Thermal state.** Not measured. The 4-CPU cap keeps the laptop below its thermal ceiling.
* **OS page cache.** Not dropped between runs (that needs a privileged container). It affects unpack speed for both
  tools equally: every timed install is preceded by an untimed prepare install that reads the same wheels seconds
  earlier.
* **Warm is fresher than a CI cache, and no CI service was used.** The warm cache is populated seconds before the timed
  run. A real CI cache restored from a tarball is usually older than PyPI's 10-minute index `max-age`, so both tools
  revalidate 134 index pages (pip serially, uv concurrently); the `stale` experiment (cache aged 610 s) measures that
  CI-shaped state. The ratio is of **one step**: in a real job the checkout, cache restore and test run are identical
  for both tools, so the CI-relevant number is *seconds saved per run* (about 19 s on x86), not the ratio.
* **Disk.** WSL2 virtual disk on NVMe. Both tools write to the same overlay filesystem.

## What is not measured

* Resolution. The file is fully pinned; resolving a `requirements.in` into a lockfile is a different benchmark.
* Memory and CPU use in the main harness, which records one metric. The nuance experiments measure both
  ([`NUANCES.md`](NUANCES.md) §4, §5, §9).
* Native Windows or macOS installs. Linux container only.
* Any dependency set other than this one.
* `uv sync` / `uv.lock`. This study uses the `uv pip install` interface against the same requirements file pip gets: the
  like-for-like choice. uv's native project workflow is a different comparison.

## Known asymmetries in the harness

* pip's venv is created with `python -m venv` (which bundles pip via `ensurepip`, no download), and the pinned
  `pip==26.2.1` is then installed into it *before* the timer, which downloads pip's wheel into pip's cache. uv's venv is
  `uv venv` (no pip inside). Neither step is timed. In the `cold` state, pip's own wheel and its `/simple/pip/` index
  page are therefore in pip's cache before the timed install, but pip is not in the workload, so nothing is reused.
* uv is installed via pip. This does not affect timing.
* **Hardlink check.** uv links wheels from its cache into the venv; if the two are on different filesystems it silently
  falls back to copying, which would inflate uv's warm and frozen times. Both live on the container's writable layer
  here, and the harness verifies it: after the first warm uv install it counts site-packages files with link count > 1
  versus = 1 into `results/<run>/checks.json`. `uv_hardlinked: true` means most files were linked, not copied.

## Checks before the run

Answered and signed before any timed run, together with [`prediction.md`](prediction.md):

1. **What does this favour?** See above: uv on `cold` and `noop`; pip slightly on `frozen`.
2. **What is uncontrolled?** Network (`cold` and `partial` only), host load, thermals, page cache.
3. **Are cold and warm actually separated?** Yes: `cold` deletes the tool's cache directory before *every* run, then
   creates the venv; venv creation touches only the pip wheel.
4. **Did anything under test author the workload?** No. The set was chosen by the Superset project and pinned by
   pip-tools, which wraps pip's resolver, but resolution is not under test, only install.

## Running it

```bash
RUNS=1 bash bench/run.sh    # smoke test, about 12 minutes: expect 12 rows, exit 0 on all, checks.json present
bash bench/run.sh           # the full run, RUNS=5
```

## The requirements file changed between the laptop runs and the VPS runs

The two laptop runs used `bench/requirements.x86-runs-2026-09-15.txt` (SHA-256 `ca99fb7f…`, recorded in their
`env.json`). For the ARM runs, `bottleneck` gained a `platform_machine != "aarch64"` marker and `pandas[performance]`
became `pandas` (the extra only adds `bottleneck` and `numexpr`, both pinned explicitly). The current
`bench/requirements.txt` (`ccd456eb…`) pins the same 134 package versions on x86 (the only changes are the aarch64
marker and the dropped extra, whose two packages are pinned explicitly) and installs 133 on ARM. Both files are
published.

## Second machine: a VPS on a datacenter link

Added after the two laptop runs showed that the `cold` state does not reproduce over a home connection.

* **Oracle Cloud VM, 4× Ampere Neoverse-N1 (aarch64), Ubuntu 24.04, kernel 6.17-oracle.** Same `inside.sh`, the same
  package set (via `bench/requirements.txt` with the aarch64 marker described above), same pip and uv versions, same
  `python:3.11-slim-bookworm` image (its **arm64/v8 digest**, pinned in `bench/run_vps.sh`), same 4-CPU / 8 GB limits.
* **Datacenter link:** the probe measured about 1.3 Gbps (81–148 Mbps at home), so `cold` and `partial` are
  network-light here, which is closer to what CI sees.
* **Different architecture, different wheels.** Every pin that installs from a wheel had an aarch64 wheel except
  `bottleneck==1.3.8` (the four sdists are pure Python and build anywhere), excluded on aarch64 by an environment marker
  (`; platform_machine != "aarch64"`): 133 packages on ARM, 134 on x86. Line numbering was preserved, so the `partial`
  drop list is identical on both machines.
* **The VPS hosts other services.** The container ran with `--cpu-shares=512`, half the default weight, so it yields CPU
  to anything else as soon as there is contention. Shares change nothing on an idle machine, which it was (load 0.00
  before the run; the only other running container was a reverse proxy). The work directory and the pulled image were
  removed afterwards.
* **ARM and x86 numbers are separate measurements.** Different CPU, different wheels, different disk. pip's per-file CPU
  work is about 27% slower on Neoverse-N1 (warm 24.7 s vs 19.5 s) while uv's hardlink pass is not CPU-bound, so every
  ratio is larger on ARM *because pip is slower there*, not because uv is faster. `analysis/analysis.py` reports each
  machine separately.
* **The datacenter cold number reproduces across two sessions** run about 1.5 hours apart: cross-session medians differ
  by 0.1% (pip) and 6.2% (uv). It is one machine, on ARM, and was added after the laptop runs, not pre-registered.

## Independent review

Before the first run, the harness and this document were reviewed by a separate AI review session given only the files,
with no prior context, instructed to be adversarial. It found one blocker (a `find | head` pipeline that would have
stopped the run under `pipefail` after four rows), the bytecode-compilation asymmetry, a fixed tool order favouring the
second tool, a CPU-cap variable that was not passed to the container, discarded tool output, and several wording errors.
All were fixed before the smoke test that preceded the first run. Details, and the later reviews, are in
[`editorial_log.md`](editorial_log.md).
