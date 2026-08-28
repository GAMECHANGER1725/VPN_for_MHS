#!/usr/bin/env bash
#
# lib/common.sh — shared paths, logging, and secret-safe helpers.
#
# Sourced by bin/vpn and every lib/*.sh. Defines no policy on its own; it is
# the substrate the command modules build on.
#
# Layout on disk (all under $VPN_STATE, default ~/.config/vpn-for-mhs):
#
#   config/server.conf        non-secret server settings (subnet, port, ...)
#   state/keys/               private keys, dir 700, files 600, NEVER in git
#   state/peers/<name>.json   per-peer metadata — PUBLIC key only, no secrets
#   state/ipam.txt            address allocations, one "ip name" per line
#   state/rollback/           saved system state for clean uninstall
#   logs/vpn.log              operational log, secret-scrubbed
#
# The repository working tree holds code only. Live state lives outside it, so
# a stray `git add -A` cannot capture a key. .gitignore is a second line of
# defence, not the first.

set -uo pipefail

# --------------------------------------------------------------------------
# Root of all runtime state. Overridable for tests.
# --------------------------------------------------------------------------
: "${VPN_STATE:=${XDG_CONFIG_HOME:-$HOME/.config}/vpn-for-mhs}"

VPN_CONFIG_DIR="$VPN_STATE/config"
VPN_KEYS_DIR="$VPN_STATE/state/keys"
VPN_PEERS_DIR="$VPN_STATE/state/peers"
VPN_ROLLBACK_DIR="$VPN_STATE/state/rollback"
VPN_LOG_DIR="$VPN_STATE/logs"
VPN_IPAM_FILE="$VPN_STATE/state/ipam.txt"
VPN_SERVER_CONF="$VPN_CONFIG_DIR/server.conf"
VPN_LOG_FILE="$VPN_LOG_DIR/vpn.log"

# --------------------------------------------------------------------------
# Colour (respect NO_COLOR and non-tty)
# --------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RST=$'\033[0m'; _C_B=$'\033[1m'; _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'; _C_CYN=$'\033[36m'
else
  _C_RST=""; _C_B=""; _C_DIM=""; _C_RED=""; _C_GRN=""; _C_YEL=""; _C_CYN=""
fi

# --------------------------------------------------------------------------
# Messaging. Human output goes to stderr so stdout stays clean for data
# (a config, a public key) that a caller may want to capture.
# --------------------------------------------------------------------------
info()  { printf '%s\n' "$*" >&2; }
step()  { printf '%s==>%s %s\n' "$_C_B$_C_CYN" "$_C_RST" "$*" >&2; }
ok()    { printf '%s ok %s %s\n' "$_C_GRN" "$_C_RST" "$*" >&2; }
warn()  { printf '%swarn%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
die()   { printf '%sERROR:%s %s\n' "$_C_B$_C_RED" "$_C_RST" "$*" >&2; exit 1; }

# die_with_action <error> <reason> <suggested action>
# The house style for a good error: what failed, why, and what to do next.
die_with_action() {
  printf '%sERROR:%s %s\n\n%sReason:%s\n  %s\n\n%sSuggested action:%s\n  %s\n' \
    "$_C_B$_C_RED" "$_C_RST" "$1" \
    "$_C_B" "$_C_RST" "$2" \
    "$_C_B" "$_C_RST" "$3" >&2
  exit 1
}

# --------------------------------------------------------------------------
# Logging. Every line is scrubbed of anything key-shaped before it is written,
# so a private key can never reach the log even if a caller passes one in by
# mistake. WireGuard keys are 44-char base64 ending in '='.
# --------------------------------------------------------------------------
scrub_secrets() {
  sed -E 's#[A-Za-z0-9+/]{42,43}=#<redacted-key>#g'
}

log() {  # log <level> <message>
  [ -d "$VPN_LOG_DIR" ] || mkdir -p "$VPN_LOG_DIR" 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" \
    | scrub_secrets >> "$VPN_LOG_FILE"
}

# --------------------------------------------------------------------------
# Platform + dependency guards
# --------------------------------------------------------------------------
require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die_with_action \
    "This command only runs on macOS." \
    "The VPN server is designed for the M2 MacBook (uname reports $(uname -s))." \
    "Run it on the Mac that will host the VPN."
}

require_cmd() {  # require_cmd <bin> <brew-formula>
  command -v "$1" >/dev/null 2>&1 || die_with_action \
    "'$1' is not installed." \
    "This command needs $1, which is not on PATH." \
    "brew install ${2:-$1}"
}

# --------------------------------------------------------------------------
# Filesystem: create the state tree with correct, tight permissions.
# --------------------------------------------------------------------------
ensure_state_dirs() {
  umask 077   # everything we create is private by default
  mkdir -p "$VPN_CONFIG_DIR" "$VPN_KEYS_DIR" "$VPN_PEERS_DIR" \
           "$VPN_ROLLBACK_DIR" "$VPN_LOG_DIR" 2>/dev/null
  # keys directory must be 700 even if umask was looser upstream
  chmod 700 "$VPN_KEYS_DIR" 2>/dev/null || true
  [ -f "$VPN_IPAM_FILE" ] || : > "$VPN_IPAM_FILE"
}

# is the system initialised?
is_initialised() { [ -f "$VPN_SERVER_CONF" ]; }

require_initialised() {
  is_initialised || die_with_action \
    "The VPN is not initialised yet." \
    "No server configuration exists at $VPN_SERVER_CONF." \
    "vpn init"
}

# --------------------------------------------------------------------------
# server.conf is a flat KEY=value file. Read a single key.
# --------------------------------------------------------------------------
conf_get() {  # conf_get <KEY> [default]
  local key="$1" def="${2:-}" val=""
  if [ -f "$VPN_SERVER_CONF" ]; then
    val="$(grep -E "^${key}=" "$VPN_SERVER_CONF" 2>/dev/null | head -1 | cut -d= -f2-)"
  fi
  printf '%s' "${val:-$def}"
}

# Validate a name used for a peer or interface: lowercase alnum plus dash,
# 1-32 chars, must start alnum. Keeps names safe as filenames and wg keys.
valid_name() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,31}$'
}
