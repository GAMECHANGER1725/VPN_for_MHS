#!/usr/bin/env bash
#
# Scenario tests for classify_cgnat().
#
# This function decides whether the tool tells you "port forwarding will work"
# or "port forwarding cannot possibly work". Getting it wrong in either
# direction wastes hours, so each realistic topology gets an explicit case.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPN_DOCTOR_LIB_ONLY=1 . "$DIR/bin/vpn-doctor"

PASS=0; FAIL=0

# scenario <desc> <expect_state> <expect_layers> \
#          <pub4> <lan4> <router_wan> <cgnat_hop> <priv_hops> <trace>
scenario() {
  local desc="$1" want_state="$2" want_layers="$3"
  shift 3
  classify_cgnat "$@"
  local ok=1
  [ "$CGNAT_STATE" = "$want_state" ]  || ok=0
  [ "$NAT_LAYERS"  = "$want_layers" ] || ok=0
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL %s\n' "$desc"
    printf '       want state=%s layers=%s\n' "$want_state" "$want_layers"
    printf '       got  state=%s layers=%s\n' "$CGNAT_STATE" "$NAT_LAYERS"
    printf '       evidence: %s\n' "$CGNAT_EVIDENCE"
  fi
}

echo "Typical home broadband — one router, real public IP"
scenario "public IP, router agrees, one private hop" \
  none 1 \
  203.0.113.9 192.168.1.50 203.0.113.9 "" 1 "192.168.1.1 100.100.0.1"

scenario "public IP, one private hop, no UPnP answer" \
  none 1 \
  203.0.113.9 192.168.1.50 "" "" 1 "192.168.1.1 62.115.1.1"

echo
echo "CGNAT — the case that breaks port forwarding"
scenario "observed address is itself in 100.64/10 (conclusive)" \
  confirmed unknown \
  100.90.4.7 192.168.1.50 "" "" 0 ""

scenario "router WAN is CGNAT, Internet sees a different address" \
  confirmed "2+" \
  203.0.113.9 192.168.1.50 100.70.1.2 "" 1 "192.168.1.1 100.70.1.2"

scenario "traceroute crosses a 100.64/10 hop" \
  confirmed unknown \
  203.0.113.9 192.168.1.50 "" 100.70.1.2 2 "192.168.1.1 100.70.1.2"

scenario "observed address is RFC1918 (broken/proxied egress)" \
  confirmed unknown \
  192.168.99.4 192.168.1.50 "" "" 0 ""

echo
echo "Double NAT — router behind another router"
# Two private hops means traffic crosses more than one NAT, but when the
# observed public address is routable and no 100.64.0.0/10 hop appeared, that
# is multi-layer private NAT, not carrier-grade NAT. Reporting it as CGNAT
# sends the user to their ISP over a problem the ISP did not cause.
# See test-ownership.sh for the NAT_TYPE assertions.
scenario "two private hops, routable public IP: not CGNAT" \
  none "2+" \
  203.0.113.9 192.168.1.50 "" "" 2 "192.168.1.1 10.0.0.1 62.115.1.1"

scenario "router WAN is RFC1918, differs from observed" \
  confirmed "2+" \
  203.0.113.9 192.168.1.50 10.0.0.42 "" 2 "192.168.1.1 10.0.0.1"

echo
echo "No NAT at all"
scenario "this Mac holds the public address directly" \
  none 0 \
  203.0.113.9 203.0.113.9 "" "" 0 ""

echo
echo "Insufficient evidence — must not guess"
scenario "nothing known at all" \
  unknown unknown \
  "" "" "" "" 0 ""

scenario "public IP known but no traceroute data" \
  unknown unknown \
  203.0.113.9 192.168.1.50 "" "" 0 ""

echo
echo "Boundary conditions on 100.64.0.0/10"
scenario "100.63.255.255 is NOT cgnat space" \
  none 1 \
  100.63.255.255 192.168.1.50 100.63.255.255 "" 1 "192.168.1.1 62.115.1.1"

scenario "100.128.0.0 is NOT cgnat space" \
  none 1 \
  100.128.0.0 192.168.1.50 100.128.0.0 "" 1 "192.168.1.1 62.115.1.1"

scenario "100.64.0.0 IS cgnat space (lower bound)" \
  confirmed unknown \
  100.64.0.0 192.168.1.50 "" "" 0 ""

scenario "100.127.255.255 IS cgnat space (upper bound)" \
  confirmed unknown \
  100.127.255.255 192.168.1.50 "" "" 0 ""

echo
echo "Evidence is always populated when a verdict is reached"
classify_cgnat 100.90.4.7 192.168.1.50 "" "" 0 ""
if [ -n "$CGNAT_EVIDENCE" ]; then
  PASS=$((PASS+1)); echo "  ok   confirmed verdict carries evidence"
else
  FAIL=$((FAIL+1)); echo "  FAIL confirmed verdict carries no evidence"
fi

classify_cgnat "" "" "" "" 0 ""
if [ -z "$CGNAT_EVIDENCE" ]; then
  PASS=$((PASS+1)); echo "  ok   unknown verdict claims no evidence"
else
  FAIL=$((FAIL+1)); echo "  FAIL unknown verdict invented evidence: $CGNAT_EVIDENCE"
fi

echo
echo "State is fully reset between calls (no leakage)"
classify_cgnat 100.90.4.7 192.168.1.50 "" "" 0 ""
classify_cgnat 203.0.113.9 192.168.1.50 203.0.113.9 "" 1 "192.168.1.1 62.1.1.1"
if [ "$CGNAT_STATE" = "none" ] && [ "${CGNAT_EVIDENCE#*100.64.0.0/10}" = "$CGNAT_EVIDENCE" ]; then
  PASS=$((PASS+1)); echo "  ok   prior verdict does not leak into the next"
else
  FAIL=$((FAIL+1)); echo "  FAIL state leaked: state=$CGNAT_STATE evidence=$CGNAT_EVIDENCE"
fi

echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
