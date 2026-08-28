#!/usr/bin/env bash
#
# Tests for lib/peers.sh — peer metadata records.
#
# The one invariant that matters most: a peer record NEVER contains a private
# key or PSK. It is asserted directly here against real generated records.
#
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VPN_STATE="$(mktemp -d "${TMPDIR:-/tmp}/peertest.XXXXXX")"
export VPN_STATE
trap 'rm -rf "$VPN_STATE"' EXIT

. "$DIR/lib/common.sh"
. "$DIR/lib/peers.sh"
ensure_state_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2' got '$3')"; fi; }

CPUB="CLIENTPUBdddddddddddddddddddddddddddddddddd="

echo "record creation and readback"
peer_write_record phone "$CPUB" 10.77.0.2 active "my iphone"
if peer_exists phone; then ok "peer file created"; else bad "peer file missing"; fi
eq "name"     "phone"       "$(peer_get phone name)"
eq "pubkey"   "$CPUB"       "$(peer_get phone public_key)"
eq "address"  "10.77.0.2"   "$(peer_get phone address)"
eq "status"   "active"      "$(peer_get phone status)"
eq "notes"    "my iphone"   "$(peer_get phone notes)"

echo
echo "record is valid JSON"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json,sys; json.load(open('$(peer_file phone)'))" 2>/dev/null; then
    ok "parses as JSON"
  else
    bad "peer record is not valid JSON"
  fi
fi

echo
echo "THE invariant: no secret material in a peer record, ever"
if grep -qiE 'privatekey|privkey|presharedkey|"psk"' "$(peer_file phone)"; then
  bad "peer record contains a secret field name"
else
  ok "no secret field names in record"
fi

echo
echo "file permissions are 600"
PERM="$(stat -c '%a' "$(peer_file phone)" 2>/dev/null || stat -f '%Lp' "$(peer_file phone)" 2>/dev/null)"
eq "peer record is 0600" "600" "$PERM"

echo
echo "created_at is preserved across updates; updated_at is not asserted equal"
C1="$(peer_get phone created_at)"
sleep 1
peer_set_status phone revoked
eq "status changed"          "revoked" "$(peer_get phone status)"
eq "created_at unchanged"    "$C1"     "$(peer_get phone created_at)"
eq "address preserved"       "10.77.0.2" "$(peer_get phone address)"
eq "notes preserved"         "my iphone" "$(peer_get phone notes)"

echo
echo "listing"
peer_write_record laptop "$CPUB" 10.77.0.3 active ""
peer_write_record tablet "$CPUB" 10.77.0.4 active ""
eq "three peers listed" "laptop
phone
tablet" "$(peer_list_names)"

echo
echo "notes with quotes do not break the JSON"
peer_write_record weird "$CPUB" 10.77.0.5 active 'has "quotes" in it'
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json; json.load(open('$(peer_file weird)'))" 2>/dev/null; then
    ok "quoted notes still valid JSON"
  else
    bad "quoted notes broke JSON"
  fi
fi

echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
