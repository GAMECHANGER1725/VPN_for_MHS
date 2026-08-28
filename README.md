# VPN for MHS

A zero-cost, self-hosted WireGuard VPN where a MacBook Air M2 is the server.

> **Project status: Phase 1 (Reconnaissance) — instrument delivered, audit not yet run.**
>
> No VPN has been installed. No system setting has been changed. What exists
> today is the diagnostic that decides whether this project is viable at all,
> and the honest documentation of what it can and cannot do.

---

## The three sentences that matter

**Your Mac is the VPN server.** There is no cloud component, no VPS, no
provider. When you connect from your phone, your phone is talking to your
MacBook.

**Your home Internet connection is the VPN's Internet connection.** Full-tunnel
traffic exits through your home ISP, at your home upload speed, from your home
IP address.

**If the Mac is offline, the VPN is offline.** Asleep, lid closed, carried out
of the house, off Wi-Fi — the VPN is down. A MacBook Air is not a server, and
this project will not pretend otherwise.

A fourth sentence may also apply, and Phase 1 exists to find out:

**If your ISP uses carrier-grade NAT and you have no usable public IPv6,
direct inbound access to your home is impossible** — not difficult, not a
matter of finding the right router setting. Impossible. See
[docs/limitations.md](docs/limitations.md).

---

## Start here

```sh
git clone https://github.com/GAMECHANGER1725/VPN_for_MHS.git
cd VPN_for_MHS
bin/vpn-doctor
```

`vpn-doctor` is **read-only**. It does not install anything, does not modify
sysctls, pf, routes, DNS, power settings or launchd, and does not write outside
`reports/`. Read it before you run it — it is one bash file and that is
deliberate.

To capture the result for the next phase:

```sh
bin/vpn-doctor --with-sudo --save
```

`--with-sudo` adds read-only pf inspection (`pfctl -s info|rules|nat`), which
needs root to query. `--save` writes a JSON report to `reports/` — gitignored,
`chmod 600`, and containing your public IP and LAN topology, so review it
before sharing.

### Options

| Flag | Effect |
|---|---|
| *(none)* | Human-readable report |
| `--json` | Machine-readable report on stdout |
| `--save` | Write JSON to `reports/` (gitignored, mode 600) |
| `--with-sudo` | Also inspect pf ruleset (read-only, prompts for password) |
| `--offline` | Make **zero** external network requests |
| `--fast` | Skip traceroute and `system_profiler` |
| `--no-color` | Plain output |

Exit codes: `0` clean, `1` one or more BLOCK findings, `2` bad usage,
`3` not macOS.

### What it sends off-machine

By default `vpn-doctor` makes a small, disclosed set of external requests to
determine whether you are reachable from the Internet:

| Purpose | Destination | Override |
|---|---|---|
| Observed public IPv4 | `https://api.ipify.org` | `IPV4_ECHO_URL` |
| Observed public IPv6 | `https://api6.ipify.org` | `IPV6_ECHO_URL` |
| IPv4 reachability | ICMP to `1.1.1.1` | `PING4_TARGET` |
| IPv6 reachability | ICMP to `2606:4700:4700::1111` | `PING6_TARGET` |
| NAT depth | `traceroute` to `1.1.1.1` | `TRACE_TARGET` |
| DNS resolution | A-record for `example.com` | `DNS_TEST_NAME` |
| Router WAN address | UPnP SSDP + SOAP, **LAN only** | — |

`--offline` skips all of them, at the cost of being unable to classify your
environment.

---

## Reading the verdict

| | Meaning |
|---|---|
| **GREEN** | Directly reachable and suitable. Only awarded after a real inbound handshake from outside your network — never from a self-test. |
| **YELLOW** | Workable, with router configuration or a stated caveat. |
| **RED** | Direct inbound connectivity is unavailable. |
| **UNKNOWN** | `--offline`, or evidence was insufficient. |

`vpn-doctor` will not report GREEN from inside your own LAN. A host cannot
prove that an inbound packet from the Internet would reach it by testing from
within the network that packet would have to cross. That proof belongs to
Phase 3, with a real client on cellular data.

Full breakdown of every check: [docs/reconnaissance.md](docs/reconnaissance.md).

---

## Architecture

```
  Client (phone / laptop, anywhere)
      |
      |  WireGuard — ChaCha20-Poly1305, Curve25519, BLAKE2s
      |  UDP, single configurable port
      v
  Internet
      |
      v
  Home router          <- inbound UDP port-forward (IPv4)
      |                   or inbound v6 firewall rule (IPv6)
      v
  MacBook Air M2       <- wireguard-go on utunN
      |                   pf NAT in a dedicated anchor
      |                   net.inet.ip.forwarding = 1
      v
  Home LAN  +  Home ISP uplink
```

WireGuard owns the cryptography. This project owns everything around it:
configuration, peer and key lifecycle, routing, DNS, firewall, diagnostics,
monitoring, automation and backup. **No custom cryptography, no custom
protocol** — those are non-goals, permanently.

Draft design and the decision points that depend on your audit result:
[docs/architecture.md](docs/architecture.md).

---

## Repository layout

```
bin/
  vpn-doctor         Phase 1 environment audit (read-only)
  upnp-wan-ip.py     Router WAN address query via UPnP IGD (read-only)
tests/
  run-all.sh         Run every suite + syntax + shellcheck
  test-primitives.sh Address/CIDR arithmetic
  test-cgnat.sh      CGNAT classification scenarios
  test-report.sh     JSON report emitter
docs/
  reconnaissance.md  What the audit checks and how to read it
  architecture.md    Draft design, pending audit results
  limitations.md     What this cannot do, stated plainly
reports/            Audit output (gitignored)
```

## Running the tests

```sh
bash tests/run-all.sh
```

85 assertions across three suites, plus syntax checks and shellcheck:

| Suite | Covers |
|---|---|
| `test-primitives.sh` | IPv4→int, CIDR containment, RFC 6598 boundaries, RFC 1918, netmask→prefix, subnet overlap, IPv6 classification, JSON escaping |
| `test-cgnat.sh` | The CGNAT classifier against realistic topologies: single-NAT home broadband, confirmed CGNAT via three different signals, double NAT, no NAT, insufficient evidence, `100.64.0.0/10` boundaries, and state leakage between runs |
| `test-report.sh` | JSON emitter — empty report, facts, findings, and hostile content (embedded quotes, backslashes, newlines, tabs) validated by a real JSON parser |

These functions decide whether the tool tells you "port forwarding will work"
or "port forwarding cannot possibly work". Being wrong in either direction
costs hours, so they are tested rather than trusted. All are pure bash and run
on any platform, which is why they could be verified here even though the audit
itself cannot.

## Secrets

`.gitignore` blocks keys, generated configs, live state, backups, QR images and
audit reports from commit #1 onward, before any key exists to leak. No private
key will ever be committed, logged, or printed unless you explicitly export it.

## Roadmap

| Phase | | |
|---|---|---|
| 1 | Reconnaissance | **instrument ready — awaiting your audit** |
| 2 | Architecture | draft, blocked on Phase 1 result |
| 3 | Minimal working VPN, one client | not started |
| 4 | Routing / NAT | not started |
| 5 | DNS | not started |
| 6 | Peer management | not started |
| 7 | CLI | not started |
| 8 | Monitoring | not started |
| 9 | Automation / recovery | not started |
| 10 | Security hardening | not started |
| 11 | Testing | primitives only |
| 12 | Documentation | in progress |

Nothing above is marked done until it has been run on real hardware and the
result recorded.
