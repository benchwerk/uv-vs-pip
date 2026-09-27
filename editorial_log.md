# Record of runs, reviews and corrections

A dated record of every run, defect, independent review and correction in this study, kept as the work happened. Results
from runs later superseded are not published; each entry below says which runs were superseded and why. Clock times are
local (UTC+2) and approximate; each run's exact start is `started_utc` in its `env.json`.

## 2026-09-15

**Harness drafted; first smoke test failed.** Both tools failed on `python-geohash` (source only, needs a C++ compiler).
The package was removed rather than adding a compiler, leaving 134 pins.

**Questions and prediction signed** ([`methodology.md`](methodology.md), [`prediction.md`](prediction.md)), before any
timed run.

**Independent review 1: adversarial review of the harness** (a separate AI review session given only the files, with no
prior context). 19 findings. Acted on:
- BLOCKER: `find | head` under `pipefail` would have stopped the run after four rows (SIGPIPE, exit 141). Replaced with
  `-links` counting, with no pipe to `head`.
- MAJOR: pip compiles `.pyc` on install and uv does not; `PYTHONDONTWRITEBYTECODE=1` does not affect pip's installer.
  The misleading variable was removed, the difference disclosed in the methodology, and a `warm_nocompile` state added
  to measure it.
- MAJOR: `CPUS` and `MEM` were not passed into the container, so `env.json` would have recorded `null`. Fixed.
- MAJOR: pip always ran first, so uv always found CDN and DNS caches warmed. The order now alternates per run, and one
  throwaway cold install of each tool precedes timing.
- MAJOR: a transient PyPI failure in an untimed prepare step would abort the whole run. Prepare installs retry three
  times.
- MAJOR: tool output was discarded. Every install now logs to `results/<run>/logs/`, and each row carries a `t0` epoch.
- MAJOR: the prediction answered the tested claim "yes" in seconds and "no" in ratio. The metric was fixed to the ratio
  (the unit of the claim), and the prediction states the claim is expected to be false.
- MAJOR: the warm state is fresher than a real CI cache restore. Disclosed.
- MINOR: wording (pip's cached wheel gives no advantage because pip is not in the workload; pip-tools wraps pip's
  resolver; the partial state drops 26 named pins, recorded in `env.json`); `$EPOCHREALTIME` instead of forking `date`;
  `uv venv --python` pinned; `/tmp` filesystem, downlink estimate and bytecode defaults recorded; the `uv pip` interface
  stated; `MSYS_NO_PATHCONV` set in `run.sh`.
- Deferred: a `stale` warm state (cache older than PyPI's index `max-age`). Added later as a nuance experiment.

**Smoke test 2 passed:** 12 rows, hardlinks confirmed. `curl` is missing from the slim image, so the downlink probe was
rewritten with `urllib`.

**20:16, run 1.** 60/60 installs, no failures, no prepare retries. Downlink probe 81 Mbps. Three unrelated containers on
the Docker host were idle; their list was recorded for run 2 in `results/neighbours-run2.txt`.

**20:51, run 2 (reproducibility run).** 60/60, no failures. The probe measured 148 Mbps, yet cold installs were 2–4x
slower than in run 1: a single-wheel probe does not represent sustained multi-connection throughput, so it is recorded
as a weak instrument.

**Analysis of runs 1 and 2.**
- `warm`, `frozen`, `noop` and `warm_nocompile` reproduce across the two runs within 1–8% on medians.
- `partial` reproduces for pip (±1.5%); uv's partial state had two network outliers in run 2 (2.9 s and 5.4 s against
  about 0.7 s). The median holds; the spread is published.
- **`cold` does not reproduce** (pip medians 64 s vs 174 s; uv 23 s vs 113 s). As the methodology commits, cold is
  reported as a network artefact with both ranges, and is not a headline.
- pip's bytecode compilation is 10.7 s of its 19.5 s warm install (55%). With `--no-compile`, pip is still 53x slower
  than uv (54x against uv's `warm` median; see [`NUANCES.md`](NUANCES.md) §0).
- Prediction outcome recorded in [`prediction.md`](prediction.md): warm direction right, magnitude six times too low;
  the cold prediction wrong and not measurable on this link.
- Headline: the warm (CI cache hit) ratio, 120x, reproducible across two runs, with the bytecode share as the second
  number. Cold is reported as a range with the network caveat.

## 2026-09-16

**Run 3 on a second machine:** Oracle Cloud VPS, 4× Ampere Neoverse-N1 (aarch64), Ubuntu 24.04, about 1.3 Gbps. Same
`inside.sh`, the same package set (see the aarch64 marker below), same pip and uv versions, the arm64 digest of the same
image, the same 4 CPU / 8 GB limits, and `--cpu-shares=512` so the machine's other services keep priority. Run as a
transient systemd unit.
- The smoke test found one aarch64 gap: `bottleneck==1.3.8` has no ARM wheel (pulled in by `pandas[performance]`). It is
  excluded on aarch64 by an environment marker, and the extra was replaced by plain `pandas`, since both of its
  dependencies are pinned explicitly. The x86 install set is unchanged and the `partial` drop list byte-identical: 133
  packages on ARM, 134 on x86.
- Three false starts before the real run: two because the launcher ended with the SSH session (fixed by running under
  `systemd-run`), one because a cleanup step stopped the freshly started container. The cleanup trap had also deleted
  results on failure; it was rewritten to always preserve them. Nothing outside the throwaway work directory was
  touched.
- 60/60, no failures, no retries. Hardlinks confirmed (11,257). Work directory, image and staging directory removed
  afterwards; only the reverse-proxy container was running before and after. Results in
  `results/2026-09-16_1810_vps-arm64/`.

**VPS analysis.**
- **Cold reproduces on a datacenter link:** pip 35.65–35.87 s (0.6% spread), uv 2.41–2.52 s (4.6%). **14.7x.** A
  different machine, so reported separately, not merged with the laptop results.
- Warm 177x (pip 24.7 s, uv 0.139 s), frozen 183x, partial 81x, noop 38x. The same shape as x86, with every ratio larger
  on ARM.
- Bytecode share of pip's warm time: 59% on ARM (14.6 of 24.7 s), against 55% on x86.
- The home cold result (2.7x and 1.5x, not reproducible) against the datacenter result (14.7x; 13.8x in the second
  session, below) is itself a finding: the cold number depends on the connection, and only a CI-class connection makes
  it measurable.

**Nuance harness written (seven experiments), then two independent reviews in parallel,** each a separate AI review
session with no prior context.

*Independent review 2: research reasoning.* 20 findings. The BLOCKER: the study's original framing, that warm-cache
numbers go unreported, was wrong. uv's own README headline is the warm-cache number. The framing was asserted rather
than checked, and was retracted. Also:
- The cold ratio across link speeds is a mechanism, not an artefact, and is the right place for the datacenter number.
- "Reproduces" was overstated from one VPS session (resolved by session 2, below).
- "120x in CI" describes one step (about 19 s), not a CI outcome, and no CI service was run.
- The bytecode 2×2 was half-measured (`uv --compile-bytecode` was missing from the primary table).
- The laptop runs had used a requirements file that was edited afterwards. The original was reconstructed byte for byte
  (SHA-256 verified) and published as `requirements.x86-runs-2026-09-15.txt`.
- Every install log was 0 bytes because of `-q`, so the "network blip" explanation for run 2 had no evidence.

*Independent review 3: code review of the nuance harness.* 19 findings. The BLOCKER: `$RC` was set inside a command
substitution and read in the parent under `set -u`, so `cpu` and `netem` would have aborted on their first row after two
minutes of preparation; neither had ever produced a row. MAJOR: **four of the 134 pins are sdists** (`func-timeout`,
`pgsanity`, `shortid`, `wtforms-json`), where the methodology said "all binary wheels" and "exactly one sdist". Caught
from uv's `uv_build.json` markers; corrected, and an `sdist` experiment added to measure the build-isolation share of
cold. Also:
- `mem` was labelled as container memory but measured the largest process's RSS (relabelled).
- `same` reported wrapper-template noise as 29 differing scripts (rewritten: venv baseline subtracted, RECORD content
  hashes, entry-point targets).
- `netem`'s default 1000-packet queue would drop ACKs at 150 ms on a 1.3 Gbps link (limit raised; `tc -s` logged).
- The RTT probe included DNS (fixed); `import` and `disk` rows had no exit codes (added); pip's cache contained uv's
  wheel (cleared); `.pyc` and byte counts included pip's own bootstrap (excluded).
- tmpfs gives a lower bound for the cross-filesystem penalty (labelled); cpuset 0 shares vCPU 0 with virtio interrupts
  on WSL2 (the last cores are used instead); cold legs on the laptop are noise (VPS only).

Both reviews were addressed in one rewrite of `nuances_inside.sh`, which also added `stale` (a 610 s old cache,
CI-shaped), `sdist`, a `compileall -j1` serial reference, and `uv --compile-bytecode` in `cpu`. All earlier nuance
results were discarded; everything was re-run from this harness version.

**21:40, VPS session 2 of the main harness** (same file, same image, about 1.5 hours after session 1). 60/60, no
failures. Cross-session medians: cold pip **0.1%** apart, cold uv 6.2%, warm pip 0.5%, warm uv 5.8%, every other state
≤4.2%. The cold ratio is 14.7x in session 1 and 13.8x in session 2. The datacenter cold number now reproduces across two
sessions, with the standing caveat that it is one machine, on ARM, and was not pre-registered.

**Evening, three harness defects found by the first real nuance run,** after the reviews:
1. `timed()` printed seconds and exit code on two lines; `read -r s rc` took the first, and `printf %d` turned the empty
   second into 0. Every exit code in that run was recorded as 0, and `same`'s rows were malformed JSON. Fixed to one
   line and unit-tested in the image (`true` → 0, `false` → 1). The 55 affected laptop rows' installs were verified
   successful from their logs; the run was superseded regardless.
2. **uv warm measured 0.66 s instead of 0.16 s** in every nuance experiment. Isolated: writing the (no longer quiet)
   install log to `/results`, a Windows bind mount under Docker Desktop, cost **0.47 s for 137 lines** through virtiofs
   (measured in a superseded run, not published). The main harness escaped this only because `-q` left the logs empty.
   Fixed: logs are written to the container filesystem while the clock runs and moved afterwards. On the VPS (`/results`
   on ext4) the cost is negligible, but the harness now behaves the same everywhere. Rule adopted for every harness:
   nothing on the timed path may touch a bind mount.
3. `tr -d '\r'` in the RECORD hash had been turned into a literal newline by a file round-trip that converts a lone
   carriage return. Caught because `same` reported 0/134 identical after having reported 134/134. Fixed, and the harness
   file verified free of carriage-return bytes.

All nuance results from before these fixes were superseded and are not published. The laptop and VPS nuance runs were
restarted from the same harness version.

## 2026-09-17

**Nuance runs complete on both machines from the final harness.** Laptop: 5 experiments, 57 rows. VPS: 9 experiments,
163 rows. No unexpected failures (the `compileall` reference exits 1 by design, on two Python 2 fixture files). The VPS
staging, results, work directory and image were removed afterwards; only the reverse proxy ran before and after. The
write-up is [`NUANCES.md`](NUANCES.md); raw rows are in `results/*_nuances_*`.

One result needed a mechanism before it could be reported: uv's cross-filesystem (copy mode) warm install took 0.53 s on
the laptop and 9.3 s on the VPS. One isolated container test showed the VPS boot volume writes at about 50 MB/s (512 MB
with `fdatasync` in 10.2 s; a one-off test, not a published artefact); at that speed the 538 MB venv needs about 10.7 s,
the same order as the measured 9.3 s. It is reported as "the disk's write speed × the venv size", not as a uv constant.
Why uv's copy path pays the disk synchronously while pip's writes are page-cached was not determined.

**The mechanisms, measured (`EXP=why`).** Start-up cost; CPU and wall time, peak threads and peak port-443 sockets per
install; an strace syscall census; an HTTP request census from both tools' verbose logs; a cProfile of pip's
non-bytecode time; uv's own phase timers. Smoke test, then real runs on both machines, then a review of each causal
claim against its evidence.

*Independent review 4: each causal claim against its evidence.* 17 findings, two BLOCKERs, both against the original
framing:
- **uv makes the same 401 HTTP requests as pip** on a cold install: 135 index pages, 131 PEP 658 metadata files, 131
  wheels and 4 sdists, counted from uv's `Sending fresh GET request` lines. The census had compared pip's request count
  with uv's count of *distinct URLs*. The mechanism is sequencing (pip one request at a time on two connections, uv up
  to 50 at once), not count; and warm, neither tool touches the network, so it explains cold and none of the 120x.
- The strace "total" line had been summed in with the syscalls: pip's warm run makes 349k calls, not 698k (uv 37k, not
  75k; the ratio is unchanged).

MAJOR: the pip strace census included bytecode compilation (a `--no-compile` trace was added); cProfile inflates
Python-heavy phases, so "54% resolve" is about 45% (profiler-free phase timing added: a `-v` boundary stamp,
`--dry-run`, `--no-index --find-links`); the probe's wall clock was quantised by its own sampling loop, and its resource
usage included the `ss` processes it spawned (fixed: `wait4` on the child, exit stamped by a waiter thread). The
reviewer's profiler-free count was adopted at the time: pip evaluates 70,949 candidate links to install 134 pinned
packages (corrected by review 5, below).

Verdicts: A (parallel vs sequential) proven; B reframed as above; C (links vs writes) partly proven until compilation
was separated, now proven; D (where pip's time goes) partly, with an interim split of about 45/45/10
resolve/install/prepare, since replaced by the profiler-free timings in `NUANCES.md` §9D; E (start-up) not a warm-gap
mechanism, only relevant to the no-op ratio; F (uv's timers) proven. Earlier `why` results were superseded and the
experiment re-run on both machines.

*Independent review 5: every number in `NUANCES.md` traced to its source field.* 26 findings, all applied in a rewrite
of the document. The ones that would have been stated wrongly:
- **70,949 candidate links → 64,825.** The cold `-vv` log includes 6,124 links evaluated inside the four
  build-dependency subprocesses (one per sdist); the warm run being explained evaluates 64,825 (`evaluate_link` call
  count in the profile). The earlier number had been adopted without splitting it by process.
- **"The home cold ratio is your latency" → false.** Under the measured netem slopes the home results cannot be a
  latency effect (they would need about 60 ms and would move uv by 4 s, not 21 s). The home results are a bandwidth
  floor (about 180 MB at 81 Mbps ≈ 18 s for either tool) plus instability. netem explains the fast-link cold ratio; it
  does not model the slow-link collapse. Corrected in `NUANCES.md` §6.
- "1.6x" on one core used a number that does not exist (14.7); it is 24.2 / 14.3 = 1.7x. "About 450 round trips" → about
  400 (401 x86, 398 ARM). uv's stat-family count omitted `statx` (1,844 → 4,013). "About 140 small files" written by uv
  → about 400 (`checks.json`). "1 clone and 2 vforks = build isolation" → the warm run builds nothing; two unidentified
  short-lived child processes. "Start-up is the entire no-op ratio" → 0.14 s of 0.68 s. Two documents had used "install
  only" for two different ratios; `NUANCES.md` §0 now defines four ratios once, with sources.
- Per-machine disclosure: ARM makes 398 requests (133 packages); ARM-only experiments now say so; x86-only figures (654
  `.pyc` files, 6,407 files) now carry their ARM equivalents.

Fixes from review 4 verified: child resource usage via `wait4`, exit stamped by a waiter thread, strace totals, the
request census compared like for like, phases timed without the profiler.

[`NUANCES.md`](NUANCES.md) is the reviewed statement of what the data supports.
