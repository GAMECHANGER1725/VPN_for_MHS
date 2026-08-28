# "I want this VPN on every network"

That's one sentence covering two independent problems. They have different
answers, and conflating them is how people end up with a VPN that mysteriously
works in some places and not others.

```
   ┌──────────────────────┐                    ┌──────────────────────┐
   │  CLIENT SIDE         │                    │  SERVER SIDE         │
   │  where your phone    │ ──── UDP ────────▶ │  where the Mac is    │
   │  or laptop is        │                    │                      │
   │                      │                    │                      │
   │  Q: can a UDP packet │                    │  Q: is the Mac at    │
   │     get OUT of here? │                    │     home, awake, and │
   │                      │                    │     reachable?       │
   └──────────────────────┘                    └──────────────────────┘
     vpn-doctor --client-check                    vpn-doctor
     run it on every network                      run it at home
```

---

## Server side: the Mac has to stay home

This is the part that isn't negotiable, and it's worth being blunt about
because it's the constraint people most want to wish away.

A VPN server is reachable because clients know a fixed address to send packets
to. That address is your **home** public IP plus a port your **home** router
forwards. Both of those belong to the house, not to the laptop.

So when the Mac leaves home:

- Its LAN address changes, so the port-forward at home now points at nothing.
- Its public IP becomes whatever network it's on.
- If that network is one you don't administer — school, a café, a friend's
  place — you cannot create a port-forward there at all.

**A laptop cannot be both a roaming client and a reachable server.** Not with
WireGuard, not with anything else, without a fixed rendezvous point somewhere
that both sides can reach. That rendezvous point is a machine that stays put
and has a real address, which is exactly the VPS this project rules out.

If you need the server to move with you, the only zero-cost answer is a
third-party overlay (see [limitations.md](limitations.md) §3), and that is a
different architecture with a different trust model — not this one with a
setting flipped.

**Practical consequence:** the Mac lives at home, on AC, awake. Your phone and
your other laptop are the things that roam.

---

## Client side: which networks let WireGuard out

This is where "every network" mostly lives, and here the news is better —
with one hard exception.

WireGuard is **UDP only**. There is no TCP mode. So a client works on a given
network if and only if that network lets arbitrary outbound UDP through and
lets the replies back.

Test any network in about five seconds:

```sh
bin/vpn-doctor --client-check
```

It sends one STUN binding request and watches for the reply. A completed round
trip proves UDP left and came back on a non-DNS port, which is what WireGuard
needs. It reports `LIKELY WORKS`, `WILL NOT WORK`, or `UNKNOWN`, and it needs
no sudo.

### What to expect, by network type

| Network | Outbound UDP | WireGuard client |
|---|---|---|
| Home broadband | Open | Works |
| Mobile data / tethering | Open | Works, and usually the most reliable option |
| Most hotels, cafés, airports | Usually open | Usually works |
| Corporate networks | Often restricted | Varies; often blocked |
| **School / university networks** | **Commonly UDP-filtered** | **Often blocked** |
| Captive portals, pre-login | Blocked until you authenticate | Log in first, then connect |

### When a network blocks UDP

Then WireGuard cannot connect from there. Not "is slow", not "needs the right
port" — cannot. This is a property of that network, and no server-side
configuration changes it.

Three things people try, and what they're actually worth:

1. **A different UDP port.** Genuinely worth trying. Some networks allow UDP
   broadly but block a handful of well-known ports. Costs nothing to test.
   This project keeps the port configurable for exactly this reason. It is
   *not* a security measure, and it does nothing on a network that blocks UDP
   wholesale.

2. **Tunnelling WireGuard over TCP/443** (wstunnel). This project builds this
   as an opt-in cloak — see [obfuscation.md](obfuscation.md). It wraps
   WireGuard's UDP in a TLS connection on port 443 so it passes networks that
   block UDP, while WireGuard stays the security boundary. Two honest costs:
   real performance loss (TCP carrying a tunnel retransmits at two layers and
   degrades under loss), and that on a network which deliberately blocks UDP
   this is getting past an administrator's policy — the AUP consequences are
   yours, and they land on your account rather than on the code.

3. **A third-party overlay.** Tailscale and ZeroTier relay over TCP/443 when
   UDP fails, which traverses nearly everything. That's option B in
   [limitations.md](limitations.md) §3: sound cryptography, genuinely free at
   your scale, and dependent on someone else's coordination servers. A real
   option — just not the same thing as the VPN you asked me to build.

---

## Managed networks specifically

Your first audit ran on one: search domain `detnsw.win`, a `/19` LAN, DNS on a
dedicated server, ICMP filtered while HTTPS passed. That's a Department of
Education network.

Two things follow, and they're separate:

**Technical.** Every number in an audit describes the network it ran on. A
report taken at school says nothing about whether your home connection can
host a VPN server. `vpn-doctor` now detects this and refuses to give a home
verdict from a school network, because designing against the wrong numbers is
worse than having none.

**Policy.** Using a VPN on a network you don't administer is usually covered
by that organisation's acceptable use policy, and school networks in
particular tend to be explicit about it. That's your call to make, not mine —
but it's a real risk with real consequences (device restrictions, account
action) and it's worth knowing you're making it rather than discovering it
afterwards. If the Mac itself turns out to be school-managed, `vpn-doctor`
flags that too, and it's a stronger reason to use a machine you own outright.

I'll keep building the VPN either way. I'm not going to build filter-evasion
tooling into it — that's a different project with different risks, and it
isn't what you asked for.

---

## The realistic answer

With this architecture, you get:

- **Home:** works.
- **Mobile data:** works. This is your most reliable remote path.
- **Most public Wi-Fi:** works.
- **Restrictive managed networks:** often not, and that's a property of those
  networks rather than a defect in your setup.

With the TCP/443 cloak ([obfuscation.md](obfuscation.md)) added, the
"restrictive managed networks" row moves much closer to working — the cloak is
built precisely so UDP-blocking networks stop being a wall. The remaining hard
limit is not the client network any more; it is whether your **home** has a
reachable address at all. A cloak gets packets out of school; it cannot
manufacture an inbound path at home if your ISP uses CGNAT. That is the one
question the home audit still has to answer.
