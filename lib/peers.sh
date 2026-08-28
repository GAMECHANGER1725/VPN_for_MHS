#!/usr/bin/env bash
#
# lib/peers.sh — peer records and the operations over them.
#
# A peer's metadata lives in state/peers/<name>.json and holds NON-SECRET
# fields only: name, public key, assigned IP, timestamps, status, notes. The
# private key and PSK live in state/keys/ and are never named here.
#
# Requires lib/common.sh, lib/keys.sh, lib/ipam.sh, lib/config.sh already
# sourced (bin/vpn does this).

peer_file() { printf '%s/%s.json' "$VPN_PEERS_DIR" "$1"; }
peer_exists() { [ -f "$(peer_file "$1")" ]; }

# json_str — emit a JSON string value with the handful of escapes we need.
_json_str() {
  local s="${1:-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

_json_get() {  # _json_get <file> <key>
  grep -E "\"$2\"[[:space:]]*:" "$1" 2>/dev/null | head -1 \
    | sed -E "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"?([^\",}]*)\"?.*/\1/"
}

peer_get() { _json_get "$(peer_file "$1")" "$2"; }

# peer_write_record <name> <pubkey> <ip> <status> <notes>
peer_write_record() {
  local name="$1" pub="$2" ip="$3" status="$4" notes="${5:-}"
  local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local created; created="$(peer_get "$name" created_at 2>/dev/null)"
  [ -n "$created" ] || created="$now"
  local f; f="$(peer_file "$name")"
  ( umask 077
    {
      printf '{\n'
      printf '  "name": %s,\n'       "$(_json_str "$name")"
      printf '  "public_key": %s,\n' "$(_json_str "$pub")"
      printf '  "address": %s,\n'    "$(_json_str "$ip")"
      printf '  "status": %s,\n'     "$(_json_str "$status")"
      printf '  "created_at": %s,\n' "$(_json_str "$created")"
      printf '  "updated_at": %s,\n' "$(_json_str "$now")"
      printf '  "notes": %s\n'       "$(_json_str "$notes")"
      printf '}\n'
    } > "$f"
  )
  chmod 600 "$f"
}

# peer_list_names -> one name per line, sorted
peer_list_names() {
  [ -d "$VPN_PEERS_DIR" ] || return 0
  local f
  for f in "$VPN_PEERS_DIR"/*.json; do
    [ -f "$f" ] || continue
    basename "$f" .json
  done | sort
}

# peer_set_status <name> <status>
peer_set_status() {
  peer_exists "$1" || return 1
  peer_write_record "$1" "$(peer_get "$1" public_key)" \
    "$(peer_get "$1" address)" "$2" "$(peer_get "$1" notes)"
}
