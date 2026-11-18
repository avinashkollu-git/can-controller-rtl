#!/usr/bin/env python3
"""Regression runner (from amba-uvm-vip): tests x seeds, pass/fail summary, merged coverage.

Each run gets its own directory <out>/runs/<test>_s<seed>/ with sim.log and
coverage.dat. Then it writes:
  <out>/summary.md   pass/fail table, checks per bus, failures with repro commands
  <out>/coverage.md  merged functional coverage (scoreboard sampled table),
                     SVA cover hits and RTL line coverage
  <out>/junit.xml    for CI
Exit status is 0 only if every run passed.
"""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys, time
import xml.etree.ElementTree as ET

TESTS = ["regs_test", "frames_test", "arb_test", "rxerr_test", "busoff_test", "noise_test"]
VEC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "vectors", "frames.txt"))
# per-test frame count (+N); regs_test N = register write/read rounds
N_PER_TEST = {"busoff_test": 1}
ERR_RE = re.compile(r"^(UVM_ERROR|UVM_FATAL) (?!:)|^%Error|Assertion failed")


COLS = ["frames_checked", "rx_checked", "arb_cases", "aborted", "injected", "err_predicted_match",
        "err_bit", "err_stuff", "err_crc", "err_form", "err_ack"]


def run_one(a, test, seed):
    rundir = os.path.join(a.out, "runs", f"{test}_s{seed}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [os.path.abspath(a.bin), f"+UVM_TESTNAME={test}", f"+N={N_PER_TEST.get(test, a.n)}", f"+VEC={VEC}", "+UVM_NO_RELNOTES",
           f"+verilator+seed+{seed}"] + (["+waves"] if a.waves else [])
    env = dict(os.environ, VERILATOR_SOLVER=os.environ.get("VERILATOR_SOLVER", "z3 --in"))
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=rundir, capture_output=True, text=True, timeout=a.timeout, env=env)
        log, rc = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        log, rc = (e.stdout or b"").decode(errors="replace") + "\nTIMEOUT (wall clock)\n", -1
    open(os.path.join(rundir, "sim.log"), "w").write(log)
    first_err = next((l for l in log.splitlines() if ERR_RE.search(l)), None)
    passed = rc == 0 and "RESULT: PASS" in log and first_err is None
    if not passed and first_err is None:
        first_err = "no RESULT line (crash or timeout)" if "RESULT:" not in log else "RESULT: FAIL"
    stats = {}
    for l in log.splitlines():
        if l.startswith("STATS"):
            stats.update({k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", l)})
    covbins = [(m[0], m[1], m[2], int(m[3])) for m in re.findall(r"^COVBIN (\w+) (\w+) (\S+) (\d+)$", log, re.M)]
    return dict(test=test, seed=seed, passed=passed, secs=time.time() - t0, rundir=rundir,
                cmd=f"cd {rundir} && {' '.join(cmd)}", first_err=first_err, stats=stats, covbins=covbins)


def functional_coverage(results):
    """Sum the scoreboard's sampled bins over all runs."""
    hits = {}
    for r in results:
        for bus, cp, b, n in r["covbins"]:
            hits[(bus, cp, b)] = hits.get((bus, cp, b), 0) + n
    out = ["## Functional coverage (scoreboard sampled table, merged over all runs)\n",
           "| Group | Coverpoint | Bins hit | % | Bins never hit |", "|---|---|---|---|---|"]
    tot = {}
    for bus in sorted({k[0] for k in hits}):
        for cp in dict.fromkeys(k[1] for k in hits if k[0] == bus):
            bins = [(k[2], n) for k, n in hits.items() if k[0] == bus and k[1] == cp]
            h = sum(n > 0 for _, n in bins)
            t = tot.setdefault(bus, [0, 0]); t[0] += len(bins); t[1] += h
            miss = ", ".join(b for b, n in bins if n == 0) or "-"
            out.append(f"| {bus} | {cp} | {h}/{len(bins)} | {100.0 * h / len(bins):.1f} | {miss} |")
    for bus, (n, h) in sorted(tot.items()):
        out.append(f"| **{bus} total** | | {h}/{n} | **{100.0 * h / n:.1f}** | |")
    out += ["\n<details><summary>Hit counts per bin</summary>\n", "| Group | Coverpoint | Bin | Hits |",
            "|---|---|---|---|"]
    out += [f"| {k[0]} | {k[1]} | {k[2]} | {n} |" for k, n in hits.items()]
    return "\n".join(out) + "\n</details>\n"


def code_coverage(a, results):
    """Merge Verilator coverage.dat files: SVA cover properties + RTL line coverage."""
    dats = [os.path.join(r["rundir"], "coverage.dat") for r in results
            if os.path.exists(os.path.join(r["rundir"], "coverage.dat"))]
    if not dats or not shutil.which("verilator_coverage"):
        return "No coverage.dat files (or no verilator_coverage).\n"
    merged = os.path.join(a.out, "coverage_merged.dat")
    subprocess.run(["verilator_coverage", "--write", merged] + dats, check=True, capture_output=True)
    files, covers = {}, {}
    for ln in open(merged, errors="replace"):
        m = re.match(r"C '(.*)' (\d+)", ln.strip())
        if not m:
            continue
        kv = dict(f.split("\x02", 1) for f in m.group(1).split("\x01") if "\x02" in f)
        path, page, hit = kv.get("f", ""), kv.get("page", ""), int(m.group(2))
        if page.startswith("v_user") and path.startswith("sva/"):
            covers[(path, kv.get("o", "?"))] = covers.get((path, kv.get("o", "?")), 0) + hit
        elif path.startswith("rtl/"):
            t = files.setdefault(path, [0, 0])
            t[0] += 1
            t[1] += hit > 0
    hitc = sum(1 for n in covers.values() if n)
    out = [f"## SVA cover properties: {hitc}/{len(covers)} hit\n", "| File | Cover | Count |", "|---|---|---|"]
    out += [f"| {f} | {o} | {n} |" for (f, o), n in sorted(covers.items())]
    out += ["\n## RTL line/branch coverage (Verilator --coverage-line)\n",
            "| File | Points | Hit | % |", "|---|---|---|---|"]
    tot = [0, 0]
    for f in sorted(files):
        n, h = files[f]
        tot[0] += n; tot[1] += h
        out.append(f"| {f} | {n} | {h} | {100.0 * h / n:.1f} |")
    out.append(f"| **total** | {tot[0]} | {tot[1]} | {100.0 * tot[1] / max(tot[0], 1):.1f} |")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", required=True, help="simulator binary (build/Vtb)")
    ap.add_argument("--tests", default="all", help="comma list, or all")
    ap.add_argument("--seeds", type=int, default=5, help="seeds per test")
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=40, help="frames (or rounds) per run")
    ap.add_argument("--jobs", type=int, default=1, help="parallel runs (default 1: low CPU load)")
    ap.add_argument("--timeout", type=int, default=120, help="wall-clock seconds per run")
    ap.add_argument("--out", default="results/regress")
    ap.add_argument("--waves", action="store_true", help="dump waves.vcd in every run")
    a = ap.parse_args()

    tests = TESTS if a.tests == "all" else a.tests.split(",")
    jobs = [(t, s) for t in tests for s in range(a.first_seed, a.first_seed + a.seeds)]
    shutil.rmtree(a.out, ignore_errors=True)
    os.makedirs(a.out)

    t0 = time.time()
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        results = list(ex.map(lambda j: run_one(a, *j), jobs))
    wall = time.time() - t0
    npass = sum(r["passed"] for r in results)

    md = ["# Regression summary\n",
          f"**{npass}/{len(results)} passed**, {a.seeds} seed(s) x {len(tests)} test(s), "
          f"N={a.n} per run, wall time {wall:.1f} s, {a.jobs} worker(s)\n",
          "| Test | Runs | Pass | Fail | " + " | ".join(COLS) + " |", "|---|---|---|---|" + "---|" * len(COLS)]
    for t in tests:
        rs = [r for r in results if r["test"] == t]
        s = lambda k: sum(r["stats"].get(k, 0) for r in rs)
        md.append(f"| {t} | {len(rs)} | {sum(r['passed'] for r in rs)} | {sum(not r['passed'] for r in rs)} | "
                  + " | ".join(str(s(c)) for c in COLS) + " |")
    tot = lambda k: sum(r["stats"].get(k, 0) for r in results)
    md.append(f"| **total** | {len(results)} | {npass} | {len(results) - npass} | "
              + " | ".join(str(tot(c)) for c in COLS) + " |")
    md.append("\n## Failures\n")
    fails = [r for r in results if not r["passed"]]
    md += [f"- {r['test']} seed {r['seed']}: `{r['first_err']}`\n  - repro: `{r['cmd']}`" for r in fails] or ["None."]
    open(os.path.join(a.out, "summary.md"), "w").write("\n".join(md) + "\n")

    cov = "# Coverage\n\n" + functional_coverage(results) + "\n" + code_coverage(a, results)
    open(os.path.join(a.out, "coverage.md"), "w").write(cov)

    suite = ET.Element("testsuite", name="can-controller-rtl", tests=str(len(results)),
                       failures=str(len(fails)), time=f"{wall:.1f}")
    for r in results:
        tc = ET.SubElement(suite, "testcase", classname=r["test"], name=f"seed{r['seed']}", time=f"{r['secs']:.2f}")
        if not r["passed"]:
            ET.SubElement(tc, "failure", message=r["first_err"]).text = r["cmd"]
    ET.ElementTree(suite).write(os.path.join(a.out, "junit.xml"), encoding="utf-8", xml_declaration=True)

    for r in fails:
        print(f"FAIL {r['test']} seed {r['seed']}: {r['first_err']}\n  repro: {r['cmd']}")
    print(f"\n{npass}/{len(results)} passed in {wall:.1f} s: " + ", ".join(f"{c}={tot(c)}" for c in COLS))
    print(f"summary: {a.out}/summary.md  coverage: {a.out}/coverage.md")
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
