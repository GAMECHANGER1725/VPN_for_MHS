# Session state

Live working state, kept current so any new session can resume without
re-deriving. Update this file as work lands — it is the handoff mechanism.

**Last updated:** 2026-08-30, end of the cloud session that produced
`docs/stealth-roadmap.md`.

---

## Where things actually stand

**Working:** VLESS+Reality on `137.23.22.149:443`, `dest`/`sni` =
`itunes.apple.com`. Verified carrying real traffic (exit IP confirmed as the
VM). Client is Hiddify on macOS in **"Proxy service only"** mode, SOCKS on
`127.0.0.1:12334`.

**Broken:** Hiddify's **VPN / TUN mode**. The macOS system extension never
registers — `systemextensionsctl list` reports 0 extensions, nothing appears
under System Settings → Network → VPN or Login Items & Extensions, and no
approval prompt is ever offered. Error surfaced by the app is "failed to start
background core".

**Consequence of that break:** the system-wide SOCKS proxy on the Wi-Fi service
is the workaround, which causes the **"no internet when disconnected"** bug —
the proxy setting points at `127.0.0.1:12334`, which stops listening when
Hiddify disconnects, so every proxy-respecting app loses all internet rather
than falling back to direct. The user chose to fix TUN mode properly rather
than toggle the proxy manually.

---

## Immediate next actions

Full pathway is in [stealth-roadmap.md](stealth-roadmap.md). The front of the
queue:

1. **Exposure audit** — `nmap` the VM from off-network, TCP full range plus
   VPN-shaped UDP. Reality's premise is "this IP is a web server"; WireGuard on
   51820 and SSH on 22 both contradict it. Highest value, lowest cost item.
2. **Lock down WireGuard and SSH** to known sources, or retire WireGuard.
3. **macOS TUN diagnosis** — three checks, none yet run:
   - `codesign -dv --verbose=4 /Applications/Hiddify.app`, and the same on its
     packet-tunnel `.appex` (`find /Applications/Hiddify.app -iname "*.appex"`).
     Looking for a real `Developer ID Application` authority vs ad-hoc.
   - Console.app streaming on `subsystem:com.apple.system-extension` while
     switching Hiddify to VPN mode and connecting.
   - Notification Center, for a dismissed "System Extension Blocked" banner.
4. **Verify the Reality handshake** from off-network with `openssl s_client`
   against correct SNI, wrong SNI, and no SNI. All three should behave like the
   real destination.
5. **Tier 1** — resolve the SNI↔ASN mismatch (`itunes.apple.com` claimed from
   an Oracle Cloud IP). See roadmap §3 for the three architectural options.

---

## Loose ends from earlier sessions

- `loglevel` on the server may still be `debug` from handshake debugging.
  Revert to `warning` and restart Xray. Not confirmed done.
- `vpn-add-friend` script was written and handed over but **not confirmed
  installed** at `/usr/local/bin/vpn-add-friend`. Uses Python's json module to
  append a client UUID, restarts Xray, prints link + QR.
- No `vpn-remove-friend` exists. Discussed, never built.
- Temporary `~/serve` Python file server and its iptables rule on **8081** from
  the clipboard-corruption debugging may still be present. Should be removed —
  it is also an exposure-audit finding.
- `.claude/settings.json` permission allowlist: drafted in conversation, must
  be created by the user (an agent is not permitted to author its own
  permission grants).

---

## Decisions awaiting the owner

Do not resolve these autonomously.

1. **Third party in the data path — yes or no?** CDN fronting is the strongest
   answer to the real threat model and breaks the project's founding
   self-hosted principle. See roadmap §3 Option C.
2. **Keep WireGuard?** It costs the "just a web server" story on the only IP,
   and Reality covers every network it covers.
3. **Reconcile `limitations.md` §9** with what was actually built.

---

## The measurement that outranks everything

Nothing in this project has been tested on the school network. Whether the
filter does TLS interception, proxy-only egress, or ASN-category blocking is
**pure speculation** right now, and those are the three things most likely to
defeat the current design.

One session on that network answers all three. If a session is running on the
Mac while connected to that network, that test takes priority over every other
item here.
