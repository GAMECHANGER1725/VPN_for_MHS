#!/usr/bin/env bash
#
# Tests for lib/ipam.sh — address allocation.
#
# A duplicate address is the bug that bites intermittently in production, so
# allocation, release, reuse and pool exhaustion are all pinned down here.
#
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/ipam.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2' got '$3')"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ipamtest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
F="$TMP/ipam.txt"; : > "$F"

echo "arithmetic"
eq "ip4_to_int 10.77.0.0"    "172818432" "$(ip4_to_int 10.77.0.0)"
eq "int_to_ip4 round trip"   "10.77.0.1" "$(int_to_ip4 $(( $(ip4_to_int 10.77.0.0) + 1 )))"
eq "server_address 10.77.0.0/24" "10.77.0.1" "$(server_address 10.77.0.0/24)"
eq "server_address 10.83.4.0/24" "10.83.4.1" "$(server_address 10.83.4.0/24)"
eq "network int 10.77.0.128/24 normalises" "$(ip4_to_int 10.77.0.0)" "$(subnet_network_int 10.77.0.128/24)"
eq "broadcast 10.77.0.0/24"  "$(ip4_to_int 10.77.0.255)" "$(subnet_broadcast_int 10.77.0.0/24)"

echo
echo "bad input is rejected"
if ip4_to_int "10.77.0" >/dev/null 2>&1; then bad "short address accepted"; else ok "short address rejected"; fi
if ip4_to_int "10.77.0.256" >/dev/null 2>&1; then bad "octet>255 accepted"; else ok "octet>255 rejected"; fi
if ip4_to_int "x.y.z.w" >/dev/null 2>&1; then bad "non-numeric accepted"; else ok "non-numeric rejected"; fi

echo
echo "allocation starts at network+2 (network+1 is the server)"
eq "first peer"  "10.77.0.2" "$(ipam_allocate "$F" 10.77.0.0/24 phone)"
eq "second peer" "10.77.0.3" "$(ipam_allocate "$F" 10.77.0.0/24 laptop)"
eq "third peer"  "10.77.0.4" "$(ipam_allocate "$F" 10.77.0.0/24 tablet)"

echo
echo "allocation is idempotent (asking twice never double-assigns)"
eq "phone again same ip" "10.77.0.2" "$(ipam_allocate "$F" 10.77.0.0/24 phone)"
eq "count still 3"       "3" "$(ipam_count "$F")"

echo
echo "lookups"
eq "ip_for laptop"   "10.77.0.3" "$(ipam_ip_for "$F" laptop)"
eq "name_for .4"     "tablet"    "$(ipam_name_for "$F" 10.77.0.4)"
if ipam_is_taken "$F" 10.77.0.3; then ok ".3 is taken"; else bad ".3 should be taken"; fi
if ipam_is_taken "$F" 10.77.0.9; then bad ".9 should be free"; else ok ".9 is free"; fi

echo
echo "release frees the address, and it is reused before extending"
ipam_release "$F" laptop
eq "count back to 2" "2" "$(ipam_count "$F")"
if ipam_is_taken "$F" 10.77.0.3; then bad ".3 still taken after release"; else ok ".3 freed"; fi
eq "new peer reuses .3 (lowest free)" "10.77.0.3" "$(ipam_allocate "$F" 10.77.0.0/24 desktop)"

echo
echo "release is idempotent and safe on unknown names"
ipam_release "$F" neverexisted
eq "count unchanged" "3" "$(ipam_count "$F")"

echo
echo "no address is ever handed out twice across a churn sequence"
G="$TMP/churn.txt"; : > "$G"
for i in $(seq 1 20); do ipam_allocate "$G" 10.77.0.0/25 "peer$i" >/dev/null; done
ipam_release "$G" peer5; ipam_release "$G" peer10; ipam_release "$G" peer15
for i in 21 22 23; do ipam_allocate "$G" 10.77.0.0/25 "peer$i" >/dev/null; done
DUPES="$(awk '{print $1}' "$G" | sort | uniq -d | wc -l | tr -d ' ')"
eq "zero duplicate addresses after churn" "0" "$DUPES"
SERVER_TAKEN="$(ipam_name_for "$G" 10.77.0.1)"
eq "server address .1 never allocated to a peer" "" "$SERVER_TAKEN"

echo
echo "pool exhaustion returns non-zero rather than a bad address"
H="$TMP/tiny.txt"; : > "$H"
# /29 = 8 addrs: .0 net, .1 server, .2-.6 peers (5), .7 broadcast
for i in 1 2 3 4 5; do
  ipam_allocate "$H" 10.77.0.0/29 "p$i" >/dev/null || bad "allocation $i failed early"
done
if ipam_allocate "$H" 10.77.0.0/29 "one_too_many" >/dev/null 2>&1; then
  bad "6th allocation in a /29 should have failed"
else
  ok "pool exhaustion detected (returns non-zero)"
fi
eq "exactly 5 peers fit a /29" "5" "$(ipam_count "$H")"

echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
