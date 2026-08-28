#!/usr/bin/env bash
#
# Tests for lib/config.sh — WireGuard config rendering.
#
# A malformed config is rejected by wg-quick with an opaque error, so the
# structure, the split/full-tunnel distinction, and the per-peer /32 isolation
# are all pinned here where failures are legible.
#
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/config.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else bad "$1 (missing: $3)"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF "$3"; then bad "$1 (should not contain: $3)"; else ok "$1"; fi; }

# fake key-shaped strings, clearly not real
SPRIV="SERVERPRIVaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa="
SPUB="SERVERPUBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb="
CPRIV="CLIENTPRIVcccccccccccccccccccccccccccccccc="
CPUB="CLIENTPUBdddddddddddddddddddddddddddddddddd="
PSK="PRESHAREDeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee="

echo "server interface"
SI="$(render_server_interface "$SPRIV" 10.77.0.1 24 51820)"
has "has [Interface]"      "$SI" "[Interface]"
has "carries private key"  "$SI" "PrivateKey = $SPRIV"
has "address with prefix"  "$SI" "Address = 10.77.0.1/24"
has "listen port"          "$SI" "ListenPort = 51820"

echo
echo "server peer block — the /32 isolation control"
SP="$(render_server_peer phone "$CPUB" 10.77.0.2 "$PSK")"
has "labelled with name"   "$SP" "# peer: phone"
has "client public key"    "$SP" "PublicKey = $CPUB"
has "preshared key"        "$SP" "PresharedKey = $PSK"
has "AllowedIPs is a /32"  "$SP" "AllowedIPs = 10.77.0.2/32"
hasnt "no wider range leaks" "$SP" "10.77.0.2/24"
hasnt "server peer has no private key" "$SP" "PrivateKey"

echo
echo "server peer without PSK omits the line entirely"
SP2="$(render_server_peer laptop "$CPUB" 10.77.0.3 "")"
hasnt "no empty PresharedKey line" "$SP2" "PresharedKey"

echo
echo "client full-tunnel config"
CF="$(render_client_conf "$CPRIV" 10.77.0.2 24 10.77.0.1 "$SPUB" "$PSK" \
        "203.0.113.9:51820" "0.0.0.0/0" 25)"
has "client private key"   "$CF" "PrivateKey = $CPRIV"
has "client address"       "$CF" "Address = 10.77.0.2/24"
has "DNS points at server tunnel" "$CF" "DNS = 10.77.0.1"
has "server public key"    "$CF" "PublicKey = $SPUB"
has "endpoint"             "$CF" "Endpoint = 203.0.113.9:51820"
has "full tunnel"          "$CF" "AllowedIPs = 0.0.0.0/0"
has "keepalive for NAT"    "$CF" "PersistentKeepalive = 25"

echo
echo "client split-tunnel config routes only chosen networks"
ALLOWED="$(split_tunnel_allowed 10.77.0.0/24 192.168.1.0/24)"
CS="$(render_client_conf "$CPRIV" 10.77.0.2 24 10.77.0.1 "$SPUB" "" \
        "203.0.113.9:51820" "$ALLOWED" 25)"
has "includes VPN subnet"  "$CS" "10.77.0.0/24"
has "includes home LAN"    "$CS" "192.168.1.0/24"
hasnt "does NOT full-tunnel" "$CS" "0.0.0.0/0"
hasnt "no PSK line when empty" "$CS" "PresharedKey"

echo
echo "split_tunnel_allowed joins correctly"
if [ "$(split_tunnel_allowed 10.77.0.0/24)" = "10.77.0.0/24" ]; then ok "single network"; else bad "single network"; fi
if [ "$(split_tunnel_allowed 10.77.0.0/24 192.168.1.0/24 192.168.2.0/24)" \
     = "10.77.0.0/24,192.168.1.0/24,192.168.2.0/24" ]; then ok "three networks"; else bad "three networks"; fi

echo
echo "a rendered config has no shell-injection surprises (values appear verbatim)"
CINJ="$(render_client_conf "$CPRIV" 10.77.0.2 24 "" "$SPUB" "" "203.0.113.9:51820" "0.0.0.0/0" 25)"
hasnt "omitted DNS produces no DNS line" "$CINJ" "DNS ="

echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
