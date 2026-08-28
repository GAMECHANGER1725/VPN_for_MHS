#!/usr/bin/env bash
#
# lib/config.sh — render WireGuard configuration files.
#
# Two producers:
#   render_server_conf   the wg-quick config for the Mac (the [Interface] plus
#                        one [Peer] block per provisioned peer)
#   render_client_conf   the config a single client device imports
#
# The rendering functions take every value as an argument and print to stdout.
# They touch no global state and no key files, so they are unit-testable
# without wg installed. bin/vpn is responsible for reading keys and passing
# them in — that keeps secret handling in one place.

# render_client_conf writes a [Interface]/[Peer] pair for one device.
#
#   render_client_conf <client_priv> <client_ip> <cidr_bits> <dns> \
#                      <server_pub> <psk> <endpoint> <allowed_ips> <keepalive>
#
# allowed_ips decides split vs full tunnel and is passed in, not assumed:
#   "0.0.0.0/0"                  full tunnel (all IPv4 through the VPN)
#   "10.77.0.0/24,192.168.1.0/24" split tunnel (VPN + home LAN only)
render_client_conf() {
  local cpriv="$1" cip="$2" bits="$3" dns="$4" spub="$5" psk="$6" \
        endpoint="$7" allowed="$8" keepalive="${9:-25}"

  printf '[Interface]\n'
  printf 'PrivateKey = %s\n' "$cpriv"
  printf 'Address = %s/%s\n' "$cip" "$bits"
  [ -n "$dns" ] && printf 'DNS = %s\n' "$dns"
  printf '\n[Peer]\n'
  printf 'PublicKey = %s\n' "$spub"
  [ -n "$psk" ] && printf 'PresharedKey = %s\n' "$psk"
  printf 'Endpoint = %s\n' "$endpoint"
  printf 'AllowedIPs = %s\n' "$allowed"
  # A roaming client behind NAT needs keepalive so the server can reach back.
  printf 'PersistentKeepalive = %s\n' "$keepalive"
}

# render_server_interface writes just the [Interface] stanza for the Mac.
#
#   render_server_interface <server_priv> <server_ip> <cidr_bits> <listen_port>
#
# No DNS/Address routing tricks here; NAT and forwarding are pf's job, wired
# up by the start command, not baked into the wg config. Keeping wg-quick's
# PostUp minimal makes teardown predictable.
render_server_interface() {
  local spriv="$1" sip="$2" bits="$3" port="$4"
  printf '[Interface]\n'
  printf 'PrivateKey = %s\n' "$spriv"
  printf 'Address = %s/%s\n' "$sip" "$bits"
  printf 'ListenPort = %s\n' "$port"
}

# render_server_peer writes one [Peer] block for the server config.
#
#   render_server_peer <name> <client_pub> <client_ip> <psk>
#
# AllowedIPs on the SERVER side is the peer's single tunnel address as a /32.
# This is the isolation control: it is what stops one peer from sourcing
# traffic as another. It is enforced by the server, never by client goodwill.
render_server_peer() {
  local name="$1" cpub="$2" cip="$3" psk="$4"
  printf '\n# peer: %s\n' "$name"
  printf '[Peer]\n'
  printf 'PublicKey = %s\n' "$cpub"
  [ -n "$psk" ] && printf 'PresharedKey = %s\n' "$psk"
  printf 'AllowedIPs = %s/32\n' "$cip"
}

# split_tunnel_allowed <vpn_cidr> <extra...> -> comma-joined AllowedIPs
# Builds the client AllowedIPs for split-tunnel mode: the VPN subnet plus any
# home networks the user wants reachable, and nothing else.
split_tunnel_allowed() {
  local out="$1"; shift
  local n
  for n in "$@"; do [ -n "$n" ] && out="$out,$n"; done
  printf '%s' "$out"
}
