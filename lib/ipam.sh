#!/usr/bin/env bash
#
# lib/ipam.sh — IP address management for the VPN subnet.
#
# The allocation file (state/ipam.txt) is the source of truth: one
# "<ip> <name>" per line. The server always holds .1. Peers get the next free
# host address, and a released address is reused before the pool extends.
#
# Pure arithmetic and file bookkeeping — no WireGuard, no network. Fully
# testable off-macOS, which matters because a duplicate address assignment is
# the kind of bug that surfaces only intermittently in the field.

# ip4_to_int / int_to_ip4 — the two primitives everything else builds on.
ip4_to_int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1" || return 1
  [ -n "${d:-}" ] || return 1
  local o
  for o in "$a" "$b" "$c" "$d"; do
    printf '%s' "$o" | grep -Eq '^[0-9]+$' || return 1
    [ "$o" -le 255 ] || return 1
  done
  printf '%s' $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

int_to_ip4() {
  local n="$1"
  printf '%d.%d.%d.%d' $(( (n>>24)&255 )) $(( (n>>16)&255 )) $(( (n>>8)&255 )) $(( n&255 ))
}

# subnet_network <cidr> -> network address as int
subnet_network_int() {
  local net="${1%%/*}" bits="${1##*/}" ni mask
  ni=$(ip4_to_int "$net") || return 1
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  printf '%s' $(( ni & mask ))
}

# subnet_broadcast_int <cidr> -> broadcast address as int
subnet_broadcast_int() {
  local bits="${1##*/}" ni
  ni=$(subnet_network_int "$1") || return 1
  printf '%s' $(( ni | (0xFFFFFFFF >> bits) ))
}

# server_address <cidr> -> the server's tunnel IP (network + 1)
server_address() {
  local ni; ni=$(subnet_network_int "$1") || return 1
  int_to_ip4 $(( ni + 1 ))
}

# --------------------------------------------------------------------------
# Allocation file operations. All take the file path explicitly so tests can
# use a temp file and the real code passes $VPN_IPAM_FILE.
# --------------------------------------------------------------------------

# ipam_ip_for <file> <name> -> prints ip if name already allocated, else nothing
ipam_ip_for() {
  awk -v n="$2" '$2==n {print $1; exit}' "$1" 2>/dev/null
}

# ipam_name_for <file> <ip> -> prints name holding ip, else nothing
ipam_name_for() {
  awk -v ip="$2" '$1==ip {print $2; exit}' "$1" 2>/dev/null
}

# ipam_is_taken <file> <ip>
ipam_is_taken() {
  awk -v ip="$2" '$1==ip {found=1} END{exit found?0:1}' "$1" 2>/dev/null
}

# ipam_allocate <file> <cidr> <name>
#   Idempotent: if name already has an address, prints it and returns 0.
#   Otherwise assigns the lowest free host address (skipping network,
#   server .1, and broadcast), appends it, and prints it.
#   Returns 1 if the pool is exhausted, 2 on a bad subnet.
ipam_allocate() {
  local file="$1" cidr="$2" name="$3"

  local existing; existing="$(ipam_ip_for "$file" "$name")"
  if [ -n "$existing" ]; then printf '%s\n' "$existing"; return 0; fi

  local net bcast; net=$(subnet_network_int "$cidr") || return 2
  bcast=$(subnet_broadcast_int "$cidr") || return 2

  local candidate=$(( net + 2 ))   # net+1 is the server; peers start at net+2
  while [ "$candidate" -lt "$bcast" ]; do
    local ip; ip="$(int_to_ip4 "$candidate")"
    if ! ipam_is_taken "$file" "$ip"; then
      printf '%s %s\n' "$ip" "$name" >> "$file"
      printf '%s\n' "$ip"
      return 0
    fi
    candidate=$(( candidate + 1 ))
  done
  return 1   # exhausted
}

# ipam_release <file> <name> -> removes name's allocation (idempotent)
ipam_release() {
  local file="$1" name="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/ipam.XXXXXX")" || return 1
  awk -v n="$name" '$2!=n' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ipam_count <file> -> number of allocations
ipam_count() { grep -c . "$1" 2>/dev/null || printf '0'; }
