#!/usr/bin/env python3
"""Print a Markdown summary of build/synth: generic and SKY130 cell counts, area, timing."""
import os, re, sys

d = sys.argv[1]


def read(f):
    p = os.path.join(d, f)
    return open(p).read() if os.path.exists(p) else ""


def grab(pat, text, default="n/a"):
    m = re.findall(pat, text)
    return m[-1] if m else default   # last match = top-level total


gen, sky = read("generic_stat.rpt"), read("area.rpt")
CELLS = r"(\d+)\s+(?:[\d.E+]+\s+)?cells"
ffs = sum(int(n) for n in re.findall(r"(\d+)\s+[\d.E+]+\s+sky130_fd_sc_hd__df\w+", sky))
rows = [
    ("Generic cells (Yosys `synth`)", grab(CELLS, gen)),
    ("SKY130 HD cells", grab(CELLS, sky)),
    ("SKY130 HD area (um^2)", grab(r"Chip area for (?:top )?module .*?:\s*([\d.]+)", sky)),
    ("Flip-flops (SKY130)", ffs or "n/a"),
    ("WNS setup @ 10 ns (ns)", grab(r"worst slack max (\S+)", read("wns_setup.rpt"))),
    ("WNS hold (ns)", grab(r"worst slack min (\S+)", read("wns_hold.rpt"))),
    ("Fmax (OpenSTA, Small wire load, TT 25C 1.8V)", grab(r"fmax ([\d.]+ MHz)", read("fmax.rpt"))),
]
print("| Metric | Value |\n|---|---|")
for k, v in rows:
    print(f"| {k} | {v} |")
