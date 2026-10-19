#!/usr/bin/env bash
# Self-test for scripts/e2e-known-limits.sh: feeds synthetic client output
# to e2e_tally and checks every branch (plan §8 M8). Exit 0 when all pass.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/e2e-known-limits.sh

E2E_KNOWN_LIMITS=(
  "srv|cli|demo|xfail|strict line|reason S"
  "srv|cli|demo|mayfail|timing line|reason T"
)
checks=0; failures=0

# expect NAME WANT_FAIL WANT_KNOWN EXIT OUTPUT [SERVER CLIENT]
expect() {
  local name=$1 want_fail=$2 want_known=$3 exit_code=$4 out=$5
  e2e_tally "${6:-/bin/srv}" "${7:-/bin/cli}" demo "$out" "$exit_code"
  checks=$((checks + 1))
  if [ "$TALLY_FAIL" = "$want_fail" ] && [ "$TALLY_KNOWN" = "$want_known" ]; then
    echo "ok $checks - $name"
  else
    failures=$((failures + 1))
    echo "not ok $checks - $name (fail=$TALLY_FAIL known=$TALLY_KNOWN, want $want_fail/$want_known)"
  fi
}

nl=$'\n'
expect "all ok, exit 0" 0 0 0 "ok 1 - a${nl}ok 2 - b${nl}1..2"
expect "a listed xfail line fails, exit 1: the run passes" 0 1 1 "ok 1 - a${nl}not ok 2 - strict line${nl}1..2"
expect "a listed mayfail line fails, exit 1: the run passes" 0 1 1 "ok 1 - a${nl}not ok 2 - timing line${nl}1..2"
expect "a listed mayfail line passes: the run passes" 0 0 0 "ok 1 - a${nl}ok 2 - timing line${nl}1..2"
expect "a listed xfail line passes: the run fails (limit gone)" 1 0 0 "ok 1 - a${nl}ok 2 - strict line${nl}1..2"
expect "an unlisted line fails: the run fails" 2 0 1 "ok 1 - a${nl}not ok 2 - other${nl}1..2"
expect "listed + unlisted failures: the run fails" 1 1 1 "ok 1 - a${nl}not ok 2 - strict line${nl}not ok 3 - other${nl}1..3"
expect "a listed failure does not explain a deadline (exit 124)" 1 1 124 "ok 1 - a${nl}not ok 2 - strict line"
expect "exit 1 with no failed line fails" 1 0 1 "ok 1 - a${nl}1..1"
expect "no ok line fails" 1 0 0 "1..0"
expect "entries match the exact server and client" 2 0 1 "ok 1 - a${nl}not ok 2 - strict line" /bin/other /bin/cli
e2e_tally /bin/srv /bin/cli demo "ok 1 - a${nl}not ok 2 - strict line${nl}junk line" 1
checks=$((checks + 1))
if [ "$TALLY_LINES" = "  ok 1 - a${nl}  not ok 2 - strict line # TODO reason S${nl}" ]; then
  echo "ok $checks - known lines are annotated, other output is dropped"
else
  failures=$((failures + 1)); echo "not ok $checks - annotation: $TALLY_LINES"
fi

echo "1..$checks"
[ "$failures" -eq 0 ]
