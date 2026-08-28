# Architecture

> **Pivot:** this document originally proposed a MacBook Air M2 as the VPN
> server, with the DECISION points below resolved by a `vpn-doctor` audit of
> the home network. That audit's core question — CGNAT, usable IPv6, router
> ownership — stopped mattering once the server moved to a small Oracle Cloud
> "Always Free" VM with its own routable public IP. The sections below are
> kept for the reasoning they still carry (subnet, DNS, key handling, threat
> model), with the home-network-specific decisions noted as superseded rather
> than deleted.

## Principle

WireGuard owns the cryptography. This project owns everything around it.

That division never moves. No custom crypto, no custom protocol, no
modification to WireGuard's data path. Engineering effort goes into
configuration, key lifecycle, routing, DNS, firewall, diagnostics, monitoring,
automation and backup — the parts that tutorials skip and that determine
whether a VPN is actually operable six months later.

## Data path

```
Client                                   Oracle Cloud VM (server)
──────                                   ────────────────────────
app traffic                              wireguard (kernel module, wg0)
   │                                          │
   ▼                                          ▼
WireGuard client                         iptables: nat (MASQUERADE) + filter
   │  ChaCha20-Poly1305                       │
   │  Curve25519 / BLAKE2s                    ▼
   │  UDP, one port                      net.ipv4.ip_forward = 1
   ▼                                          │
Internet ──▶ OCI Security List ──▶ VM ───────┘──▶ Oracle Cloud uplink
             (ingress rule)                       reserved public IP
```

## Component boundaries

| Concern | Owner | Why |
|---|---|---|
| Key exchange, cipher, handshake | **WireGuard** | Audited. Never reimplemented. |
| Tunnel interface lifecycle | `wg-quick` + kernel WireGuard | The supported Linux path. |
| Peer records, IP allocation, key rotation | this project | WireGuard has no notion of a named peer or an address pool. |
| NAT and forwarding | `iptables` + `sysctl` | Isolated rules so uninstall is exact. |
| Cloud-level ingress | OCI Security List | A second firewall layer in front of the OS's own. |
| DNS for clients | forwarder on the tunnel address | Keeps resolution off third-party resolvers by default. |
| Service lifecycle | `systemd` (`wg-quick@wg0`) | The correct Linux mechanism. Not a polling loop. |
| Diagnostics, health, benchmark | this project | The observability layer. |

---

## DECISION 0 — Is the network yours to configure? (superseded)

This assumed a home router you administer, with inbound port forwarding as the
gating question. It doesn't apply to a cloud VM: the VM has a directly
routable public IP and an OCI Security List you configure yourself through the
Oracle Cloud Console, not a home router. `vpn-doctor`'s network-ownership audit
remains useful for the separate *client*-side question — is the network a
device is connecting *from* one that blocks outbound UDP — see
[docs/networks.md](networks.md).

## DECISION 1 — Transport (superseded)

The original branch (NOT DETECTED / CONFIRMED+candidate / CONFIRMED+unusable /
LIKELY) existed entirely to route around home-network CGNAT and router
port-forwarding. An Oracle Cloud VM has a public IPv4 address by default —
reserved, in this project's case, so it never changes — with no NAT to
traverse and no ISP to negotiate with. Transport is simply: WireGuard over
UDP, one configurable port (default `51820`), opened in both the OCI Security
List and the VM's own `iptables`.

**Client-side UDP blocking still applies** and is unaffected by where the
server lives: the TCP/443 cloak ([obfuscation.md](obfuscation.md)) remains the
decided answer for networks (school, some corporate Wi-Fi) that block outbound
UDP for the *client*. It fixes client egress, not server reachability, and
those are independent problems.

**Found during the first real client test**: Oracle's default Ubuntu image
ships a `FORWARD` chain with policy `ACCEPT` but a single catch-all `REJECT`
rule at the top — the same pattern the image uses on `INPUT` for SSH. That
rule blocks all routed traffic, `INPUT`'s own allow-list does nothing for it,
and the symptom is confusing: the WireGuard handshake succeeds, the tunnel's
own address is pingable, but anything beyond it (`1.1.1.1`, the open internet)
comes back `ICMP administratively prohibited` from the server itself. Fixed
by inserting, above the `REJECT` line: `iptables -I FORWARD 1 -i wg0 -j
ACCEPT` and `iptables -I FORWARD 2 -o wg0 -m state --state
RELATED,ESTABLISHED -j ACCEPT`, then `netfilter-persistent save`. Anyone
rebuilding this box needs both the `INPUT` fix (for reaching the server) and
this `FORWARD` fix (for the server routing traffic onward) — they are two
separate chains and neither implies the other.

**Also worth knowing**: `wg-quick`'s full-tunnel mode on macOS replaces the
client's entire default route (via two `/1` routes) and rewrites DNS on every
network service the machine has, not just the active one. With the `FORWARD`
bug above still in place, that meant a client with no working route to
anywhere and no automatic recovery — worth testing a new server with a
restricted `AllowedIPs` (just the server's tunnel address, then a single
external IP) before ever trying `0.0.0.0/0`, so a forwarding bug can't take
the whole client offline.

## DECISION 2 — VPN subnet

Taken from the audit's conflict scan rather than hard-coded. Checked against
both this machine's networks and the ranges a roaming client is likely to sit
on. `10.77.0.0/24` is the first candidate, not a default. IPv6 side gets a
random RFC 4193 ULA `/64`, generated once at install and then fixed.

## DECISION 3 — DNS

Default target: a resolver reachable **only** on the tunnel address, forwarding
to a public resolver from the VM itself (e.g. `1.1.1.1`) rather than to
whatever a home router happened to hand out. No commercial provider is
required or hard-coded; the choice is configuration.

**DECISION**: run a local forwarder (`dnsmasq`/`unbound`) on the VM, bound to
the tunnel address only — a cloud VM has no home-router resolver to defer to,
so this is now the only sensible default rather than one branch of a choice.

Leak prevention is client-side and platform-specific, and will be documented
per platform rather than presented as one uniform recipe — because it isn't
one.

## DECISION 4 — IPv6 inside the tunnel

Advertised only once the VM's own IPv6 reachability (Oracle Cloud VMs get
IPv6 only if the VCN/subnet is configured for it) is confirmed working
end-to-end. Not assumed just because the VM has a public IPv4. A tunnel that
advertises `::/0` over a broken IPv6 path blackholes client traffic, which is
worse than no IPv6 at all. Until confirmed, client configs get explicit IPv6
leak prevention instead of silence.

---

## Planned layout

```
bin/
  vpn                 single CLI entry point (currently macOS-only; needs a
                       Linux backend — pf/launchd calls swapped for
                       iptables/systemd — before it can drive the Oracle VM)
  vpn-doctor          ✅ built (macOS client/network audit)
  upnp-wan-ip.py      ✅ built
lib/
  config.sh  peers.sh  keys.sh  net.sh  iptables.sh  dns.sh  health.sh
config/             chmod 700, gitignored
  server.conf  network.conf  dns.conf
  peers/<name>.json   metadata only — never private keys
state/              runtime: allocations, last-known public IP
  keys/             chmod 700, files chmod 600
systemd/
  wg-quick@wg0 (built into wireguard-tools) + a health-check unit/timer
iptables/
  vpnformhs.rules     our NAT + filter rules, restored via netfilter-persistent
tests/
docs/
```

Bash, because every operation is shelling out to `wg`, `iptables`,
`ip`/`route` and `systemctl` anyway, and a second language would add a
dependency without removing a subprocess. If peer state outgrows JSON files,
that is the point to reconsider — not before.

The initial Oracle VM setup in this pivot was done by hand over SSH (Phase 3)
rather than through `bin/vpn`, precisely because that CLI's platform layer is
still macOS-only. Bringing `bin/vpn` up to parity with what was done by hand —
so the *next* server, or a rebuild of this one, goes through the project's own
tested key/peer code instead of ad hoc shell commands — is tracked as its own
follow-up, not bundled into getting the first tunnel working.

## CLI surface

```
vpn doctor | install | init | uninstall
vpn start | stop | restart | status | logs [--security]
vpn peer list | add NAME | show NAME | export NAME
         remove NAME | revoke NAME | rotate NAME
vpn config validate | show          (never prints private keys)
vpn firewall status | network status
vpn backup | restore BACKUP
vpn check | benchmark
```

Error messages carry a reason and a next action, always:

```
ERROR: WireGuard tunnel could not start.

Reason:
  wireguard-go is not installed, so wg-quick has no userspace
  implementation to attach to utun.

Suggested action:
  brew install wireguard-go
  bin/vpn doctor
```

## Safety model for system changes

Every change to forwarding, pf, routing, DNS or power follows the same
sequence, with no exceptions:

1. **Inspect** current state.
2. **Explain** exactly what will change and why, in plain terms.
3. **Confirm** with you — no silent destructive changes.
4. **Back up** the prior state to `state/rollback/`.
5. **Apply.**
6. **Validate**, and roll back automatically if validation fails.

pf rules live in a dedicated anchor loaded from our own file. `/etc/pf.conf` is
Apple's and gets overwritten by OS updates; we never write to it. Uninstall is
a clean anchor unload, not a guess about which lines were ours.

## Key handling

- Generated with `wg genkey` (`getentropy`, not shell randomness).
- One keypair per device. No key is ever shared between peers.
- Private keys: `state/keys/`, mode 600, directory 700, never in git, never
  logged, never printed except by an explicit `vpn peer export`.
- Peer metadata files hold the **public** key only.
- Revocation removes the peer from the running interface *and* from the
  persisted config, then reloads — so a revoked peer cannot reconnect after a
  restart. This gets an explicit test in Phase 11.
- Rotation generates a new keypair, swaps it atomically, and reissues the
  client config.
- Backups encrypt the key material; the passphrase is never stored alongside.

## Threat model sketch

Full version lands in Phase 10. The questions being designed against:

- Can a revoked peer reconnect — immediately, or after a service restart?
- Can one peer impersonate or reach another? (`AllowedIPs` is the enforcement
  point, and it is enforced server-side, not by client politeness.)
- Does a stolen client config grant more than that one device's access?
- Are DNS or IPv6 leaks possible in each supported client configuration?
- Can a local unprivileged user on the Mac read key material?
- Does malformed config break the service, or fail closed?
- What is exposed to the Internet beyond one UDP port?

WireGuard's own properties do the heavy lifting: it is silent to unauthenticated
probes, so a port scan of the WireGuard port returns nothing and there is no
handshake to brute-force. Changing the port off 51820 reduces scanner log noise.
It is not a security control and will not be presented as one.
