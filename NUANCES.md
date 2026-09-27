# Nuance findings — uv vs pip, beyond the headline

Nine nuance experiments plus a "why" experiment, two machines, one harness (`bench/nuances_inside.sh`), four independent reviews of this work (reviews 2–5 in `editorial_log.md`; the last traced every number in this document to its source field and found 26 corrections, all applied here). Raw rows: `results/2026-09-16_2320_nuances_laptop/` (x86 laptop, home link, NVMe) and `results/2026-09-16_2330_nuances_vps-arm64/` (4× Ampere ARM VPS, ~1.3 Gbps datacenter link, 50 MB/s boot volume); `results/2026-09-17_why_*/`. `findings_nuances.json` in each. **n = 5 runs unless stated; §7 and §9 are n = 3.** Where only one machine is quoted, it is named.

**Main-harness reference numbers** (`results/2026-09-15_2016`, `2026-09-16_1810_vps-arm64`): x86 warm pip 19.45 s / uv 0.162 s; ARM warm 24.65 s / 0.139 s. Second sessions on each machine: x86 115x, ARM 167x — the ratios below quote the first session (120x / 177x) and the sessions' medians agree within 7.8% for every state except home-link cold and x86 uv `partial` (10.6%, two network outliers in the second run).

---

## 0. The four ratios — pick one and name it

The single biggest source of confusion in "uv vs pip" numbers is that four different comparisons are all true. Every result in this study names which one it quotes.

| # | Ratio | x86 | ARM | Compares | Source |
| :-- | :-- | --: | --: | :-- | :-- |
| 1 | **Out of the box** | **120x** | **177x** | pip default (compiles `.pyc`) vs uv default (doesn't), install command only | main run |
| 2 | **Install only** | **54x** | **72x** | pip `--no-compile` vs uv default — the installer work alone | main run `warm_nocompile` |
| 3 | **Like-for-like** | **5.4x** | **6.1x** | pip default vs uv `--compile-bytecode` — both produce every `.pyc` | `import` experiment |
| 4 | **Install + first import** | **9.2x** | **9.7x** | what one fresh process importing 11 heavy modules experiences | `import` experiment |

(#3 and #4 come from a separate experiment whose pip install measured 19.53 s and uv 0.176 s — i.e. 111x — versus the main run's 120x. Same quantity, different session; the difference is session drift.)

#2 is pip's `warm_nocompile` median (8.78 s) over uv's `warm` median (0.162 s). `findings.json` lists 52.9x for `warm_nocompile` because it pairs pip with uv's run inside that same state (0.166 s); the two differ by uv's run-to-run variation.

## 1. The bytecode 2×2 — is the 120x real, or deferred?

| | x86 install | x86 first import | x86 install + first import | ARM install | ARM first import | ARM total |
| :-- | --: | --: | --: | --: | --: | --: |
| pip (default: compiles at install) | 19.53 s | 0.68 s | **20.20 s** | 24.70 s | 1.00 s | **25.68 s** |
| uv (default: defers) | 0.18 s | **2.02 s** | **2.19 s** | 0.15 s | **2.49 s** | **2.65 s** |
| uv `--compile-bytecode` | 3.64 s | 0.65 s | **4.29 s** | 4.08 s | 0.79 s | **4.87 s** |
| *`compileall -j1`, everything, serial* | — | 10.16 s | — | — | 13.80 s | — |

First import = `import numpy, pandas, pyarrow, sqlalchemy, celery, flask, cryptography, redis, marshmallow, jsonschema, wtforms` in a fresh process; the second import is the control (≈ 0.65 s on x86, ≈ 0.78 s on ARM, identical across all three configs — so `first − second` isolates the compile). The `compileall` reference exits 1 on every run because two packages ship Python-2 fixture files that cannot compile (`func_timeout/py2_raise.py`, one selenium file); it compiles everything else.

**The deferred cost has bounds.** Importing those 11 modules writes 654 `.pyc` files (x86; 640 ARM) and costs uv 1.35 s / 1.71 s on first import. Compiling *all* 6,407 (x86; 6,380 ARM) files serially — what pip does at install — costs 10.16 s / 13.80 s, **within 6%** of pip's measured bytecode share (10.67 s / 14.59 s). **Same work: pip does it at install; uv does it at first import, or in 3.5–3.9 s on request because it uses all four cores.** The `cpu` experiment confirms the last part: on one core, `uv --compile-bytecode` costs 14.0 s of compile (14.34 − 0.33) versus pip's 14.59 s — within 4%.

**Where the deferred cost bites:** install as root and run as a non-root user, or on a read-only filesystem, and uv's deferred `.pyc` is paid on *every* process start and never cached. That is what `--compile-bytecode` / `UV_COMPILE_BYTECODE=1` is for, and every uv Docker guide says to set it.

## 2. Did they install the same thing?

**Yes: identical package file contents.** All 134 (x86) / 133 (ARM) packages have identical file contents by RECORD hash (`same_thing.json`, `dists_same_content` = `dists_pip` on both machines) — including the four sdists both tools built from source. The only files present in one venv and not the other are uv's four `uv_build.json` markers. Entry-point scripts point at the same targets (the wrapper *template* differs, which is cosmetic). `INSTALLER` says `pip` in one and `uv` in the other.

Method note: pip writes `RECORD` with CRLF line endings (Python's `csv` module) and uv with LF, and pip's RECORD lists the `.pyc` files it compiled. Both had to be normalised before the comparison meant anything.

## 3. Disk: hardlinks are a loan (x86 unless stated)

| x86 | venv | of which `.pyc` | cache | venv + cache (actual) |
| :-- | --: | --: | --: | --: |
| pip | 698 MB | 114 MB | 182 MB (compressed wheels) | **880 MB** |
| uv | 566 MB | 0 | 591 MB (unpacked) | **595 MB** — 11,296 files hardlinked |
| uv, cache on another filesystem | 566 MB | 0 | 584 MB | **1,146 MB** — 0 hardlinked, every file copied |

uv's cache is *unpacked* — **3.2x** bigger than pip's compressed one (591 vs 182 MB) — so a CI cache tarball of uv's cache is correspondingly larger. The 595 MB total only holds while cache and venv share a filesystem.

**When they don't** (a mounted CI cache volume, Docker `--mount=type=cache`): uv silently falls back to copying, and the warm install becomes **0.53 s on the laptop's NVMe — and 9.3 s on the VPS** (n = 5 each), whose boot volume writes at ~50 MB/s (one isolated `dd` test, 512 MB with `fdatasync` in 10.2 s — recorded in the editorial log, not as a results artefact). That is 63x slower than uv's own hardlinked number on the same machine, and still 2.7x faster than pip there. The tmpfs used as the "other filesystem" is the fastest possible source, so these are lower bounds. Why uv's copy pays the disk synchronously while pip's page-cached writes do not was not determined.

## 4. CPU count — where uv's parallelism actually matters (ARM VPS, `--cpuset-cpus`; n = 5)

| | 1 core | 2 cores | 4 cores* |
| :-- | --: | --: | --: |
| pip warm | 24.2 s | 24.4 s | 24.7 s |
| uv warm | 0.33 s | 0.21 s | 0.14 s |
| uv `--compile-bytecode` warm | **14.3 s** | 7.6 s | 4.1 s |
| pip cold | 35.0 s | 35.6 s | 35.7 s |
| uv cold | 6.2 s | 3.7 s | 2.4 s |

\* The 4-core column is not a cpuset run: all values are from the main run (4-CPU quota) except uv `--compile-bytecode` (4.1 s), which is from the `import` experiment.

pip is single-threaded and does not care. uv's hardlink pass barely cares (0.33 → 0.14 s). **uv's bytecode compile scales almost perfectly with cores** — on one core its compile costs what pip's does (§1). On a 1-vCPU runner the like-for-like ratio (pip default vs uv compiling) is 24.2 / 14.3 = **1.7x**.

## 5. Memory — peak RSS of the largest process in the installer's tree

| | x86 warm | x86 cold | ARM warm | ARM cold |
| :-- | --: | --: | --: | --: |
| pip | 139 MB | 153 MB | 137 MB | 150 MB |
| uv | 66 MB | **178 MB** | 61 MB | **216 MB** |

uv is lighter when it only links, heavier when it downloads and unpacks in parallel. Not a problem for anything but a very small runner; recorded because nobody measures it.

## 6. Latency (ARM VPS, `tc netem`, cold installs, n = 5)

| Added one-way delay | TCP connect (median of 5) | pip cold | uv cold | Ratio |
| :-- | --: | --: | --: | --: |
| +0 ms | 1.4 ms | 36.0 s | 2.47 s | 14.6x |
| +50 ms | 51.5 ms | 57.9 s | 4.97 s | 11.6x |
| +150 ms | 151.5 ms | 102.9 s | 12.35 s | 8.3x |

**pip loses 0.45 s per millisecond of added latency; uv loses 0.07 s.** Both tools make the same ~400 requests (§9B); pip issues them one after another on two keep-alive connections, so each request — and the TCP slow-start ramp on every one of the 130 wheel bodies — waits out the round trip in series; uv's fifty concurrent connections overlap them. The ratio *falls* with latency, because pip's baseline is dominated by ~24 s of CPU work and latency adds proportionally less to it — so "uv wins by more on a slow link" is false in ratio and true in seconds.

**What this does *not* explain: the home-connection cold results.** At home (81–148 Mbps) uv's cold install took 8–130 s across runs and pip's 56–223 s; under these slopes, the extra ~28 s on pip in session 1 would imply ~60 ms of latency and add ~4 s to uv, not 21 s. The home numbers are a **bandwidth floor** — ~180 MB of wheels at 81 Mbps is ~18 s for either tool — plus link instability. So: on a fast link the cold ratio is set by latency (measured here); on a slow or unstable link it is set by bandwidth and collapses toward 1 (observed in the main run, not modelled by netem).

## 7. Stale cache — the CI-shaped warm state (ARM VPS, cache aged 610 s, n = 3)

pip **25.8 s**, uv **0.29 s**, ratio **88x**. Ageing the cache past PyPI's 600 s index `max-age` costs pip +1.1 s over its fresh-warm 24.7 s and uv +0.15 s over 0.14 s — consistent with 133 conditional index requests done serially versus concurrently (the request count in this state was not censused; inferred from the `max-age` behaviour). The out-of-the-box CI ratio is 88x rather than 177x; in seconds saved per CI run it is ~25 s either way.

## 8. The four sdists (ARM VPS, n = 5)

Four of the 134 pins ship only a `.tar.gz` and get built at install. Cold, just those four: **pip 7.0 s, uv 1.25 s.** That is ~20% of pip's whole 35.7 s cold install and **half of uv's 2.4 s** — four tiny pure-Python packages, each needing a PEP 517 build-isolation environment with its own `setuptools`. Warm (built wheel cached): pip 0.64 s, uv 0.02 s.

---

## 9. WHY — the mechanisms, each with its evidence (both machines, n = 3)

`EXP=why`; results in `results/2026-09-17_why_{laptop,vps-arm64}/why/`. Reviewed twice independently; the first review reframed claim B and corrected two numbers, the second corrected the candidate-link count and four sentences.

### A. pip runs on one core's worth of CPU, in sequence; uv is parallel — PROVEN

| Warm install | CPU-seconds ÷ wall-seconds | peak threads | Cold install | peak threads | concurrent TLS connections |
| :-- | --: | --: | :-- | --: | --: |
| pip | 0.97 (x86) / 0.98 (ARM) | 2 | pip | 3 | **4** (2 hosts × 2 processes) |
| uv | **3.0 / 2.6** | 15 / 13 | uv | 66 / 65 | **50** (uv's default concurrency cap; 48–50 observed) |

Thread and socket peaks are 50 ms samples — lower bounds, not medians. Corroborated by strace: pip's warm run spawns two short-lived children (unidentified; not builds — all four sdist wheels are cached) and otherwise runs in one process; pip 26.2.1 compiles bytecode serially (`compileall.compile_file` in `wheel.py`). And by the `cpu` experiment: pip's warm time is the same on 1, 2 and 4 cores; uv's compile scales with cores.

### B. Both tools make the same requests. pip makes them one at a time — REFRAMED

| Cold install, requests to PyPI | pip x86 | uv x86 | pip ARM | uv ARM |
| :-- | --: | --: | --: | --: |
| index pages (`/simple/<name>/`) | 135 | 135 | 134 | 134 |
| PEP 658 metadata files (`.whl.metadata`) | 131 | 131 | 130 | 130 |
| wheels | 131 | 131 | 130 | 130 |
| sdists | 4 | 4 | 4 | 4 |
| **total** | **401** | **401** | **398** | **398** |
| TLS connections used | 4 | ≤ 50 | 4 | ≤ 50 |

(One index page, metadata file and wheel in each column are `setuptools`, fetched for the sdists' build environment; ARM installs 133 packages.) The mechanism is not that pip pays more round trips — it is that pip issues them serially over two keep-alive connections and uv issues up to fifty at once. That is what the `netem` slope measures. **Warm, neither tool touches the network at all** (0 connections, 0 `connect` calls), so this explains the cold ratio and contributes nothing to the 120x.

### C. uv links, pip unzips and writes — PROVEN (once bytecode is separated)

| Warm install, syscalls (`strace -f -c`, x86; ARM within 1%) | pip default | pip `--no-compile` | uv |
| :-- | --: | --: | --: |
| total | 349k | 195k | **37k** |
| `linkat` (hardlink) | 0 | 0 | **11,299** |
| `write` | 19,706 | 13,258 | 1,908 |
| `fsync` | 268 | 268 | **0** |
| `stat`-family (`newfstatat` + `statx`) | 114,873 | 39,374 | 4,013 |

pip's default run makes ~150k more syscalls than `--no-compile`: the bytecode pass (6,406 atomic renames of `.pyc` files). Even without it, pip does **5x** the syscalls of uv: it unzips the 11,296 wheel members out of compressed wheels and writes each one, and `fsync`s twice per package (268 = 2 × 134); uv creates 11,299 hardlinks into its unpacked cache and writes ~400 small files (RECORD, INSTALLER, REQUESTED per package, plus 31 scripts). The `disk` experiment is the other half of the proof: uv's cache is unpacked (591 MB vs pip's 182 MB compressed) *because* linking requires the files to already exist.

### D. Where pip's non-bytecode time goes — MEASURED WITHOUT A PROFILER

pip warm `--no-compile`, x86 [ARM], medians of 3, wall clock:

| Measurement | seconds | meaning |
| :-- | --: | :-- |
| whole run | **8.81** [10.36] | |
| up to "Installing collected packages" | 4.56 [5.44] | find candidates, resolve, prepare |
| from there to the end | 4.24 [4.92] | unzip, write, RECORD, scripts |
| `--dry-run` (everything except installing) | 3.97 [4.83] | 13% under the boundary stamp; same shape |
| `--no-index --find-links wheelhouse` (no index pages at all) | 5.25 [5.94] | |
| **⇒ index-page handling** = whole − no-index | **3.57 [4.42]** | **40% [43%]** of pip's non-bytecode time |

"Index-page handling" is reading 134 cached index responses and 131 cached metadata files through pip's HTTP cache, parsing them, and evaluating every link — the subtraction also adds a wheelhouse directory scan, so it is a close estimate, not an exact isolation. What pip evaluates in that time: for 134 packages whose exact versions are given, **64,825 candidate links** (`evaluate_link` call count in the profile; the cold `-vv` log, with the four build-dependency subprocesses (one per sdist) excluded, agrees: 17,302 found, 47,523 skipped — almost all as wheels for other platforms or Python versions; `.egg` and `.exe` are the largest unsupported-format categories). The cold log shows 70,949 because it includes 6,124 links evaluated by the four build-dependency subprocesses (one per sdist). The cProfile (kept in `census.json`, labelled as inflated) agrees on the shape and names the code: `Link.from_json`, `evaluate_link`, `urlsplit` — ~65,000 `Link` objects per install. uv reads the same 134 pages and resolves in **28 ms** (its own timer).

So pip's 19.45 s warm install on x86 decomposes as: **bytecode 10.7 s (55%) · index-page handling 3.6 s (18%) · unzip/write/fsync 4.2 s (22%) · the rest ~1 s (5%)** — the last three measured under `--no-compile` and assumed unchanged by the compile pass. uv's 0.17 s: resolve 28 ms + install 132 ms (its own timers, one `-v` run) + ~10 ms of process start.

### E. Native binary vs interpreter — REAL, BUT NOT A WARM-RATIO MECHANISM

`python -c pass` 9 ms · `pip --version` 135 ms · `uv --version` 5 ms (x86; ARM 13 / 199 / 6). pip's no-op install (0.68 s in the main run) is 0.14 s of start-up plus ~0.54 s of re-checking 134 installed distributions; uv's no-op is 0.02 s. Start-up is **0.7%** of pip's warm install. "Rust is fast" is true and is not why uv wins the warm install; parallelism and hardlinks are.

### F. uv's own accounting — PROVEN

x86: `Resolved 134 packages in 28ms · Installed 134 packages in 132ms` = 160 ms of the 174 ms wall median (one `-v` run for the timers; three runs for the wall) — the remainder is process start and environment discovery. ARM: 35 ms + 101 ms of 164 ms.

---

## Summary

1. Four ratios are all true: 120x, 54x, 5.4x and 9.2x on x86. Every result names which one it quotes.
2. uv did not skip anything: the installs have identical package file contents.
3. Hardlinks are why uv's venv costs almost nothing; a cache on another filesystem costs the disk's write speed: 0.5 s on NVMe, 9 s on a 50 MB/s cloud volume.
4. uv's bytecode advantage is parallelism. On one core it matches pip.
5. Both tools make about 400 requests; pip makes them one after another and loses 0.45 s per millisecond of latency. On a slow home link neither tool's cold number describes the tools: it is bandwidth.
6. A CI-aged cache: 88x, about 25 seconds per run (ARM VPS).
7. Four small sdists are 20% of pip's cold time and half of uv's (ARM VPS).
8. **Why**, each with its evidence: pip is one core's worth of CPU on two connections; uv uses fifty connections and every core. pip unzips and writes 11,296 files and fsyncs 268 times; uv makes 11,299 hardlinks. And 18% of pip's warm time is spent handling about 65,000 candidate links to pick 134 pinned versions, measured by taking the index away.
