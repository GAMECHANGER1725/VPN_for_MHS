# Making it work on UDP-blocking networks (the TCP/443 cloak)

**Decision of record:** self-hosted WireGuard with an optional TCP/443
obfuscation layer, so the tunnel passes networks that block UDP — school and
similar — while remaining fully yours, with no third party in the path.

This document is the design. The build lands in the implementation phases; it
depends on the home audit first (see the end).

---

## Why a cloak is needed at all

WireGuard is UDP-only. A network that drops outbound UDP — common on school and
some corporate networks — cannot carry it, whatever port you pick. `vpn-doctor
--client-check` measures exactly this.

The fix is to stop sending UDP on such networks. WireGuard's UDP is wrapped
inside an ordinary TCP connection on port 443, the HTTPS port. To the network's
firewall the traffic is indistinguishable from a normal HTTPS session, because
that is what it is at the transport layer. The WireGuard datagrams ride inside.

```
 normal path (home, mobile, open Wi-Fi):
   client ──── WireGuard/UDP :51820 ────────────────▶ Mac

 cloaked path (school, UDP blocked):
   client ─ WG/UDP ─▶ wstunnel client ─ TCP/TLS :443 ─▶ wstunnel server ─ WG/UDP ─▶ Mac
             (localhost)                (looks like HTTPS)          (localhost)
```

The client's WireGuard app still just speaks UDP to `127.0.0.1`; a local
`wstunnel` process picks that up and carries it over TCP/443 to a matching
process on the Mac, which hands it to WireGuard locally. WireGuard itself is
unchanged and unaware. **No cryptography is added or altered** — this is a
transport wrapper around the audited tunnel, nothing more.

---

## Two problems, and what the cloak does and does not solve

This is the part most guides get wrong, so it is stated plainly.

| Problem | Where | Cloak solves it? |
|---|---|---|
| **1. Client network blocks UDP** | at school, the café, etc. | **Yes.** TCP/443 escapes the filter. |
| **2. Server has no inbound path** | your home ISP | **No.** This is upstream of the client entirely. |

The cloak is a client-side escape hatch. It gets your packets *out* of a
restrictive network. It does nothing about whether they can *land* on your Mac,
which is decided by your home connection:

- If home has a reachable public IP (or usable IPv6), packets land. The cloak
  completes the picture and you have "works on school".
- If home is behind **CGNAT** with no usable IPv6, there is nowhere to land.
  The cloak still can't help, because the missing piece is a public address at
  home, not a way out of school. That case is BLOCKED for self-hosting, and the
  only zero-cost answer is a third-party overlay ([limitations.md](limitations.md) §4).

**This is why the home audit is the gate.** Until we know your home isn't
CGNAT, we don't know whether the self-hosted path can work on school at all.

---

## Chosen tool: wstunnel

`wstunnel` (BSD-licensed, actively maintained) carries UDP or TCP over
WebSocket/HTTPS. Chosen over the alternatives because:

- **It speaks real TLS on 443.** The session presents as HTTPS, which is what
  gets through restrictive networks — not a custom protocol a DPI box flags.
- **It is a plain userspace binary**, installable via Homebrew, no kernel
  extension, no SIP concerns.
- **It wraps; it does not re-encrypt the payload.** WireGuard's own encryption
  is untouched. wstunnel's TLS is an outer layer for camouflage and integrity
  on the wire, not a second security boundary we depend on.

Rejected for this project:

- **udp2raw** — fakes TCP/ICMP at the raw-socket level. Powerful, but needs
  root on the client and is fingerprintable; heavier than needed.
- **Rolling our own** — a non-goal, permanently. No custom transport.

---

## Server side (the Mac)

A second launchd service alongside WireGuard:

```
wstunnel server  ─ listens on TCP 443
                 ─ terminates TLS
                 ─ forwards decapsulated UDP to 127.0.0.1:<wg-port>
```

Requirements and honest costs:

- **Port 443 must be free and forwarded.** If anything on the Mac already
  serves 443, that conflict is surfaced before we touch it. The home router
  forwards TCP/443 to the Mac, exactly as it would forward the WireGuard UDP
  port — same CGNAT caveat applies.
- **A TLS certificate.** A self-signed cert is enough (WireGuard is the real
  security boundary; the TLS is camouflage), so no paid CA and no public
  hostname are required. This keeps it zero-cost.
- **CPU.** Every cloaked packet now crosses userspace twice on the Mac
  (wstunnel + wireguard-go) instead of once. On filtered networks only. Phase 3
  benchmarks the real cost on the M2 rather than guessing.

## Client side (per platform, because it differs)

- **iOS / Android:** the official WireGuard app has no plugin for this, so the
  phone runs WireGuard normally and a companion approach is needed. This is the
  genuinely awkward platform and its options (a second app, or falling back to
  mobile data which usually isn't filtered) get documented honestly rather than
  pretended away.
- **macOS / Linux client:** run `wstunnel` locally, point WireGuard at
  `127.0.0.1`. Clean.
- **Windows:** same pattern, `wstunnel.exe` as a background service.

The CLI generates **two profiles per peer**: a direct one (fast, for normal
networks) and a cloaked one (for UDP-blocked networks). You pick per network.
Auto-detection — try direct, fall back to cloak — is a later refinement, not a
first cut.

---

## Design principles this respects

- **WireGuard stays the security boundary.** The cloak is transport camouflage.
  If wstunnel's TLS were stripped tomorrow, your traffic is still WireGuard-
  encrypted end to end.
- **Off by default.** Direct WireGuard is the primary path. The cloak is opt-in
  per peer/network, because it is slower and only needed where UDP is blocked.
- **No custom crypto, no custom protocol.** wstunnel is an existing audited-ish
  tool doing a standard job; we integrate it, we don't reinvent it.
- **Honest about the ceiling.** The cloak defeats UDP blocking and simple DPI.
  A network doing full TLS fingerprinting or allowlisting destinations by SNI
  can still stop it, and this project will say so rather than promise
  invisibility.

---

## Status and the one dependency

- Approach: **decided** (self-hosted + TCP/443 cloak).
- Tooling: **chosen** (wstunnel).
- Build: **pending the implementation phases**, and gated on one thing —

  **a valid audit of your home network.** Run at home:

  ```sh
  bin/vpn-doctor --with-sudo --save
  ```

  If it comes back clear of CGNAT (or with usable IPv6), the self-hosted cloak
  is buildable and "works on school" is achievable. If it comes back CGNAT with
  no IPv6, we have an honest decision to make about the overlay before writing
  another line, because no cloak fixes a missing address at home.
