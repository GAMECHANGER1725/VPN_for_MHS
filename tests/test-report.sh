#!/usr/bin/env bash
#
# Tests for the JSON report emitter.
#
# The JSON report is the machine-readable handoff between phases and is written
# to disk with --save. Malformed output here silently corrupts everything
# downstream, so it gets parsed by a real JSON parser, not eyeballed.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPN_DOCTOR_LIB_ONLY=1 . "$DIR/bin/vpn-doctor"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

PARSER=""
if command -v python3 >/dev/null 2>&1; then PARSER=python3; fi

check_valid_json() {  # check_valid_json <desc> <json>
  if [ -z "$PARSER" ]; then
    printf '  skip %s (no python3 to validate with)\n' "$1"; return
  fi
  if printf '%s' "$2" | "$PARSER" -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "$1"
  else
    bad "$1 — parser rejected the output"
    printf '%s\n' "$2" | sed 's/^/       /'
  fi
}

echo "empty report (no facts, no findings)"
FACT_N=0; FINDINGS_N=0; FACT_KEYS=(); FACT_VALS=(); FINDINGS=()
OUT="$(emit_json)"
check_valid_json "emits parseable JSON with nothing collected" "$OUT"

echo
echo "facts only"
FACT_N=0; FINDINGS_N=0
fact verdict "YELLOW"
fact public_ipv4 "203.0.113.9"
fact cgnat_state "none"
OUT="$(emit_json)"
check_valid_json "emits parseable JSON with facts" "$OUT"
if printf '%s' "$OUT" | grep -q '"verdict": "YELLOW"'; then ok "fact round-trips"; else bad "fact missing"; fi

echo
echo "facts + findings"
FACT_N=0; FINDINGS_N=0
fact verdict "RED"
finding BLOCK CGNAT_CONFIRMED "Your ISP places you behind carrier-grade NAT." "Port forwarding cannot fix this."
finding WARN SERVER_ON_WIFI "The uplink is Wi-Fi." "Prefer Ethernet."
OUT="$(emit_json)"
check_valid_json "emits parseable JSON with findings" "$OUT"
if [ -n "$PARSER" ]; then
  N="$(printf '%s' "$OUT" | "$PARSER" -c 'import json,sys; print(len(json.load(sys.stdin)["findings"]))' 2>/dev/null)"
  [ "$N" = "2" ] && ok "both findings present" || bad "expected 2 findings, got '$N'"
fi

echo
echo "hostile content must not break the JSON"
FACT_N=0; FINDINGS_N=0
fact quoted 'value with "double quotes" inside'
fact backslash 'C:\path\to\thing'
fact newline "$(printf 'line one\nline two')"
fact tabbed "$(printf 'a\tb')"
fact both 'he said "hi" and \escaped\'
fact empty ""
finding INFO ODD 'message with "quotes" and \backslash' 'action with "quotes"'
OUT="$(emit_json)"
check_valid_json "escapes quotes, backslashes, newlines and tabs" "$OUT"
if [ -n "$PARSER" ]; then
  V="$(printf '%s' "$OUT" | "$PARSER" -c 'import json,sys; print(json.load(sys.stdin)["quoted"])' 2>/dev/null)"
  [ "$V" = 'value with "double quotes" inside' ] && ok "quoted value survives round-trip" || bad "quoted value corrupted: '$V'"
  V="$(printf '%s' "$OUT" | "$PARSER" -c 'import json,sys; print(json.load(sys.stdin)["backslash"])' 2>/dev/null)"
  [ "$V" = 'C:\path\to\thing' ] && ok "backslashes survive round-trip" || bad "backslash corrupted: '$V'"
fi

echo
echo "a realistic full report parses"
FACT_N=0; FINDINGS_N=0
fact schema_version "1"; fact os_version "15.5"; fact arch "arm64"
fact primary_interface "en0"; fact link_type "wifi"
fact lan_cidr "192.168.1.0/24"; fact public_ipv4 "203.0.113.9"
classify_cgnat 100.90.4.7 192.168.1.50 "" "" 0 ""
fact cgnat_state "$CGNAT_STATE"; fact cgnat_evidence "$CGNAT_EVIDENCE"
fact verdict "RED"
finding BLOCK CGNAT_CONFIRMED "CGNAT confirmed." "See docs/limitations.md."
OUT="$(emit_json)"
check_valid_json "full report parses" "$OUT"

echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
