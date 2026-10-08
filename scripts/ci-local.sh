#!/usr/bin/env bash
# Run the GitHub workflows locally with act (host mode: the jobs' steps
# execute directly on this Mac — no containers, no Linux).
#
#   scripts/ci-local.sh                 # ci.yml, push event, every job
#   scripts/ci-local.sh push core       # one ci job
#   scripts/ci-local.sh schedule        # nightly.yml (fuzz/matrix/cpp/quic/ios-sim)
#   scripts/ci-local.sh schedule fuzz   # one nightly job
#
# The checkout step clones by $GITHUB_SHA into act's workspace, so the
# local run exercises the committed tree, not the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."

EVENT="${1:-push}"
shift || true
JOB="${1:-}"

if [ "$EVENT" = "push" ] || [ "$EVENT" = "pull_request" ]; then
  WORKFLOW=.github/workflows/ci.yml
elif [ "$EVENT" = "schedule" ] || [ "$EVENT" = "workflow_dispatch" ]; then
  WORKFLOW=.github/workflows/nightly.yml
else
  echo "ci-local: unknown event '$EVENT' (push|pull_request|schedule|workflow_dispatch)" >&2
  exit 2
fi

ARGS=("$EVENT" -W "$WORKFLOW")
[ -n "$JOB" ] && ARGS+=("-j" "$JOB")
exec act "${ARGS[@]}"
