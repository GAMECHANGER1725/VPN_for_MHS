# Phase 1 — Reconnaissance

What `bin/vpn-doctor` inspects, why each check exists, and how to read the
result.

## Guarantees

- **Read-only.** No sysctl writes, no pf changes, no route changes, no DNS
  changes, no `pmset` changes, no launchd jobs, no installs. The only file it
  writes is a report under `reports/`, and only with `--save`.
- **Inspectable.** One bash file plus one Python helper. Both are commented and
  meant to be read before running.
- **Disclosed egress.** Every external destination is listed in the README and
  overridable by environment variable. `--offline` makes zero external
  requests.
- **Refuses to guess.** On a non-macOS host it exits 3 rather than producing a
  plausible-looking invalid report.

---

## Sections

### 1. System
`sw_vers`, `uname -m`, `sysctl hw.optional.arm64`, `machdep.cpu.brand_string`,
`hw.ncpu`, `hw.memsize`, `system_profiler` model identifier.

Confirms Apple Silicon and the macOS generation. Homebrew prefix
(`/opt/homebrew` vs `/usr/local`) and pf behaviour both depend on these.

### 2. Tooling
Homebrew, `wg`, `wg-quick`, `wireguard-go`, `qrencode`, `python3`, Xcode CLT.

Establishes what is already present. Installs nothing.

> macOS has no in-kernel WireGuard. A server here runs `wireguard-go` in
> userspace on a `utun` interface — supported and correct, but with different
> throughput and CPU characteristics than Linux. Phase 3 benchmarks it.

### 3. Network interfaces
`networksetup -listnetworkserviceorder`, `-listallhardwareports`,
`route -n get default`, `ifconfig`, `ipconfig getifaddr`.

Identifies the primary interface, whether the uplink is **Wi-Fi or Ethernet**,
the LAN subnet, and every other addressed interface.

Existing `utun` interfaces are enumerated. Some are benign (iCloud Private
Relay, Handoff); others mean a second VPN is already competing for routes.
`bridge100` appearing usually means macOS Internet Sharing is or was enabled,
which installs its own NAT and can collide with ours.

### 4. Routing
`netstat -rn` for both families. Counts default routes — **more than one IPv4
default route** means something else is contending for egress, which must be
resolved before adding a full-tunnel server.

### 5. DNS
`scutil --dns` (resolver #1), `networksetup -getdnsservers`, search domains,
then a live resolution test and a per-resolver reachability check.

Determines whether the resolver is the router itself, which is the default
design target: clients point at the Mac's tunnel address, the Mac forwards to
the router, and DNS never leaves your home.

### 6. Connectivity
ICMP to the gateway and to the Internet on both families, plus an HTTPS fetch.

IPv4 reachability is the **OR** of ICMP and HTTPS, not ICMP alone. Managed
networks routinely drop ICMP echo while passing TCP and UDP freely, so a failed
ping is not evidence of a missing Internet path. The report distinguishes
"AVAILABLE (ICMP + HTTPS)" from "AVAILABLE (HTTPS; ICMP echo filtered)", and
the filtered case raises an `ICMP_FILTERED` finding — both because ping-based
troubleshooting will mislead you there, and because it is one signal that the
network is centrally administered.

### 7. Public addressing, NAT depth, CGNAT
The most important section. Three independent signals:

1. **Observed public IPv4** — what an external echo service sees. If it is
   itself inside `100.64.0.0/10`, or any reserved range, it cannot accept
   inbound traffic. Definitionally conclusive.
2. **Traceroute hop analysis** — counts consecutive private hops at the edge
   before the first globally routable hop. A CGNAT hop in `100.64.0.0/10` is
   conclusive; two or more private hops suggests double NAT.
3. **Router WAN address via UPnP** (`bin/upnp-wan-ip.py`) — asks your router
   what address it believes it holds. If the router says `100.64.3.7` and the
   Internet sees `203.0.113.9`, a carrier NAT sits above you and no
   port-forward can help.

`CONFIRMED` requires either a definitionally conclusive signal or two agreeing
ones. `LIKELY` is a single suggestive signal. The evidence string is always
printed, so you can check the reasoning rather than trust the label.

The report also states a **NAT type**, because "several private hops" and
"carrier-grade NAT" are not the same finding:

| Type | Meaning |
|---|---|
| `none` | This machine holds the public address. |
| `single` | One NAT, at your router. Port forwarding works. |
| `multi-layer-private` | More than one NAT, but the observed public address is routable and no `100.64.0.0/10` hop appeared. Enterprise, campus, or double-router. |
| `cgnat` | Carrier-grade NAT. |

Both of the last two block inbound connections, but the remedies differ
entirely — a double-router setup you own is fixable, and sending someone to
their ISP over a campus network wastes everyone's time.

Many routers ship with UPnP disabled. "No answer" is normal and benign, not a
failure.

### 8. IPv6
Classifies every address on the primary interface (link-local / ULA / global),
checks for a default v6 route, tests v6 Internet reachability, and — the
decisive test — checks whether **the Mac's own global address is the address
the Internet sees**. If they match, there is no NAT66 and inbound is possible
subject only to the router's firewall.

Verdict: `candidate`, `partial`, or `unusable`. The tool will not advertise
`::/0` to clients on the strength of `partial`.

### 9. Firewall and forwarding
Application Firewall state, stealth mode, block-all; `net.inet.ip.forwarding`
and `net.inet6.ip6.forwarding`; and with `--with-sudo`, the pf status, rule
counts and anchor list.

Existing NAT rules are flagged: something else already owns NAT on this
machine, and this project must add to it in its own anchor rather than flush
it.

### 10. Power and availability
`pmset -g custom` for AC and battery sleep timers, Power Nap, wake-on-network,
`disablesleep`, and current sleep-prevention assertions.

A sleeping Mac is an offline VPN. The tool reports the setting and explains the
trade-off. It does not change it.

### 11. VPN subnet selection
Collects every IPv4 network on the machine, then tests candidate VPN subnets
for overlap against those **and** against the private ranges a roaming client
is most likely to land on (`192.168.0.0/24`, `192.168.1.0/24`, Docker's
`172.17.0.0/16`, and similar).

This second check matters: a full-tunnel client sitting on a café network that
uses the same range as your VPN will have broken routing. Also suggests a
random RFC 4193 ULA `/64` for the tunnel's IPv6 side.

### 11b. Network ownership
Weighs five signals to decide whether this is a network you administer: LAN
prefix shorter than `/24`, a DHCP-supplied search domain that is not a
home-style suffix, DNS that is neither the gateway nor on the local subnet,
ICMP filtered while HTTPS passes, and two or more layers of private routing.

Two or more signals classifies the run **managed / institutional** and forces
RED. One signal is not enough — a home behind two routers trips exactly one,
and a false accusation here is worse than a missed detection.

This check exists because an early audit came back from a Department of
Education network and the tool reported YELLOW, cheerfully recommending a VPN
subnet for a router the user has no authority over. Every measurement in that
report was individually correct and the conclusion was still useless.

### 12. Verdict

| | Meaning |
|---|---|
| **GREEN** | Directly reachable and suitable. |
| **YELLOW** | Possible with router configuration or a stated caveat. |
| **RED** | Direct inbound connectivity is unavailable. |
| **UNKNOWN** | `--offline`, or insufficient evidence. |

**`vpn-doctor` never returns GREEN.** A host cannot prove that an inbound UDP
packet from the Internet would reach it by testing from inside the network that
packet must cross. GREEN is reserved for Phase 3, after a real handshake from a
client on cellular data. A self-test that awarded itself GREEN would be exactly
the kind of false confidence this project exists to avoid.

### 13. Findings
Severity-tagged, each with a code, a description, and a concrete next action.

| Level | Meaning |
|---|---|
| `BLOCK` | Prevents the project proceeding as designed. Exit code 1. |
| `WARN` | Works, but with a real caveat you should decide about. |
| `INFO` | Worth knowing; no action forced. |

---

## After running it

Capture the result for Phase 2:

```sh
bin/vpn-doctor --with-sudo --save
```

Then share the **verdict, the CGNAT section, the IPv6 section and the findings
list**. Those four determine the architecture. The saved JSON contains your
public IP, LAN addressing and MAC addresses — it is gitignored and mode 600.
Redact before posting anywhere public.

## Privacy note on the report

The JSON contains: public IPv4/IPv6, LAN subnet and address, gateway, DNS
resolvers, search domains, traceroute hops, interface list, and hardware
identifiers. None of it is cryptographically secret. All of it is identifying.
Treat it accordingly.
