# Known limits of the e2e matrix, and the TAP tally that applies them.
# Sourced by scripts/e2e-pair.sh and scripts/e2e-pair-quic.sh (plan §8 M8).
#
# A known limit is one TAP line that fails for a documented reason. A listed
# `not ok` line is shown with `# TODO <reason>` and does not fail the run. One
# entry per line:
#
#   <server>|<client>|<schema>|<mode>|<TAP description>|<reason>
#
#   server, client: the binary's basename (exact).
#   mode: xfail    the line must fail. If it passes, the run fails: the limit
#                  is gone, so remove the entry (and update plan §8).
#         mayfail  timing decides; a pass and a fail are both fine.
#
# Native H9 (pending answers): the native core refuses a `receiverAnswer`
# param that names an answer still pending (PromisedCapUnsupported).
# capnp-zig v0.27.0 resolves it only once that answer has returned. The C++
# client sends Bootstrap and all four pipelined_params calls in one write,
# so check() always reaches the Swift server's core before mint() and
# mintFail() are answered. The Zig client writes each call on its own, and
# the Swift server answers mint() in about 0.2 ms, so the result depends on
# timing (QUIC: it failed; TCP and Unix: it mostly passed).
E2E_KNOWN_LIMITS=(
  "e2e-swift-server|e2e_client|pipelined_params|xfail|check(pipelined mint().token) called the server's own Token|native H9: receiverAnswer for a pending answer (PromisedCapUnsupported)"
  "e2e-swift-server|e2e_client|pipelined_params|xfail|check(pipelined mintFail().token) fails with mintFail()'s exception|native H9: receiverAnswer for a pending answer (PromisedCapUnsupported)"
  "e2e-swift-server|e2e-zig-client|pipelined_params|mayfail|check(pipelined mint().token) called the server's own Token|native H9 when mint() is still pending (timing)"
  "e2e-swift-server|e2e-zig-client|pipelined_params|mayfail|check(pipelined mintFail().token) fails with mintFail()'s exception|native H9 when mintFail() is still pending (timing)"
)

# e2e_known_limit SERVER CLIENT SCHEMA DESC -> prints "<mode>|<reason>" and
# returns 0 when the line is listed.
e2e_known_limit() {
  local server client entry s c sc mode desc reason
  server=$(basename "$1"); client=$(basename "$2")
  for entry in "${E2E_KNOWN_LIMITS[@]}"; do
    IFS='|' read -r s c sc mode desc reason <<<"$entry"
    if [ "$s" = "$server" ] && [ "$c" = "$client" ] && [ "$sc" = "$3" ] && [ "$desc" = "$4" ]; then
      printf '%s|%s\n' "$mode" "$reason"
      return 0
    fi
  done
  return 1
}

# e2e_tally SERVER CLIENT SCHEMA OUTPUT EXIT
# Scores one client run and sets:
#   TALLY_LINES  its TAP lines, indented, known limits annotated
#   TALLY_PASS   `ok` lines
#   TALLY_FAIL   unlisted `not ok` lines + xfail lines that passed + 1 when
#                the run failed for another reason (no `ok` line, or an exit
#                code that the listed failures do not explain)
#   TALLY_KNOWN  listed `not ok` lines
e2e_tally() {
  local server=$1 client=$2 schema=$3 out=$4 exit_code=$5 line desc hit mode reason
  TALLY_LINES=""; TALLY_PASS=0; TALLY_FAIL=0; TALLY_KNOWN=0
  while IFS= read -r line; do
    case "$line" in
      "ok "*)
        TALLY_PASS=$((TALLY_PASS + 1))
        desc=${line#* - }
        if hit=$(e2e_known_limit "$server" "$client" "$schema" "$desc"); then
          mode=${hit%%|*}
          if [ "$mode" = xfail ]; then
            TALLY_FAIL=$((TALLY_FAIL + 1))
            line="$line # known limit no longer fails: remove its entry in scripts/e2e-known-limits.sh"
          else
            line="$line # known limit did not trigger"
          fi
        fi
        ;;
      "not ok "*)
        desc=${line#* - }
        if hit=$(e2e_known_limit "$server" "$client" "$schema" "$desc"); then
          reason=${hit#*|}
          TALLY_KNOWN=$((TALLY_KNOWN + 1))
          line="$line # TODO $reason"
        else
          TALLY_FAIL=$((TALLY_FAIL + 1))
        fi
        ;;
      "1.."* | "# "*) ;;
      *) continue ;;
    esac
    TALLY_LINES+="  $line"$'\n'
  done <<<"$out"
  # A client exits 1 when any line fails; that exit is explained only when
  # every failed line is listed. Anything else (a deadline, a crash) fails.
  if [ "$TALLY_PASS" -eq 0 ]; then
    TALLY_FAIL=$((TALLY_FAIL + 1))
  elif [ "$exit_code" != 0 ] && ! { [ "$exit_code" = 1 ] && [ "$TALLY_KNOWN" -gt 0 ]; }; then
    TALLY_FAIL=$((TALLY_FAIL + 1))
  fi
}
