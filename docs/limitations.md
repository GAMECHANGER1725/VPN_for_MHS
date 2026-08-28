# Limitations

Stated plainly, before any code is installed. Every item here is a real
constraint, not a caveat that better engineering will remove.

---

## 1. A MacBook Air is not a server

This is the largest limitation and no amount of software fixes it.

| Event | Effect on the VPN |
|---|---|
| Lid closed, no external display | Machine sleeps. **VPN down.** |
| Idle sleep timer elapses | Machine sleeps. **VPN down.** |
| You carry the Mac to work | Off the home LAN. **VPN down**, and the port-forward now points at nothing. |
| Wi-Fi drops / roams | Tunnel stalls until the interface returns. Clients re-handshake, typically within `PersistentKeepalive`. |
| Mac restarts | VPN down until the launchd job runs. Recoverable, and Phase 9's job. |
| Power loss | VPN down. Comes back with the Mac. |
| macOS major update | Reboots, may reset `/etc/pf.conf`. Recoverable by design — this project never writes to that file. |

The realistic zero-cost posture is: on AC power, lid open or clamshell with an
external display, idle sleep disabled, accepting that the tunnel dies whenever
the machine leaves the house.

**Costs of keeping it awake, which you should weigh before agreeing to it:**
sustained AC power keeps the battery at high state of charge, which accelerates
calendar ageing; a fanless M2 Air idles cool but will heat under sustained
tunnel load; and the machine draws power continuously. These are real and this
project will describe the exact `pmset` change and ask before making it.

`caffeinate` and `pmset` can suppress *idle* sleep. Lid-close sleep is a
separate setting (`disablesleep`). Neither survives the machine being picked up
and carried away.

---

## 2. Carrier-grade NAT cannot be port-forwarded around

If your ISP places you behind CGNAT, your router's WAN interface holds an
address in `100.64.0.0/10` (RFC 6598) rather than a public one. Many subscribers
share one real public address at the carrier's NAT.

A port-forward on your own router maps `<router WAN>:port` to
`<Mac LAN IP>:port`. If the router's WAN address is itself private, **nothing
on the Internet can address it**. The forward is created successfully and is
completely inert. This is the single most common false promise in home-VPN
tutorials.

`vpn-doctor` tests for this three independent ways: whether the address the
Internet observes is itself in `100.64.0.0/10`, whether `traceroute` crosses a
CGNAT hop, and whether the router's own reported WAN address (via UPnP)
differs from the address the Internet sees. Two agreeing signals, or one
definitionally conclusive one, produce `CONFIRMED`.

**If CGNAT is confirmed, the honest options are:**

1. **Ask your ISP for a public IPv4 address.** Often free on request,
   sometimes a paid static-IP add-on. Free-on-request satisfies the zero-cost
   constraint; a paid add-on does not.
2. **Use IPv6, if you have a routable one.** CGNAT is an IPv4 scarcity
   workaround; the IPv6 path is frequently unencumbered. Two conditions must
   both hold: your router must permit inbound UDP to the Mac's global address,
   and *the client must also have IPv6 at connect time*. Many mobile carriers
   do; most hotel and café networks do not. An IPv6-only endpoint is a partial
   solution, not a general one.
3. **Accept LAN-only use.** The VPN still works perfectly for devices on your
   own network. Useless for remote access, which is probably the point.
4. **Use an external rendezvous host.** This is where honesty matters most —
   see below.

---

## 3. Networks you do not administer

This project assumes you control the router. On a corporate, campus, school or
other institutional network you do not, and that changes the problem from an
engineering one into a permissions one.

Concretely, on a managed network:

- **You cannot create a port forward.** Inbound reachability is not yours to
  arrange, and no amount of correct WireGuard configuration substitutes.
- **The address you are given is not stable or yours.** Institutional DHCP
  pools, VLAN reassignment and captive re-auth all move it.
- **Egress is filtered by policy.** UDP on an arbitrary port may simply not
  leave the network, and that is a deliberate configuration rather than a
  fault.
- **Acceptable-use policies apply.** Networks like this are administered under
  a policy that generally covers running network services and tunnelling
  traffic across the network boundary. A tunnel built to move traffic past
  those controls is normally a breach of it regardless of how well it is
  engineered, and the consequences fall on the account holder rather than on
  the software.

`vpn-doctor` classifies this case and returns RED. If you have a legitimate
need to reach services on such a network from outside, the route is the
organisation's IT function — they usually already run a supported remote-access
method, and asking is both faster and safer than building around them.

None of this applies to your own home network, which is what the rest of this
project is about.

## 4. What "zero-cost" excludes, and the line this project draws

There is a genuine architectural distinction the project will always make
explicit:

**A — Genuinely self-hosted.** WireGuard on your Mac, reachable directly. No
third party is involved in the data path or the control plane. If every company
in the world disappeared tomorrow, this keeps working. **This is the target.**

**B — Overlay dependent on third-party coordination.** Systems like Tailscale
and ZeroTier solve CGNAT by running coordination servers that broker NAT
traversal, and relays that carry traffic when direct traversal fails. Their
free tiers are genuinely free at your scale, and they use sound cryptography
(Tailscale is WireGuard underneath).

They are not the same thing, and the difference is not about money:

- A third party operates the control plane and holds your device identity.
- Free tiers are commercial decisions and can change.
- When direct traversal fails, traffic transits their relays. Still
  end-to-end encrypted, but the path is theirs.
- It is no longer *your* VPN in the sense this project means.

If Phase 1 returns RED, this project will present option B as a working
alternative with that trade-off stated, and will never quietly substitute it
for option A. You will always know which one you are running.

---

## 5. Dynamic public IP, with no paid DDNS

Residential IPs change — at reconnect, at ISP maintenance, sometimes on a
timer. When yours changes, existing client configs point at the wrong address.
WireGuard clients do not rediscover an endpoint on their own.

What is achievable at zero cost and no external infrastructure:

- Detect the current public IP.
- Store the last known value and detect the change.
- Log it, alert locally, and update generated client configs.

What is **not** achievable without something outside your house: pushing the
new address to a client that is currently away. A name has to resolve
somewhere, and that somewhere is a server you do not own. Free options exist
(dynamic DNS free tiers, a DNS provider's API, a git repo holding a text file)
but all are third-party dependencies, and this project will label them as such
rather than folding them into "self-hosted".

There is no self-contained solution to this. Anyone who tells you otherwise is
hiding a dependency.

---

## 6. macOS-specific constraints

- **No kernel WireGuard.** macOS runs `wireguard-go` in userspace on a `utun`
  interface. Correct and supported, but slower and more CPU-hungry than a
  Linux kernel implementation. Phase 3 will benchmark it rather than quote
  numbers.
- **Interface naming.** `wg-quick up wg0` produces `utunN`, not `wg0`. Status
  output must report the real interface or it is lying.
- **`/etc/pf.conf` is Apple's file.** OS updates overwrite it. This project
  loads rules into a dedicated anchor from its own file, so uninstall is a
  clean unload rather than a guess about which lines were ours.
- **Two independent firewalls.** The Application Firewall (`socketfilterfw`,
  the one in System Settings) and `pf` are separate. Both can block inbound
  WireGuard, and they must be reasoned about separately.
- **System Integrity Protection** constrains what can be changed. This project
  never asks you to disable it.
- **Full Disk Access / TCC** prompts may appear for launchd jobs depending on
  what they touch.

---

## 7. WireGuard is UDP-only, and the server cannot roam

Two client-side constraints that no server configuration changes.

**UDP only.** WireGuard has no TCP mode. A client can connect from a network if
and only if that network passes arbitrary outbound UDP and lets the replies
back. Networks that block UDP — commonly schools and universities, some
corporate networks, occasionally hotels — cannot carry a WireGuard client at
all. Trying a different UDP port is worth doing and costs nothing, because some
networks block specific well-known ports rather than UDP wholesale. It does
nothing where UDP is blocked outright.

Test any network before you rely on it:

```sh
bin/vpn-doctor --client-check
```

**The server cannot travel.** Clients reach a server because they know a fixed
address to send to, and that address belongs to your house — its public IP and
its port forward. A laptop cannot be both a roaming client and a reachable
server without a fixed rendezvous point that both ends can reach, which is
exactly the always-on host with a stable address this project rules out. The
Mac stays home; your phone and other devices are what move.

[networks.md](networks.md) covers what works where, and the honest options when
a network won't carry it.

## 8. What the diagnostic genuinely cannot determine

Recorded so no one mistakes silence for a pass:

- **Inbound reachability.** Not testable from inside the network the packet
  would have to enter. Requires a real client on an outside network.
- **Whether your router's port-forward will work** before you create it.
- **IPv6 prefix stability.** Requires observation over days, not one run.
- **Whether the ISP filters UDP** on your chosen port.
- **Whether your router's UPnP answer is truthful.** Some lie. It is treated
  as one signal among three.
- **Client-side IPv6 availability** on networks the client hasn't visited yet.

---

## 9. Non-goals, permanently

- Custom cryptography.
- A custom VPN protocol.
- Obscurity as a security measure. Changing the UDP port off 51820 reduces log
  noise from mass scanners. It is not a security control and will never be
  described as one.
- Tooling whose purpose is defeating a network filter. Trying an alternative
  UDP port is ordinary configuration and is supported. Wrapping the tunnel in
  TCP to get past a network that deliberately blocks UDP circumvents someone's
  policy rather than solving a technical problem, and is out of scope.
- Weakening security to make the setup work. If the secure path is blocked,
  this project reports BLOCKED rather than lowering the bar.
