#!/usr/bin/env bash
set -euo pipefail
sample=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$sample/../.." && pwd)
ref=${1:-HEAD}
logs=$(mktemp -d /tmp/capnp-workbench-archive.XXXXXX)
# A different folder name catches accidental dependence on checkout identity.
mkdir "$logs/source"
git -C "$repo" archive "$ref" | tar -x -C "$logs/source"
consumer="$logs/source/Examples/RPCWorkbench"
swift build --package-path "$consumer" --product workbench-smoke > "$logs/build.log" 2>&1
bin=$(swift build --package-path "$consumer" --product workbench-smoke --show-bin-path)
"$bin/workbench-smoke" > "$logs/run.log" 2>&1
[[ $(rg -c '^WORKBENCH_PASS' "$logs/run.log") == 21 ]] || { echo 'WORKBENCH_GATE_FAIL: archive smoke selection' >&2; exit 1; }
# The expected core is the archived ref's own released binaryTarget, so the
# gate follows each release's url + checksum flip (a hard-coded 0.1.1 URL
# failed the 0.1.2 release commit, CI 39195835543).
python3 - "$consumer/.build/workspace-state.json" "$logs/source/Package.swift" <<'PY'
import json, re, sys
state = json.load(open(sys.argv[1]))
manifest = open(sys.argv[2]).read()
release = re.search(r'\.binaryTarget\(\s*name: "CapnpCore",\s*url: "([^"]+)",\s*checksum: "([0-9a-f]{64})"\s*\)', manifest)
assert release, 'WORKBENCH_GATE_FAIL: archived Package.swift must name a released CapnpCore url'
url, checksum = release.groups()
assert url.startswith('https://github.com/nullstyle/capnp-swift/releases/download/'), \
    'WORKBENCH_GATE_FAIL: CapnpCore url must be a capnp-swift release asset'
core = next(a for a in state['object']['artifacts'] if a['targetName'] == 'CapnpCore')
assert core['source'] == {
    'type': 'remote',
    'url': url,
    'checksum': checksum,
}, 'WORKBENCH_GATE_FAIL: archive must use released remote core'
PY
echo "PASS: renamed clean archive, 21 checks, released remote core; logs: $logs"
