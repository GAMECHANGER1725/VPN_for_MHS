# VPN for MHS

A self-hosted WireGuard VPN running on a free-tier Oracle Cloud VM.

> **Project status: Phase 3 (Minimal working VPN) — in progress on Oracle Cloud.**
>
> The original design ran the server on a MacBook Air M2, on the theory that
> zero-cost meant no cloud component. Phase 1 reconnaissance on the home
> network, plus the practical reality of keeping a laptop always-on and
> reachable, made a small free-tier cloud VM the better trade: still zero
> recurring cost, but always-on and directly reachable with no CGNAT, no
> port-forwarding, and no dependency on a laptop staying awake. See
> [docs/architecture.md](docs/architecture.md) for the full reasoning and the
> decision points that led here.

---

## The three sentences that matter

**A small Oracle Cloud VM is the VPN server.** It is a real, always-on Linux
host with its own public IP — not a laptop pretending to be a server, and not
dependent on your home network's reachability.

**The server's own uplink is the VPN's Internet connection.** Full-tunnel
traffic exits through Oracle's network, at the cloud provider's speed, from
the server's public IP — not your home IP.

**If the server is down, the VPN is down.** That is now Oracle's uptime, not
your laptop's lid state — a meaningfully different (and much smaller) failure
mode than the original MacBook design, but still worth stating plainly.

The Phase 1 finding that started this pivot:

**Home network reachability was the open question, and it no longer has to be
answered.** Whether the home ISP uses carrier-grade NAT, and whether IPv6 was
usable, mattered a great deal when the plan was to open a port on a home
router. It stops mattering once the server lives somewhere with a routable
public IP by default. See [docs/limitations.md](docs/limitations.md) for what
still applies (this project still owns no cryptography and no protocol — that
part never changed) and [docs/architecture.md](docs/architecture.md) for what
the Oracle Cloud free tier does and doesn't guarantee.

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
| `--client-check` | Can a WireGuard *client* work on the network you're on right now? Fast, no sudo. |
| `--offline` | Make **zero** external network requests |
| `--fast` | Skip traceroute and `system_profiler` |
| `--no-color` | Plain output |

Exit codes: `0` clean, `1` one or more BLOCK findings, `2` bad usage,
`3` not macOS.

### Checking a network you're standing on

`vpn-doctor` still audits a macOS machine's own reachability, which no longer
decides where the server lives — but it remains the fast answer to a question
that still matters: "can a WireGuard *client* connect from this café / school
/ hotel?"

```sh
bin/vpn-doctor --client-check
```

One STUN round trip decides it. WireGuard is UDP-only, so a client works from a
network if and only if that network passes arbitrary outbound UDP. Run it
wherever you plan to connect from. [docs/networks.md](docs/networks.md) covers
what to expect by network type.

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
| Outbound UDP (STUN) | `stun.l.google.com:19302` | `STUN_SERVER` |
| Router WAN address | UPnP SSDP + SOAP, **LAN only** | — |

`--offline` skips all of them, at the cost of being unable to classify your
environment.

---

## Reading the verdict

| | Meaning |
|---|---|
| **GREEN** | Directly reachable and suitable. Only awarded after a real inbound handshake from outside your network — never from a self-test. |
| **YELLOW** | Workable, with router configuration or a stated caveat. |
| **RED** | Direct inbound connectivity is unavailable, or this is not a network you administer. |
| **UNKNOWN** | `--offline`, or evidence was insufficient. |

`vpn-doctor` will not report GREEN from inside your own LAN. A host cannot
prove that an inbound packet from the Internet would reach it by testing from
within the network that packet would have to cross. That proof belongs to
Phase 3, with a real client on cellular data.

Full breakdown of every check: [docs/reconnaissance.md](docs/reconnaissance.md).

---

## Is this even your network?

The audit checks whether the network it is running on is one you administer,
because the whole project assumes you can configure the router. Five signals
are weighed: a LAN larger than a `/24`, a DHCP-supplied directory search
domain, DNS that is neither the gateway nor on the local subnet, ICMP filtered
while HTTPS passes, and multiple layers of private routing.

Two or more and the run is classified **managed / institutional** and returns
RED. On a corporate, campus or school network you do not own the router,
inbound port forwarding is not yours to arrange, and whether a tunnel may cross
the network boundary at all is a question for whoever administers it — not one
that better WireGuard configuration answers.

One signal is deliberately not enough. A home behind two routers trips exactly
one, and the tool must not accuse a residential network of being institutional.

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
  Oracle Cloud VM (Ubuntu, Always Free tier)
      |   reserved public IPv4
      |   wireguard (kernel module) on wg0
      |   iptables NAT + Security List ingress rule, UDP/51820
      |   net.ipv4.ip_forward = 1
      v
  Oracle Cloud uplink  ->  rest of the Internet
```

WireGuard owns the cryptography. This project owns everything around it:
configuration, peer and key lifecycle, routing, DNS, firewall, diagnostics,
monitoring, automation and backup. **No custom cryptography, no custom
protocol** — those are non-goals, permanently.

Full design, including how this pivoted away from the original Mac-as-server
plan: [docs/architecture.md](docs/architecture.md).

---

## Repository layout

```
bin/
  vpn-doctor         Phase 1 environment audit (read-only)
  upnp-wan-ip.py     Router WAN address query via UPnP IGD (read-only)
  stun-probe.py      Outbound-UDP test via STUN (read-only)
tests/
  run-all.sh         Run every suite + syntax + shellcheck
  test-stun.py       STUN message parser
  test-primitives.sh Address/CIDR arithmetic
  test-cgnat.sh      CGNAT classification scenarios
  test-ownership.sh  Managed-network detection, NAT typing
  test-report.sh     JSON report emitter
docs/
  networks.md        Which networks a client can connect from, and why
  obfuscation.md     The TCP/443 cloak for UDP-blocking networks (school etc.)
  reconnaissance.md  What the audit checks and how to read it
  architecture.md    Design, including the Mac -> Oracle Cloud server pivot
  limitations.md     What this cannot do, stated plainly
reports/            Audit output (gitignored)
```

## Running the tests

```sh
bash tests/run-all.sh
```

126 assertions across five suites, plus syntax checks and shellcheck:

| Suite | Covers |
|---|---|
| `test-primitives.sh` | IPv4→int, CIDR containment, RFC 6598 boundaries, RFC 1918, netmask→prefix, subnet overlap, IPv6 classification, JSON escaping |
| `test-cgnat.sh` | The CGNAT classifier against realistic topologies: single-NAT home broadband, confirmed CGNAT via three different signals, double NAT, no NAT, insufficient evidence, `100.64.0.0/10` boundaries, and state leakage between runs |
| `test-ownership.sh` | Whether the network is one you administer, and the split between carrier-grade NAT and multi-layer private NAT — including a regression case built from a real institutional network the tool originally misread |
| `test-report.sh` | JSON emitter — empty report, facts, findings, and hostile content (embedded quotes, backslashes, newlines, tabs) validated by a real JSON parser |
| `test-stun.py` | STUN message construction and parsing, including malformed attributes |

These functions decide whether the tool tells you "port forwarding will work"
or "port forwarding cannot possibly work", and whether a given network will
carry WireGuard at all. Being wrong in either direction costs hours, so they
are tested rather than trusted. All are pure bash or pure Python with no
network dependency, which is why they can be verified anywhere even though the
audit itself only runs on macOS.

## Secrets

`.gitignore` blocks keys, generated configs, live state, backups, QR images and
audit reports from commit #1 onward, before any key exists to leak. No private
key will ever be committed, logged, or printed unless you explicitly export it.

## Roadmap

| Phase | | |
|---|---|---|
| 1 | Reconnaissance | superseded — home network reachability no longer gates the design once the server is cloud-hosted |
| 2 | Architecture | **decided: Oracle Cloud Always Free VM is the server**, see docs/architecture.md |
| 3 | Minimal working VPN, one client | **done** — full-tunnel verified end-to-end from a Mac client |
| 4 | Routing / NAT | not started |
| 5 | DNS | not started |
| 5b | TCP/443 cloak (wstunnel) for UDP-blocked networks | **designed** ([obfuscation.md](docs/obfuscation.md)); build not started |
| 6 | Peer management | not started |
| 7 | CLI | not started |
| 8 | Monitoring | not started |
| 9 | Automation / recovery | not started |
| 10 | Security hardening | not started |
| 11 | Testing | primitives only |
| 12 | Documentation | in progress |

Nothing above is marked done until it has been run on real hardware and the
result recorded.
