#!/usr/bin/env bash
#
# lib/keys.sh — WireGuard key lifecycle.
#
# All cryptographic material comes from `wg` (genkey/pubkey/genpsk), which
# draws on the OS CSPRNG. This project generates NOTHING itself — no custom
# randomness, no custom key derivation. It only stores, permissions, and
# retrieves what wg produces.
#
# Invariants enforced here:
#   - private key files are created with mode 600 in a 700 directory
#   - a private key is never echoed to stdout by any function except the one
#     explicitly named to export it
#   - peer metadata records the PUBLIC key only

# key_paths_for <name> sets three globals rather than printing paths, so the
# private path is never accidentally captured into a log line.
key_priv_path() { printf '%s/%s.privkey' "$VPN_KEYS_DIR" "$1"; }
key_pub_path()  { printf '%s/%s.pubkey'  "$VPN_KEYS_DIR" "$1"; }
key_psk_path()  { printf '%s/%s.psk'     "$VPN_KEYS_DIR" "$1"; }

# keys_generate <name>
#   Creates <name>.privkey and <name>.pubkey if absent. Idempotent: existing
#   keys are left untouched so re-running init or add never rotates by surprise.
keys_generate() {
  local name="$1" priv pub
  priv="$(key_priv_path "$name")"; pub="$(key_pub_path "$name")"
  require_cmd wg wireguard-tools

  if [ -f "$priv" ]; then
    log INFO "keys_generate: $name already has keys, leaving untouched"
    return 0
  fi

  ( umask 077
    wg genkey > "$priv" ) || die "failed to generate private key for $name"
  chmod 600 "$priv"
  wg pubkey < "$priv" > "$pub" || die "failed to derive public key for $name"
  chmod 644 "$pub"
  log INFO "keys_generate: created keypair for $name"
}

# keys_generate_psk <name>
#   A preshared key adds a symmetric layer that hardens the handshake against
#   a future quantum adversary. One per peer, shared between that peer and the
#   server. Idempotent.
keys_generate_psk() {
  local name="$1" psk; psk="$(key_psk_path "$name")"
  require_cmd wg wireguard-tools
  [ -f "$psk" ] && return 0
  ( umask 077; wg genpsk > "$psk" ) || die "failed to generate PSK for $name"
  chmod 600 "$psk"
  log INFO "keys_generate_psk: created PSK for $name"
}

# keys_pubkey <name> -> prints the public key (safe to log/display)
keys_pubkey() {
  local pub; pub="$(key_pub_path "$1")"
  [ -f "$pub" ] || return 1
  cat "$pub"
}

# keys_read_private <name> -> prints the private key.
#   Deliberately named so its use is greppable. Only config assembly and an
#   explicit export should ever call it.
keys_read_private() {
  local priv; priv="$(key_priv_path "$1")"
  [ -f "$priv" ] || return 1
  cat "$priv"
}

keys_read_psk() {
  local psk; psk="$(key_psk_path "$1")"
  [ -f "$psk" ] || return 1
  cat "$psk"
}

keys_have() { [ -f "$(key_priv_path "$1")" ]; }

# keys_remove <name> -> shred-ish removal of all key material for a peer
keys_remove() {
  local name="$1" f
  for f in "$(key_priv_path "$name")" "$(key_pub_path "$name")" "$(key_psk_path "$name")"; do
    [ -f "$f" ] || continue
    # best-effort overwrite before unlink; macOS rm has no -P guarantee on SSD
    dd if=/dev/zero of="$f" bs=64 count=1 conv=notrunc 2>/dev/null || true
    rm -f "$f"
  done
  log INFO "keys_remove: removed key material for $name"
}

# keys_audit_permissions -> warns about any key file not 600. Used by health.
keys_audit_permissions() {
  local bad=0 f perm
  [ -d "$VPN_KEYS_DIR" ] || return 0
  for f in "$VPN_KEYS_DIR"/*.privkey "$VPN_KEYS_DIR"/*.psk; do
    [ -f "$f" ] || continue
    perm="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
    if [ "$perm" != "600" ]; then
      warn "key file has permissions $perm (expected 600): $(basename "$f")"
      bad=1
    fi
  done
  return $bad
}
