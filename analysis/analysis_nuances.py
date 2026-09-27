"""
Nuance experiments -> findings_nuances.json (per results/<date>_nuances_*/ directory).

    python analysis/analysis_nuances.py .                            # every *_nuances_* and *_why_* dir
    python analysis/analysis_nuances.py . --dir 2026-09-17_why_laptop

Every experiment has its own schema; each block below reduces raw rows to medians/min/max and
the derived numbers the documents quote. Rows with a non-zero exit are dropped and counted.
"""
import argparse
import json
import statistics as st
from pathlib import Path


def rows(d):
    f = d / "raw.jsonl"
    return [json.loads(l) for l in f.read_text().splitlines() if l.strip()] if f.exists() else []


def ok(r):
    # compileall exits 1 whenever ANY file fails to compile (packages ship Python-2 fixtures: func_timeout/py2_raise.py,
    # one selenium file). It still compiles everything else, so exit 1 is a completed run for that reference row.
    if r.get("cfg") == "compileall_j1_serial":
        return r.get("exit_import1", 0) in (0, 1)
    return all(v == 0 for k, v in r.items() if k.startswith("exit"))


def agg(xs):
    xs = sorted(xs)
    return {"median": round(st.median(xs), 3), "min": xs[0], "max": xs[-1], "n": len(xs)} if xs else None


def group(rs, key, field):
    out = {}
    for r in rs:
        out.setdefault(key(r), []).append(r[field])
    return {k: agg(v) for k, v in out.items()}


def analyse(nd: Path):
    F = {"dir": nd.name, "experiments": {}}
    envs = {}
    for ed in sorted(p for p in nd.iterdir() if p.is_dir()):
        rs = rows(ed); good = [r for r in rs if ok(r)]
        env = json.loads((ed / "env.json").read_text()) if (ed / "env.json").exists() else {}
        envs[ed.name] = {k: env.get(k) for k in ("arch", "kernel", "cpuset", "affinity_cpus", "cgroup_cpu_max", "uv_cache_fs", "started_utc")}
        E = {"rows": len(rs), "failed_rows": len(rs) - len(good)}
        name = ed.name

        if name == "import":
            by = {}
            for r in good:
                by.setdefault(r["cfg"], []).append(r)
            E["configs"] = {}
            for cfg, rr in by.items():
                E["configs"][cfg] = {
                    "install_s": agg([r["install_s"] for r in rr]), "first_import_s": agg([r["first_import_s"] for r in rr]),
                    "second_import_s": agg([r["second_import_s"] for r in rr]), "total_install_plus_first_import_s": agg([r["total_s"] for r in rr]),
                    "pyc_after_install": agg([r["pyc_after_install"] for r in rr]), "pyc_after_first_import": agg([r["pyc_after_first_import"] for r in rr]),
                }
                E["configs"][cfg]["first_import_penalty_s"] = round(E["configs"][cfg]["first_import_s"]["median"] - E["configs"][cfg]["second_import_s"]["median"], 3) if cfg != "compileall_j1_serial" else None
            c = E["configs"]
            if {"pip", "uv", "uv_compile"} <= set(c):
                tot = lambda k: c[k]["total_install_plus_first_import_s"]["median"]
                E["derived"] = {
                    "ratio_out_of_the_box_install_only": round(c["pip"]["install_s"]["median"] / c["uv"]["install_s"]["median"], 1),
                    "ratio_install_plus_bytecode_like_for_like": round(c["pip"]["install_s"]["median"] / c["uv_compile"]["install_s"]["median"], 1),
                    "ratio_install_plus_first_import_pip_vs_uv": round(tot("pip") / tot("uv"), 1),
                    "ratio_install_plus_first_import_pip_vs_uv_compile": round(tot("pip") / tot("uv_compile"), 1),
                    "uv_deferred_cost_lower_bound_s_(first_import_of_11_modules)": c["uv"]["first_import_penalty_s"],
                    "uv_deferred_cost_upper_bound_s_(compileall_j1_serial)": c["compileall_j1_serial"]["first_import_s"]["median"] if "compileall_j1_serial" in c else None,
                    "uv_compile_bytecode_cost_s_(parallel)": round(c["uv_compile"]["install_s"]["median"] - c["uv"]["install_s"]["median"], 3),
                    "pyc_files_first_import_writes": c["uv"]["pyc_after_first_import"]["median"], "pyc_files_total": c["uv_compile"]["pyc_after_install"]["median"],
                }

        elif name == "same":
            E["same_thing"] = json.loads((ed / "same_thing.json").read_text()) if (ed / "same_thing.json").exists() else None
            E["install_s"] = {r["tool"]: r["install_s"] for r in good}

        elif name in ("disk", "disk_xdev"):
            by = {}
            for r in good:
                by.setdefault(r["tool"], []).append(r)
            E["tools"] = {}
            for tool, rr in by.items():
                mb = lambda k: round(st.median(r[k] for r in rr) / 1e6, 1)
                E["tools"][tool] = {"warm_install_s": agg([r["warm_install_s"] for r in rr]), "venv_apparent_mb": mb("venv_apparent_bytes"), "venv_actual_mb": mb("venv_actual_bytes"),
                                    "venv_pyc_mb": mb("venv_pyc_bytes"), "cache_mb": mb("cache_bytes"), "venv_plus_cache_actual_mb": mb("venv_plus_cache_actual_bytes"),
                                    "hardlinked_files": int(st.median(r["hardlinked_files"] for r in rr)), "cache_fs": rr[0]["cache_fs"], "venv_fs": rr[0]["venv_fs"]}

        elif name.startswith("cpu"):
            E["cpuset"] = good[0]["cpuset"] if good else None
            E["by_cfg_state"] = group(good, lambda r: f"{r['cfg']}.{r['state']}", "seconds")

        elif name == "mem":
            E["peak_rss_largest_process_mb"] = group(good, lambda r: f"{r['tool']}.{r['state']}", "peak_rss_largest_process_mb")
            E["seconds"] = group(good, lambda r: f"{r['tool']}.{r['state']}", "seconds")

        elif name == "netem":
            E["by_delay_tool"] = group(good, lambda r: f"+{r['added_delay_ms']}ms.{r['tool']}", "seconds")
            E["tcp_connect_ms"] = group(good, lambda r: f"+{r['added_delay_ms']}ms", "tcp_connect_ms")
            E["ratio_by_delay"] = {}
            for d in sorted({r["added_delay_ms"] for r in good}):
                p, u = E["by_delay_tool"].get(f"+{d}ms.pip"), E["by_delay_tool"].get(f"+{d}ms.uv")
                if p and u:
                    E["ratio_by_delay"][f"+{d}ms"] = {"pip_over_uv": round(p["median"] / u["median"], 1), "pip_s": p["median"], "uv_s": u["median"]}
            if "+0ms" in E["ratio_by_delay"] and "+150ms" in E["ratio_by_delay"]:
                r0, r1 = E["ratio_by_delay"]["+0ms"], E["ratio_by_delay"]["+150ms"]
                E["slope_s_per_ms"] = {"pip": round((r1["pip_s"] - r0["pip_s"]) / 150, 3), "uv": round((r1["uv_s"] - r0["uv_s"]) / 150, 3)}

        elif name == "stale":
            E["by_tool"] = group(good, lambda r: r["tool"], "seconds")
            if {"pip", "uv"} <= set(E["by_tool"]):
                E["ratio"] = round(E["by_tool"]["pip"]["median"] / E["by_tool"]["uv"]["median"], 1)

        elif name == "sdist":
            E["by_tool_state"] = group(good, lambda r: f"{r['tool']}.{r['state']}", "seconds")

        elif name == "why":
            par = [r for r in good if r["probe"].startswith("par-")]
            E["startup_s"] = group([r for r in good if r["probe"] == "startup"], lambda r: r["tool"], "wall_s")
            E["parallelism"] = {}
            for k in sorted({(r["tool"], r["state"]) for r in par}):
                rr = [r for r in par if (r["tool"], r["state"]) == k]
                E["parallelism"][f"{k[0]}.{k[1]}"] = {"cpu_per_wall": agg([r["cpu_per_wall"] for r in rr]), "peak_threads": max(r["peak_threads"] for r in rr),
                                                      "peak_tcp443_conns": max(r["peak_tcp443_conns"] for r in rr), "wall_s": agg([r["wall_s"] for r in rr])}
            ph = [r for r in good if r["probe"] == "phases-nocompile"]
            if ph:
                tot, pre, ins = st.median(r["total_s"] for r in ph), st.median(r["before_install_s"] for r in ph), st.median(r["install_s"] for r in ph)
                dry = st.median(r["wall_s"] for r in good if r["probe"] == "dryrun"); noidx = st.median(r["wall_s"] for r in good if r["probe"] == "noindex-nocompile")
                E["pip_warm_nocompile_phases_s"] = {"total": round(tot, 2), "before_installing_collected_packages": round(pre, 2), "installing": round(ins, 2),
                    "dry_run_resolve_plus_prepare": round(dry, 2), "no_index_find_links_total": round(noidx, 2),
                    "index_page_parsing_estimate_(total - no_index)": round(tot - noidx, 2), "index_parsing_share_pct": round((tot - noidx) / tot * 100, 1),
                    "installing_share_pct": round(ins / tot * 100, 1)}
            c = json.loads((ed / "census.json").read_text()) if (ed / "census.json").exists() else {}
            E["requests_cold"] = {"pip": c.get("pip_requests_cold"), "uv": c.get("uv_requests_cold")}
            E["syscalls"] = {k: v for k, v in c.items() if k.startswith("strace")}
            E["uv_timers_warm"] = (ed / "uv-phases-warm.txt").read_text().strip().splitlines() if (ed / "uv-phases-warm.txt").exists() else []

        F["experiments"][name] = E
    F["env"] = envs
    (nd / "findings_nuances.json").write_text(json.dumps(F, indent=1), encoding="utf-8")
    return F


def show(F):
    print(f"\n=== {F['dir']}")
    X = F["experiments"]
    if "import" in X and "derived" in X["import"]:
        c, d = X["import"]["configs"], X["import"]["derived"]
        print("import — install + first import (medians):")
        for cfg in ("pip", "uv", "uv_compile", "compileall_j1_serial"):
            if cfg in c:
                v = c[cfg]
                print(f"  {cfg:22s} install {v['install_s']['median']:7.3f}  first-import {v['first_import_s']['median']:6.3f}  second {v['second_import_s']['median']:6.3f}  total {v['total_install_plus_first_import_s']['median']:7.3f}  pyc {v['pyc_after_install']['median']:.0f}->{v['pyc_after_first_import']['median']:.0f}")
        for k, v in d.items():
            print(f"  {k}: {v}")
    if "same" in X and X["same"].get("same_thing"):
        s = X["same"]["same_thing"]
        print(f"same — dists identical by content: {s['dists_same_content']}/{s['dists_pip']}; differing: {s['dists_different_content']}; files only uv: {s['files_only_uv_n']}; entrypoints differing target: {s['entrypoints_different_target']}")
    for k in ("disk", "disk_xdev"):
        if k in X:
            for t, v in X[k]["tools"].items():
                print(f"{k:9s} {t:4s} warm {v['warm_install_s']['median']:6.3f}s  venv {v['venv_actual_mb']:6.1f} MB (pyc {v['venv_pyc_mb']:5.1f})  cache {v['cache_mb']:6.1f}  venv+cache {v['venv_plus_cache_actual_mb']:6.1f} MB  hardlinks {v['hardlinked_files']}  cache_fs {v['cache_fs']}")
    for k in sorted(X):
        if k.startswith("cpu"):
            print(f"{k} (cpuset {X[k]['cpuset']}):", {kk: v["median"] for kk, v in X[k]["by_cfg_state"].items()})
    if "mem" in X:
        print("mem peak RSS MB:", {k: v["median"] for k, v in X["mem"]["peak_rss_largest_process_mb"].items()})
    if "netem" in X:
        print("netem:", X["netem"]["ratio_by_delay"], "slope s/ms:", X["netem"].get("slope_s_per_ms"), "tcp ms:", {k: v["median"] for k, v in X["netem"]["tcp_connect_ms"].items()})
    if "stale" in X:
        print("stale (610 s old cache):", {k: v["median"] for k, v in X["stale"]["by_tool"].items()}, "ratio", X["stale"].get("ratio"))
    if "sdist" in X:
        print("sdist (4 pins):", {k: v["median"] for k, v in X["sdist"]["by_tool_state"].items()})
    if "why" in X:
        W = X["why"]
        print("why — startup:", {k: v["median"] for k, v in W["startup_s"].items()})
        for k, v in W["parallelism"].items(): print(f"  {k:9s} cpu/wall {v['cpu_per_wall']['median']:.2f}  threads {v['peak_threads']:3d}  tcp443 {v['peak_tcp443_conns']:3d}")
        print("  pip warm --no-compile phases:", W.get("pip_warm_nocompile_phases_s"))
        print("  requests cold:", W["requests_cold"])
        for k, v in W["syscalls"].items(): print(f"  {k:26s} total {v['total_calls']:7d} linkat {v.get('linkat',0):5d} write {v.get('write',0):5d} fsync {v.get('fsync',0):4d} stat {v.get('newfstatat',0)+v.get('statx',0):6d}")
        print("  uv timers:", W["uv_timers_warm"])
    failed = {k: v["failed_rows"] for k, v in X.items() if v["failed_rows"]}
    if failed:
        print("FAILED ROWS:", failed)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video_dir")
    ap.add_argument("--dir")
    a = ap.parse_args()
    vd = Path(a.video_dir)
    dirs = [vd / "results" / a.dir] if a.dir else sorted(d for d in (vd / "results").iterdir() if ("_nuances" in d.name or "_why" in d.name) and d.is_dir())
    for d in dirs:
        show(analyse(d))


if __name__ == "__main__":
    main()
