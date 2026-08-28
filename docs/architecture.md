# Architecture (DRAFT — contingent on Phase 1 results)

> This is a proposal, not a built system. The branch points marked **DECISION**
> resolve once `bin/vpn-doctor` has run on the actual machine. Committing to
> one now would be guessing.

## Principle

WireGuard owns the cryptography. This project owns everything around it.

That division never moves. No custom crypto, no custom protocol, no
modification to WireGuard's data path. Engineering effort goes into
configuration, key lifecycle, routing, DNS, firewall, diagnostics, monitoring,
automation and backup — the parts that tutorials skip and that determine
whether a VPN is actually operable six months later.

## Data path

```
Client                                   MacBook Air M2 (server)
──────                                   ───────────────────────
app traffic                              wireguard-go  (userspace, utunN)
   │                                          │
   ▼                                          ▼
WireGuard client                         pf anchor: nat + filter
   │  ChaCha20-Poly1305                       │
   │  Curve25519 / BLAKE2s                    ▼
   │  UDP, one port                      net.inet.ip.forwarding = 1
   ▼                                          │
Internet ──▶ Home router ──▶ Mac ────────────┘──▶ Home LAN
             (port-forward)                       Home ISP uplink
```

## Component boundaries

| Concern | Owner | Why |
|---|---|---|
| Key exchange, cipher, handshake | **WireGuard** | Audited. Never reimplemented. |
| Tunnel interface lifecycle | `wg-quick` + `wireguard-go` | The supported macOS path. |
| Peer records, IP allocation, key rotation | this project | WireGuard has no notion of a named peer or an address pool. |
| NAT and forwarding | `pf` anchor + `sysctl` | Isolated so uninstall is exact. |
| DNS for clients | forwarder on the tunnel address | Keeps resolution inside the home. |
| Service lifecycle | `launchd` | The correct macOS mechanism. Not a polling loop. |
| Diagnostics, health, benchmark | this project | The observability layer. |

---

## DECISION 0 — Is the network yours to configure?

Everything below assumes you administer the router. If the audit returns
`network_ownership: managed`, no other decision matters: on an institutional
network inbound port forwarding is not available to you, and whether a tunnel
may cross the network boundary is a policy question for its administrators.
Re-run the audit on the network the server will actually live on.

## DECISION 1 — Transport, set by the CGNAT verdict

**`CGNAT: NOT DETECTED`** → IPv4 primary. One UDP port-forward on the router to
the Mac's LAN address, plus a DHCP reservation so that address is stable. IPv6
added as a second endpoint if the audit reports it `candidate`.

**`CGNAT: CONFIRMED` + IPv6 `candidate`** → IPv6-only inbound. Works, with a
hard caveat: clients on IPv4-only networks (most hotels, most cafés, some
carriers) cannot connect at all. Documented as a partial solution, never as a
complete one.

**`CGNAT: CONFIRMED` + IPv6 `unusable`** → **BLOCKED** for direct inbound. The
project reports it in the required format — reason, what was attempted, what is
required, zero-cost alternatives, security implications — and does not fake a
workaround. Remaining honest paths: ask the ISP for a public IPv4 (often free
on request); use the VPN LAN-only; or accept a third-party overlay with the
dependency stated explicitly. See [limitations.md](limitations.md) §4.

**Client-side UDP blocking (any verdict above)** → the TCP/443 cloak
([obfuscation.md](obfuscation.md)) is the decided answer, built as an opt-in
layer so the tunnel passes UDP-blocking networks like school. It is orthogonal
to the CGNAT question: it fixes client egress, not server reachability. If home
is CGNAT with no IPv6, the cloak cannot help — there is nothing at home to
reach — and the overlay in limitations.md §4 becomes the only zero-cost path.

**`CGNAT: LIKELY`** → resolve before building. Enable UPnP temporarily and
re-run, or read the router's WAN status page and compare it against the
observed public address.

## DECISION 2 — VPN subnet

Taken from the audit's conflict scan rather than hard-coded. Checked against
both this machine's networks and the ranges a roaming client is likely to sit
on. `10.77.0.0/24` is the first candidate, not a default. IPv6 side gets a
random RFC 4193 ULA `/64`, generated once at install and then fixed.

## DECISION 3 — DNS

Default target: a resolver reachable **only** on the tunnel address, forwarding
to whatever the Mac itself uses. No commercial provider is required or
hard-coded; the choice is configuration.

**DECISION**: whether to run a local forwarder (`dnsmasq`/`unbound` via
Homebrew, more moving parts, better control) or point clients directly at the
router's resolver through the tunnel (simpler, fewer failure modes). Resolved
by what the audit finds in section 5.

Leak prevention is client-side and platform-specific, and will be documented
per platform rather than presented as one uniform recipe — because it isn't
one.

## DECISION 4 — IPv6 inside the tunnel

Advertised **only** if the audit reports `candidate`. `partial` is not enough.
A tunnel that advertises `::/0` over a broken IPv6 path blackholes client
traffic, which is worse than no IPv6 at all. Where IPv6 is unusable, client
configs get explicit leak prevention instead of silence.

---

## Planned layout

```
bin/
  vpn                 single CLI entry point
  vpn-doctor          ✅ built
  upnp-wan-ip.py      ✅ built
lib/
  config.sh  peers.sh  keys.sh  net.sh  pf.sh  dns.sh  health.sh
config/             chmod 700, gitignored
  server.conf  network.conf  dns.conf
  peers/<name>.json   metadata only — never private keys
state/              runtime: allocations, last-known public IP
  keys/             chmod 700, files chmod 600
launchd/
  com.vpnformhs.server.plist
  com.vpnformhs.health.plist
pf/
  vpnformhs.anchor    our rules, loaded into a named anchor
tests/
docs/
```

Bash, because every operation is shelling out to `wg`, `pfctl`, `route`,
`scutil` and `networksetup` anyway, and a second language would add a
dependency without removing a subprocess. If peer state outgrows JSON files,
that is the point to reconsider — not before.

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
