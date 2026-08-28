#!/usr/bin/env bash
#
# Run every test suite. Exits non-zero if any suite fails.
#
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RC=0
for SUITE in test-primitives.sh test-cgnat.sh test-report.sh test-ownership.sh test-ipam.sh test-config.sh test-peers.sh; do
  printf '\n=== %s ===\n' "$SUITE"
  bash "$DIR/$SUITE" || RC=1
done

printf '\n=== shell syntax ===\n'
for F in "$DIR/../bin/vpn-doctor" "$DIR"/*.sh; do
  if bash -n "$F" 2>/dev/null; then
    printf '  ok   %s\n' "$(basename "$F")"
  else
    printf '  FAIL %s\n' "$(basename "$F")"; RC=1
  fi
done

if command -v python3 >/dev/null 2>&1; then
  printf '\n=== python syntax ===\n'
  for PY in upnp-wan-ip.py stun-probe.py; do
    if python3 -c "import ast; ast.parse(open('$DIR/../bin/$PY').read())" 2>/dev/null; then
      printf '  ok   %s\n' "$PY"
    else
      printf '  FAIL %s\n' "$PY"; RC=1
    fi
  done

  printf '\n=== test-stun.py ===\n'
  python3 "$DIR/test-stun.py" || RC=1
fi

if command -v shellcheck >/dev/null 2>&1; then
  printf '\n=== shellcheck ===\n'
  if shellcheck -S warning -x "$DIR/../bin/vpn-doctor" "$DIR/../bin/vpn" "$DIR/../lib"/*.sh "$DIR"/*.sh; then
    printf '  ok   no warnings\n'
  else
    RC=1
  fi
else
  printf '\n=== shellcheck ===\n  skip (not installed)\n'
fi

printf '\n'
[ "$RC" -eq 0 ] && echo "ALL SUITES PASSED" || echo "FAILURES PRESENT"
exit "$RC"
