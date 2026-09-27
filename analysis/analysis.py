"""
Main runs: results/<run>/raw.jsonl -> findings.json.

    python analysis/analysis.py .                            # analyse every results/<run>/ dir, compare them
    python analysis/analysis.py . --primary 2026-09-15_2016

Per (tool, state): median, min, max, spread (max-min as % of median), n.
Per state: ratio of medians pip/uv.  Cross-run: does each run's median fall inside
the other run's min..max?  Prediction: compared against prediction.md's table.
The headline ratio is written as a named field, so documents can cite it by name.
"""
import argparse
import json
import re
import statistics as st
from pathlib import Path

STATES = ["cold", "warm", "partial", "frozen", "noop", "warm_nocompile"]


def load(results_dir: Path):
    rows = [json.loads(l) for l in (results_dir / "raw.jsonl").read_text().splitlines() if l.strip()]
    env = json.loads((results_dir / "env.json").read_text())
    checks = json.loads((results_dir / "checks.json").read_text()) if (results_dir / "checks.json").exists() else {}
    return rows, env, checks


def summarise(rows):
    out = {}
    for tool in ("pip", "uv"):
        for state in STATES:
            xs = sorted(r["seconds"] for r in rows if r["tool"] == tool and r["state"] == state and r["exit"] == 0)
            fails = sum(1 for r in rows if r["tool"] == tool and r["state"] == state and r["exit"] != 0)
            if not xs:
                continue
            med = st.median(xs)
            out[f"{tool}.{state}"] = {"median_s": round(med, 3), "min_s": xs[0], "max_s": xs[-1], "n": len(xs), "failed": fails,
                                      "spread_pct": round((xs[-1] - xs[0]) / med * 100, 1), "runs_s": xs}
    ratios = {}
    for state in STATES:
        p, u = out.get(f"pip.{state}"), out.get(f"uv.{state}")
        if p and u:
            ratios[state] = {"pip_over_uv": round(p["median_s"] / u["median_s"], 1), "seconds_saved": round(p["median_s"] - u["median_s"], 2)}
    return out, ratios


def read_prediction(path: Path):
    pred = {}
    if not path.exists():
        return pred
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\|\s*(\w+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)x", line)
        if m:
            pred[m.group(1)] = {"pip_s": float(m.group(2)), "uv_s": float(m.group(3)), "ratio": float(m.group(4))}
    return pred


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video_dir")
    ap.add_argument("--primary", help="results/<name> to treat as the published run (default: latest)")
    a = ap.parse_args()
    vd = Path(a.video_dir)
    dirs = sorted(d for d in (vd / "results").iterdir() if d.is_dir() and (d / "raw.jsonl").exists())
    if not dirs:
        raise SystemExit("no results")
    primary = (vd / "results" / a.primary) if a.primary else dirs[-1]

    runs = {}
    for d in dirs:
        rows, env, checks = load(d)
        s, r = summarise(rows)
        runs[d.name] = {"summary": s, "ratios": r, "env": env, "checks": checks, "rows": len(rows), "failed_rows": sum(1 for x in rows if x["exit"] != 0)}

    P = runs[primary.name]
    machine = lambda r: (r["env"].get("kernel"), r["env"].get("python_path"))
    same_machine = [n for n in runs if n != primary.name and machine(runs[n]) == machine(P)]
    # Cross-run reproducibility: each run's median inside every other SAME-MACHINE run's min..max?
    repro = {}
    for key, v in P["summary"].items():
        others = [runs[n]["summary"].get(key) for n in same_machine]
        others = [o for o in others if o]
        inside = all(o["min_s"] <= v["median_s"] <= o["max_s"] for o in others) if others else None
        med_diff = max(abs(o["median_s"] - v["median_s"]) / v["median_s"] * 100 for o in others) if others else None
        repro[key] = {"primary_median_inside_other_runs_range": inside, "max_median_diff_pct": round(med_diff, 1) if med_diff is not None else None}

    pred = read_prediction(vd / "prediction.md")
    pred_check = {}
    for state, pv in pred.items():
        rr = P["ratios"].get(state)
        if rr:
            pred_check[state] = {"predicted_ratio": pv["ratio"], "measured_ratio": rr["pip_over_uv"],
                                 "predicted_pip_s": pv["pip_s"], "measured_pip_s": P["summary"][f"pip.{state}"]["median_s"],
                                 "predicted_uv_s": pv["uv_s"], "measured_uv_s": P["summary"][f"uv.{state}"]["median_s"]}

    cold, warm = P["ratios"].get("cold", {}).get("pip_over_uv"), P["ratios"].get("warm", {}).get("pip_over_uv")
    bytecode = None
    if "pip.warm" in P["summary"] and "pip.warm_nocompile" in P["summary"]:
        w, nc = P["summary"]["pip.warm"]["median_s"], P["summary"]["pip.warm_nocompile"]["median_s"]
        bytecode = {"pip_warm_s": w, "pip_warm_nocompile_s": nc, "bytecode_seconds": round(w - nc, 2), "bytecode_share_pct": round((w - nc) / w * 100, 1)}

    findings = {
        "video": vd.name,
        "primary_run": primary.name,
        "runs_analysed": list(runs),
        "same_machine_runs": same_machine,
        "other_machines": {n: {"kernel": runs[n]["env"].get("kernel"), "host_cpus": runs[n]["env"].get("host_cpus"), "downlink_mbps": runs[n]["env"].get("downlink_mbps_estimate"),
                               "ratios": runs[n]["ratios"], "medians": {k: v["median_s"] for k, v in runs[n]["summary"].items()},
                               "spread_pct": {k: v["spread_pct"] for k, v in runs[n]["summary"].items()}}
                           for n in runs if n != primary.name and n not in same_machine},
        # --- the named headline fields (documents cite these by name) ---
        "headline": {
            "cold_ratio": cold, "warm_ratio": warm,
            "title_claim_warm_ratio_is_far_smaller_than_cold": (warm is not None and cold is not None and warm < cold / 2),
            "pip_cold_s": P["summary"].get("pip.cold", {}).get("median_s"), "uv_cold_s": P["summary"].get("uv.cold", {}).get("median_s"),
            "pip_warm_s": P["summary"].get("pip.warm", {}).get("median_s"), "uv_warm_s": P["summary"].get("uv.warm", {}).get("median_s"),
        },
        "bytecode_cost": bytecode,
        "ratios": P["ratios"],
        "summary": P["summary"],
        "reproducibility_vs_other_runs": repro,
        "prediction_check": pred_check,
        "env": P["env"], "checks": P["checks"],
        "all_runs": {n: {"ratios": r["ratios"], "medians": {k: v["median_s"] for k, v in r["summary"].items()}, "started": r["env"].get("started_utc"),
                         "downlink_mbps": r["env"].get("downlink_mbps_estimate"), "failed_rows": r["failed_rows"]} for n, r in runs.items()},
    }
    out = primary / "findings.json"
    out.write_text(json.dumps(findings, indent=1), encoding="utf-8")

    # Human summary
    print(f"primary run {primary.name}   ({len(runs)} runs analysed)\n")
    print(f"{'state':16s} {'pip med':>8s} {'uv med':>8s} {'ratio':>6s}  {'pip spread':>10s} {'uv spread':>9s}  repro")
    for state in STATES:
        p, u, r = P["summary"].get(f"pip.{state}"), P["summary"].get(f"uv.{state}"), P["ratios"].get(state)
        if p and u:
            rp = repro[f"pip.{state}"]["max_median_diff_pct"]; ru = repro[f"uv.{state}"]["max_median_diff_pct"]
            print(f"{state:16s} {p['median_s']:8.2f} {u['median_s']:8.3f} {r['pip_over_uv']:5.1f}x  {p['spread_pct']:9.1f}% {u['spread_pct']:8.1f}%  "
                  f"{'' if rp is None else f'pip ±{rp}%  uv ±{ru}%'}")
    if bytecode:
        print(f"\npip bytecode compilation: {bytecode['bytecode_seconds']} s of {bytecode['pip_warm_s']} s warm = {bytecode['bytecode_share_pct']}%")
    if pred_check:
        print("\nprediction vs measured (ratio):")
        for s_, v in pred_check.items():
            print(f"  {s_:10s} predicted {v['predicted_ratio']:5.1f}x   measured {v['measured_ratio']:5.1f}x")
    for n, m in findings["other_machines"].items():
        print(f"\nother machine — {n}  (kernel {m['kernel']}, ~{m['downlink_mbps']} Mbps):")
        print(f"{'state':16s} {'pip med':>8s} {'uv med':>8s} {'ratio':>6s}  {'pip spread':>10s} {'uv spread':>9s}")
        for state in STATES:
            if f"pip.{state}" in m["medians"]:
                print(f"{state:16s} {m['medians'][f'pip.{state}']:8.2f} {m['medians'][f'uv.{state}']:8.3f} {m['ratios'][state]['pip_over_uv']:5.1f}x  {m['spread_pct'][f'pip.{state}']:9.1f}% {m['spread_pct'][f'uv.{state}']:8.1f}%")
    h = findings["headline"]
    print(f"\nTitle claim 'warm ratio far smaller than cold': {'TRUE' if h['title_claim_warm_ratio_is_far_smaller_than_cold'] else 'FALSE'}  (cold {h['cold_ratio']}x, warm {h['warm_ratio']}x)")
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
