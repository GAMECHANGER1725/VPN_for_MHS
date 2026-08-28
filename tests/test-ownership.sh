#!/usr/bin/env bash
#
# Tests for assess_network_ownership() and the CGNAT/enterprise-NAT split.
#
# Both were added after a real audit came back from a Department of Education
# network that the tool happily reported as YELLOW. The regression case at the
# bottom is that exact environment.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPN_DOCTOR_LIB_ONLY=1 . "$DIR/bin/vpn-doctor"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# own <desc> <expect> <prefix> <cidr> <search> <resolvers> <gw> <icmp> <https> <hops>
own() {
  local desc="$1" want="$2"; shift 2
  assess_network_ownership "$@"
  if [ "$NET_OWNERSHIP" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc (want $want, got $NET_OWNERSHIP; score=$NET_OWNERSHIP_SCORE)"
    printf '       signals: %s\n' "$NET_OWNERSHIP_SIGNALS"
  fi
}

echo "residential networks"
own "typical home: /24, no search domain, DNS is the gateway, ICMP works" \
  residential 24 192.168.1.0/24 "" "192.168.1.1" 192.168.1.1 1 1 1

own "home with .local search domain and router DNS" \
  residential 24 192.168.1.0/24 "local" "192.168.1.1" 192.168.1.1 1 1 1

# A home double-router setup trips exactly one signal. One signal must not be
# enough to call a network institutional — that would be a false accusation.
own "home behind a second router: 1 signal is not enough to call it managed" \
  unknown 24 192.168.1.0/24 "" "192.168.1.1" 192.168.1.1 1 1 2

echo
echo "managed networks"
own "large subnet + directory search domain" \
  managed 19 10.225.160.0/19 "corp.example.win" "10.254.254.254" 10.225.160.1 1 1 1

own "central DNS + ICMP filtered" \
  managed 24 192.168.1.0/24 "" "10.254.254.254" 192.168.1.1 0 1 1

own "everything at once" \
  managed 16 10.0.0.0/16 "ad.example.com" "10.1.1.1" 10.0.0.1 0 1 3

echo
echo "regression: the real NSW DoE audit that was wrongly reported as YELLOW"
own "detnsw.win /19, central DNS, ICMP filtered, 2 private hops" \
  managed 19 10.225.160.0/19 "detnsw.win" "10.254.254.254" 10.225.160.1 0 1 2

assess_network_ownership 19 10.225.160.0/19 "detnsw.win" "10.254.254.254" 10.225.160.1 0 1 2
[ "$NET_OWNERSHIP_SCORE" -eq 5 ] && ok "all 5 signals fire on that network" \
  || bad "expected score 5, got $NET_OWNERSHIP_SCORE"

echo
echo "state does not leak between calls"
assess_network_ownership 16 10.0.0.0/16 "ad.example.com" "10.1.1.1" 10.0.0.1 0 1 3
assess_network_ownership 24 192.168.1.0/24 "" "192.168.1.1" 192.168.1.1 1 1 1
if [ "$NET_OWNERSHIP" = "residential" ] && [ "$NET_OWNERSHIP_SCORE" -eq 0 ] \
   && [ -z "$NET_OWNERSHIP_SIGNALS" ]; then
  ok "score and signals reset"
else
  bad "leaked: $NET_OWNERSHIP score=$NET_OWNERSHIP_SCORE signals=$NET_OWNERSHIP_SIGNALS"
fi

echo
echo "NAT type: carrier-grade vs multi-layer private"
nat() {
  local desc="$1" want_state="$2" want_type="$3"; shift 3
  classify_cgnat "$@"
  if [ "$CGNAT_STATE" = "$want_state" ] && [ "$NAT_TYPE" = "$want_type" ]; then
    ok "$desc"
  else
    bad "$desc (want $want_state/$want_type, got $CGNAT_STATE/$NAT_TYPE)"
    printf '       evidence: %s\n' "$CGNAT_EVIDENCE"
  fi
}

nat "routable public IP behind 2 private hops is enterprise NAT, not CGNAT" \
  none multi-layer-private \
  153.107.19.251 10.225.161.120 "" "" 2 "10.225.160.1 10.6.7.229 138.217.151.181"

nat "a real 100.64/10 hop is still carrier-grade NAT" \
  confirmed cgnat \
  203.0.113.9 192.168.1.50 "" 100.70.1.2 2 "192.168.1.1 100.70.1.2"

nat "unroutable observed address with 2 private hops is CGNAT" \
  confirmed cgnat \
  100.90.4.7 192.168.1.50 "" "" 2 "192.168.1.1 100.70.1.2"

nat "single NAT home broadband" \
  none single \
  203.0.113.9 192.168.1.50 203.0.113.9 "" 1 "192.168.1.1 62.1.1.1"

nat "no NAT at all" \
  none none \
  203.0.113.9 203.0.113.9 "" "" 0 ""

nat "router WAN is RFC1918 and differs: multi-layer, not carrier" \
  confirmed multi-layer-private \
  203.0.113.9 192.168.1.50 10.0.0.42 "" 2 "192.168.1.1 10.0.0.1"

nat "router WAN is 100.64/10: carrier-grade" \
  confirmed cgnat \
  203.0.113.9 192.168.1.50 100.70.1.2 "" 1 "192.168.1.1"

echo
echo "dedupe_lines"
OUT="$(printf 'a\na\nb\na\nc\n' | dedupe_lines | tr '\n' ' ')"
[ "$OUT" = "a b c " ] && ok "collapses repeats, preserves order" || bad "got '$OUT'"

echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
