#!/usr/bin/env bash
# Point Package.swift's CapnpCore binaryTarget at the locally built
# XCFramework — the inverse of the release flip (docs/release.md step 3).
# CI and act runs call this right after building the framework, so a
# branch's core changes are what the Swift lanes actually test (with the
# committed url form they would silently test the released binary).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re
s = open('Package.swift').read()
new, n = re.subn(
    r'\.binaryTarget\(\s*name: "CapnpCore",\s*url: "[^"]+",\s*checksum: "[0-9a-f]+"\s*\)',
    '.binaryTarget(\n            name: "CapnpCore",\n            path: "CapnpCore.xcframework"\n        )',
    s, count=1)
if n == 0:
    if '.binaryTarget(\n            name: "CapnpCore",\n            path:' in s or 'path: "CapnpCore.xcframework"' in s:
        print("use-local-core: already on the local path")
        raise SystemExit(0)
    raise SystemExit("use-local-core: Package.swift has neither the url form nor the local path")
open('Package.swift', 'w').write(new)
print("use-local-core: CapnpCore -> local path")
PY
