#!/usr/bin/env python3
"""Diff the Windows engine (core.scan, app defaults) against the Swift engine
(`sweepcheck --app-defaults`) file by file. Both must agree on status,
reclaimable and size for every path, or the Windows build is not shipping the
Mac app's verdicts.

    swift build -c release --product sweepcheck
    python3 windows/tools/parity_check.py ~/Music/Ableton

Read-only. Exit 0 on zero mismatches.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "windows"))

from samplesweep_win import core  # noqa: E402


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = os.path.realpath(os.path.expanduser(sys.argv[1]))
    sweepcheck = os.path.join(REPO, ".build", "release", "sweepcheck")
    if not os.path.exists(sweepcheck):
        print(f"missing {sweepcheck}; run: swift build -c release --product sweepcheck")
        return 2

    t0 = time.time()
    proc = subprocess.run([sweepcheck, root, "--app-defaults"], capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr)
        return 2
    swift: dict[str, tuple[str, int, int]] = {}
    for line in proc.stdout.splitlines():
        status, recl, size, _bucket, path = line.split("\t", 4)
        swift[path] = (status, int(recl), int(size))
    t_swift = time.time() - t0

    t0 = time.time()
    result = core.scan(root, core.Options())
    t_py = time.time() - t0
    py: dict[str, tuple[str, int, int]] = {}
    for p in result.projects:
        for f in p.files:
            py[f.path] = (f.status, int(f.reclaimable), f.size)

    only_swift = sorted(set(swift) - set(py))
    only_py = sorted(set(py) - set(swift))
    mism = [(k, swift[k], py[k]) for k in swift if k in py and swift[k] != py[k]]

    print(f"swift: {len(swift)} files in {t_swift:.1f}s   python: {len(py)} files in {t_py:.1f}s")
    print(f"only in swift: {len(only_swift)}   only in python: {len(only_py)}   mismatches: {len(mism)}")
    sb = sum(v[2] for v in swift.values() if v[1]); pb = sum(v[2] for v in py.values() if v[1])
    print(f"reclaimable bytes  swift={sb}  python={pb}  {'OK' if sb == pb else 'DIFF'}")
    for k in only_swift[:10]:
        print("  swift-only", k)
    for k in only_py[:10]:
        print("  python-only", k)
    for k, a, b in mism[:20]:
        print(f"  MISMATCH {k}\n      swift={a}\n      python={b}")
    ok = not only_swift and not only_py and not mism
    print("PARITY OK" if ok else "PARITY FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
