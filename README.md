# uv vs pip, five cache states

How much faster is uv than pip at installing a real, fully pinned dependency set, and how does the answer change with
the state of the package cache? This repository holds everything needed to check the answer: the harness, every raw
result, the analysis scripts, the methodology, the prediction written before anything was run, and the record of five
independent reviews.

**Video:** on the benchwerk YouTube channel, [@benchwerkdev](https://www.youtube.com/@benchwerkdev).

## Findings

Four different "uv vs pip" ratios are all true. Which one you get depends on what you compare (defined with sources in
[`NUANCES.md`](NUANCES.md) §0):

| Ratio | x86 laptop | ARM VPS | Compares |
| :-- | --: | --: | :-- |
| **Out of the box** | 120x | 177x | pip default (compiles `.pyc`) vs uv default (doesn't), install command only |
| **Install only** | 54x | 72x | pip `--no-compile` vs uv default: the installer work alone |
| **Like-for-like** | 5.4x | 6.1x | pip default vs uv `--compile-bytecode`: both produce every `.pyc` |
| **Install + first import** | 9.2x | 9.7x | what one fresh process importing 11 heavy modules experiences |

- **Warm cache** (the CI-with-a-cache case), median of 5 runs: x86 pip 19.45 s, uv 0.162 s; ARM pip 24.65 s, uv 0.139 s.
- **Cold cache** on a home connection did not reproduce between two runs 35 minutes apart (1.5–2.7x; pip 56–223 s, uv
  8–130 s), so it is reported as a range and is not a headline. On the datacenter VPS it did reproduce: 14.7x and 13.8x
  in two sessions. See [`prediction.md`](prediction.md).
- **Both tools installed the same packages:** all 134 (x86) / 133 (ARM) packages have identical file contents by their
  RECORD hashes; only installer metadata, entry-point wrappers and compiled `.pyc` files differ
  ([`NUANCES.md`](NUANCES.md) §2).
- **The prediction was wrong** in most states. It was written before the runs and is published with the outcome added
  below it: [`prediction.md`](prediction.md).

## What is here

| Path | Contents |
| :-- | :-- |
| [`methodology.md`](methodology.md) | the question, what is measured, the workload, environment, what the workload favours, what is not controlled or measured |
| [`prediction.md`](prediction.md) | written before execution; outcomes added afterwards |
| [`NUANCES.md`](NUANCES.md) | nine further experiments and the mechanisms behind the results, every number traced to its source field |
| [`editorial_log.md`](editorial_log.md) | dated record of every run, defect, review and correction |
| [`bench/`](bench/) | the harness: `run.sh` (main runs, x86-64 host), `run_vps.sh` (main runs, ARM VPS), `run_nuances.sh` with `nuances_inside.sh` (nuance and mechanism experiments), and the requirements files |
| [`analysis/`](analysis/) | `analysis.py` (main runs → `findings.json`) and `analysis_nuances.py` (nuance and mechanism runs → `findings_nuances.json`); Python standard library only |
| [`results/`](results/) | one folder per run: raw rows (`raw.jsonl`), per-install logs, `env.json` (versions, image digest, requirements hash, start time), `checks.json`, and `findings*.json` in each analysed run |

**Workload:** Apache Superset 4.1.0 `requirements/base.txt`, 134 pinned packages. **Tools:** pip 26.2.1, uv 0.12.15.
**Environment:** `python:3.11-slim-bookworm` pinned by digest, container limited to 4 CPUs and 8 GB, on an x86 laptop
(home connection) and a 4-core Ampere ARM VPS (datacenter connection). **5 runs per configuration, medians reported,
minimum and maximum published.** The main runs install quietly, so their per-install logs are empty and each row records
the exit code and time; the nuance and mechanism runs keep verbose logs.

**Regenerating the findings files.** Running the analysis scripts on this repository reproduces every published value.
Three differences are expected: `results/2026-09-15_2016/findings.json` was generated before the second VPS session
existed, so a fresh run also lists that session in its cross-run sections; the mechanism runs' published files name one
field `wall_s_(sampler-quantised; use timed rows elsewhere)`, which the current script writes as `wall_s`; and the
`"video"` field records the name of the folder the script was run on. The scripts write into `results/`, so run them on
a copy (for example `git checkout-index -a --prefix=/tmp/check/`) or restore the published files afterwards with `git
checkout results/`.

## Reproduce

Needs Docker and bash. From the repository root on an x86-64 host:

```bash
RUNS=1 bash bench/run.sh    # smoke test, about 12 minutes: expect 12 rows, exit 0 on all, checks.json present
bash bench/run.sh           # the main run: 5 runs per configuration
bash bench/run_nuances.sh                   # the nuance experiments (import same disk disk_xdev cpu mem netem stale sdist)
EXPS=why bash bench/run_nuances.sh          # the mechanism experiment
python analysis/analysis.py . --primary <run folder>   # writes findings.json into results/: run on a copy (see above)
python analysis/analysis_nuances.py .
```

On an ARM host, use `bench/run_vps.sh` for the main run (its header shows how it was run on the VPS); `run_nuances.sh`
selects the arm64 image automatically. The main runs use `bench/requirements.txt`; the two published x86 laptop runs
used `bench/requirements.x86-runs-2026-09-15.txt`, which pins the same package versions (the difference is explained in
[`methodology.md`](methodology.md)). Your cold-cache numbers will differ from these: they measure your network.

## Reviews

Five independent reviews, each a separate AI review session given only the files, with no prior context, are recorded
with their findings and the fix for each in [`editorial_log.md`](editorial_log.md): an adversarial review of the main
harness before its runs, then four reviews of the nuance work (research reasoning, code, each causal claim against its
evidence, and a trace of every number in `NUANCES.md` to its source field). The full review transcripts were not kept.
Runs superseded after a review found a defect are not included here; the record says which and why.

## Licence

Code (`bench/`, `analysis/`): [MIT](LICENSE). Data and documents: [CC BY 4.0](LICENSE-DATA). The requirements files in
`bench/` are derived from Apache Superset's `requirements/base.txt` (Apache License 2.0). Please link back to this
repository if you use the numbers.
