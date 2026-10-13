#!/usr/bin/env python3
"""Independently invert each network proof, rebuild, require its named failure,
then byte-restore the source and rebuild all 21 passing smoke proofs."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

sample = Path(__file__).resolve().parent.parent
source = sample / "Sources/WorkbenchKit/Client.swift"
original = source.read_bytes()
text = original.decode()
logs = Path(tempfile.mkdtemp(prefix="capnp-workbench-ablations-", dir="/tmp"))
conditions = [
    ('wire.callsSent == before + 2 && !observer.events.contains { $0.message == "Session result ready" }', "pipeline CALL is sent before server result is ready"),
    ('try echoResult.value() == "Echo: before-return"', "projected call resolves through returned session"),
    ('observer.events.contains { $0.message == "Session opening" }', "server invokes client callback capability"),
    ('try await exchangeParcel()', "unseen generic parcel survives separate-module RPC"),
    ('after.count == before.count + 12 && after.sequence == before.sequence + 12 && after.last == "Update \\(after.sequence)"', "stream receipt proves all acknowledged updates"),
    ('canceled && canceledAt.duration(to: .now) < .seconds(1)', "caller cancellation wakes before slow work completes"),
    ('try await echo("after-cancel") == "Echo: after-cancel"', "connection remains usable after caller cancellation"),
    ('policy.connection == nil', "background suspension releases managed connection"),
    ('connection !== first.connection', "foreground reconnect creates a fresh connection"),
    ('try await client.echo("foreground") == "Echo: foreground"', "foreground session completes a new RPC"),
    ('rejected', "wrong TLS certificate pin rejects connection"),
]
records = []

def build(name):
    result = subprocess.run(["swift", "build", "--package-path", str(sample), "--product", "workbench-smoke"], capture_output=True, timeout=180)
    (logs / (name + "-build.log")).write_bytes(result.stdout + result.stderr)
    assert result.returncode == 0, f"build failed: {name}"
    folder = subprocess.check_output(["swift", "build", "--package-path", str(sample), "--product", "workbench-smoke", "--show-bin-path"], text=True).strip()
    return Path(folder) / "workbench-smoke"

def run(binary, name):
    result = subprocess.run([str(binary)], capture_output=True, timeout=40)
    (logs / (name + "-run.log")).write_bytes(result.stdout + result.stderr)
    return result

try:
    for index, (condition, name) in enumerate(conditions, 1):
        prefix = f'try require({condition}, "{name}")'
        assert text.count(prefix) == 1, name
        source.write_text(text.replace(prefix, f'try require(!({condition}), "{name}")'))
        result = run(build(str(index) + "-red"), str(index) + "-red")
        assert result.returncode != 0 and name.encode() in result.stdout + result.stderr, name
        source.write_bytes(original)
        restored = run(build(str(index) + "-restored"), str(index) + "-restored")
        assert restored.returncode == 0 and restored.stdout.count(b"WORKBENCH_PASS") == 21, name
        records.append({"name": name, "inverted_exit": result.returncode, "named_failure": True, "restored_checks": 21})
        print(f"ABLATION_PASS: {name}", flush=True)
finally:
    source.write_bytes(original)
    assert source.read_bytes() == original

final = run(build("final"), "final")
assert final.returncode == 0 and final.stdout.count(b"WORKBENCH_PASS") == 21
(logs / "results.json").write_text(json.dumps({"source_sha256": hashlib.sha256(original).hexdigest(), "assertions": records, "final_checks": 21}, indent=2) + "\n")
print(f"PASS: eleven independently failed/restored proofs; {logs}", flush=True)
