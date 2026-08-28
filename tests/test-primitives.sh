#!/usr/bin/env bash
#
# Unit tests for the pure address-arithmetic helpers in bin/vpn-doctor.
#
# These functions decide whether the diagnostic reports CGNAT, so they get
# tested rather than trusted. They are pure bash with no macOS dependency,
# which is why this suite runs anywhere.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPN_DOCTOR_LIB_ONLY=1 . "$DIR/bin/vpn-doctor"

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {  # assert_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert_true()  { if "${@:2}"; then ok "$1"; else bad "$1 (expected true)"; fi; }
assert_false() { if "${@:2}"; then bad "$1 (expected false)"; else ok "$1"; fi; }

echo "ip4_to_int"
assert_eq "0.0.0.0"          "0"          "$(ip4_to_int 0.0.0.0)"
assert_eq "0.0.0.1"          "1"          "$(ip4_to_int 0.0.0.1)"
assert_eq "10.0.0.1"         "167772161"  "$(ip4_to_int 10.0.0.1)"
assert_eq "192.168.1.1"      "3232235777" "$(ip4_to_int 192.168.1.1)"
assert_eq "255.255.255.255"  "4294967295" "$(ip4_to_int 255.255.255.255)"
assert_eq "100.64.0.0"       "1681915904" "$(ip4_to_int 100.64.0.0)"

echo
echo "ip4_in_cidr"
assert_true  "10.0.0.5 in 10.0.0.0/8"        ip4_in_cidr 10.0.0.5 10.0.0.0/8
assert_true  "10.255.255.255 in 10.0.0.0/8"  ip4_in_cidr 10.255.255.255 10.0.0.0/8
assert_false "11.0.0.1 in 10.0.0.0/8"        ip4_in_cidr 11.0.0.1 10.0.0.0/8
assert_true  "192.168.1.7 in 192.168.1.0/24" ip4_in_cidr 192.168.1.7 192.168.1.0/24
assert_false "192.168.2.7 in 192.168.1.0/24" ip4_in_cidr 192.168.2.7 192.168.1.0/24
assert_true  "anything in 0.0.0.0/0"         ip4_in_cidr 8.8.8.8 0.0.0.0/0
assert_true  "exact /32 match"               ip4_in_cidr 1.2.3.4 1.2.3.4/32
assert_false "/32 near miss"                 ip4_in_cidr 1.2.3.5 1.2.3.4/32

echo
echo "is_cgnat  (RFC 6598 — 100.64.0.0/10 is 100.64.0.0 .. 100.127.255.255)"
assert_true  "100.64.0.0 lower bound"        is_cgnat 100.64.0.0
assert_true  "100.100.50.1 mid-range"        is_cgnat 100.100.50.1
assert_true  "100.127.255.255 upper bound"   is_cgnat 100.127.255.255
assert_false "100.63.255.255 just below"     is_cgnat 100.63.255.255
assert_false "100.128.0.0 just above"        is_cgnat 100.128.0.0
assert_false "100.0.0.1 outside"             is_cgnat 100.0.0.1

echo
echo "is_rfc1918"
assert_true  "10.1.2.3"                      is_rfc1918 10.1.2.3
assert_true  "172.16.0.1 lower bound"        is_rfc1918 172.16.0.1
assert_true  "172.31.255.255 upper bound"    is_rfc1918 172.31.255.255
assert_false "172.15.0.1 below /12"          is_rfc1918 172.15.0.1
assert_false "172.32.0.1 above /12"          is_rfc1918 172.32.0.1
assert_true  "192.168.50.4"                  is_rfc1918 192.168.50.4
assert_false "8.8.8.8 public"                is_rfc1918 8.8.8.8

echo
echo "is_special4  (anything that cannot accept inbound from the Internet)"
assert_true  "127.0.0.1 loopback"            is_special4 127.0.0.1
assert_true  "169.254.1.1 link-local"        is_special4 169.254.1.1
assert_true  "100.70.0.1 cgnat"              is_special4 100.70.0.1
assert_true  "192.168.1.1 private"           is_special4 192.168.1.1
assert_false "203.0.113.5 routable"          is_special4 203.0.113.5
assert_false "8.8.8.8 routable"              is_special4 8.8.8.8

echo
echo "hexmask_to_prefix"
assert_eq "0xffffffff -> 32" "32" "$(hexmask_to_prefix 0xffffffff)"
assert_eq "0xffffff00 -> 24" "24" "$(hexmask_to_prefix 0xffffff00)"
assert_eq "0xfffffe00 -> 23" "23" "$(hexmask_to_prefix 0xfffffe00)"
assert_eq "0xffff0000 -> 16" "16" "$(hexmask_to_prefix 0xffff0000)"
assert_eq "0xff000000 -> 8"  "8"  "$(hexmask_to_prefix 0xff000000)"
assert_eq "0x00000000 -> 0"  "0"  "$(hexmask_to_prefix 0x00000000)"

echo
echo "cidr_overlap  (VPN subnet conflict detection)"
assert_true  "identical /24"                 cidr_overlap 10.77.0.0/24 10.77.0.0/24
assert_true  "/24 inside /8"                 cidr_overlap 10.77.0.0/24 10.0.0.0/8
assert_true  "/8 contains /24 (order swap)"  cidr_overlap 10.0.0.0/8 10.77.0.0/24
assert_false "disjoint /24s"                 cidr_overlap 10.77.0.0/24 10.78.0.0/24
assert_false "10.x vs 192.168.x"             cidr_overlap 10.77.0.0/24 192.168.1.0/24
assert_true  "/24 inside its own /16"          cidr_overlap 172.29.13.0/24 172.29.0.0/16
assert_false "172.29/24 vs docker 172.17/16" cidr_overlap 172.29.13.0/24 172.17.0.0/16

echo
echo "v6_class"
assert_eq "loopback"    "loopback"   "$(v6_class ::1)"
assert_eq "link-local"  "link-local" "$(v6_class fe80::1)"
assert_eq "link-local uppercase" "link-local" "$(v6_class FE80::1)"
assert_eq "ula fd"      "ula"        "$(v6_class fd12:3456::1)"
assert_eq "ula fc"      "ula"        "$(v6_class fc00::1)"
assert_eq "global 2001" "global"     "$(v6_class 2001:db8::1)"
assert_eq "global 2606" "global"     "$(v6_class 2606:4700:4700::1111)"
assert_eq "global 3ffe" "global"     "$(v6_class 3ffe::1)"

echo
echo "json_escape"
assert_eq "plain"        'hello'          "$(json_escape 'hello')"
assert_eq "double quote" 'a\"b'           "$(json_escape 'a"b')"
assert_eq "backslash"    'a\\b'           "$(json_escape 'a\b')"
assert_eq "tab"          'a\tb'           "$(json_escape "$(printf 'a\tb')")"

echo
echo "probe_udp_egress — degrades safely when it cannot run"
probe_udp_egress "" "/nonexistent"
assert_eq "no python3 -> not tested (-1), not 'blocked'" "-1" "$UDP_EGRESS"
assert_eq "no python3 -> no mapped address invented" "" "$UDP_MAPPED"

probe_udp_egress "/usr/bin/python3" "/nonexistent/dir"
assert_eq "missing stun-probe.py -> not tested (-1)" "-1" "$UDP_EGRESS"
assert_eq "missing stun-probe.py -> no mapped address" "" "$UDP_MAPPED"

# The distinction matters: -1 means "we do not know", 0 means "we tested and
# UDP is blocked". Collapsing them would tell someone their network blocks
# WireGuard when we simply never checked.
probe_udp_egress "" ""
if [ "$UDP_EGRESS" != "0" ]; then
  ok "'not tested' is never reported as 'blocked'"
else
  bad "'not tested' collapsed into 'blocked'"
fi

echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
