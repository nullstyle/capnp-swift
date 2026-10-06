#!/usr/bin/env python3
"""Ablation helper: prove a test can fail (CLAUDE.md, plan §9).

    scripts/ablate.py <file> <old> <new> [-- command ...]

Replaces exactly one occurrence of <old> with <new> in <file> (a path relative
to the repo root), runs the command (default: `mise exec -- zig build test
--summary all` in core/), restores the file byte for byte (verified by hash),
and prints the failure lines. Exit 0 iff the command FAILED, i.e. the ablation
was caught. Exit 1 when the suite still passed (the test has no teeth).
"""
import hashlib
import pathlib
import subprocess
import sys

repo = pathlib.Path(__file__).resolve().parents[1]
args = sys.argv[1:]
cmd = None
if "--" in args:
    i = args.index("--")
    args, cmd = args[:i], args[i + 1 :]
if len(args) != 3:
    sys.exit(__doc__)
path, old, new = args
f = repo / path
cwd = repo
if not cmd:
    cmd = ["mise", "exec", "--", "zig", "build", "test", "--summary", "all"]
    cwd = repo / "core"

orig = f.read_bytes()
h0 = hashlib.sha256(orig).hexdigest()
text = orig.decode()
n = text.count(old)
if n != 1:
    sys.exit(f"ablate: pattern must occur exactly once in {path} (found {n})")
try:
    f.write_text(text.replace(old, new))
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    out = r.stdout + r.stderr
finally:
    f.write_bytes(orig)
if hashlib.sha256(f.read_bytes()).hexdigest() != h0:
    sys.exit("ablate: RESTORE FAILED")

keys = ("FAIL", "fail", "error:", "expected", "passed", "✘")
lines = [l for l in out.splitlines() if any(k in l for k in keys)]
print("\n".join(lines[-25:]))
print(f"ablate: restored {path}; command exit {r.returncode}")
if r.returncode == 0:
    print("ablate: NOT CAUGHT (the suite still passed)")
    sys.exit(1)
print("ablate: CAUGHT")
