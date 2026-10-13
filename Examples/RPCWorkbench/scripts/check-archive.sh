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
python3 - "$consumer/.build/workspace-state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
core = next(a for a in state['object']['artifacts'] if a['targetName'] == 'CapnpCore')
assert core['source'] == {
    'type': 'remote',
    'url': 'https://github.com/nullstyle/capnp-swift/releases/download/0.1.1/CapnpCore.xcframework.zip',
    'checksum': '750f53096f825ba211607b27adcbdd6216e487b1f6c03b0b11135427af975340',
}, 'WORKBENCH_GATE_FAIL: archive must use released remote core'
PY
echo "PASS: renamed clean archive, 21 checks, released remote core; logs: $logs"
