# VPN for MHS — Full Project History

A complete record of the project: decisions, pivots, what was built, what broke, and how it was fixed. Written for import into a personal knowledge base / second brain, so treat every section as standalone context.

Repo: `github.com/GAMECHANGER1725/VPN_for_MHS` (branch `claude/oracle-cloud-setup-rjrps3`)

---

## 1. Origin and goal

Started as a zero-cost, fully self-hosted VPN — "self-hosted" meaning no third party (no Tailscale, no ZeroTier) sits in the control plane or the data path. Two non-negotiable design principles held throughout the whole project:

- **No custom cryptography, no custom protocol.** Always use an audited, existing implementation (WireGuard, then later Xray/VLESS+Reality) and build tooling *around* it — key lifecycle, config, firewall, diagnostics — never touch the crypto itself.
- **Honesty over convenience.** Every doc in this repo states plainly what does and doesn't work, rather than promising something that quietly degrades (e.g. refusing to report "GREEN/reachable" from a self-test, since that can't actually prove inbound reachability).

---

## 2. Phase 1 — original design: MacBook Air as the server

The first design ran the WireGuard server **on a MacBook Air M2** at home, on the theory that "zero-cost" meant no cloud component at all.

**Why this was abandoned:**
- A laptop is not a server: lid-close sleep, idle sleep, being carried out of the house, Wi-Fi roaming, and macOS updates resetting `/etc/pf.conf` all take the VPN down.
- The realistic uptime posture required disabling idle sleep and staying on AC power constantly — real costs (battery calendar aging, sustained heat, continuous power draw) for a fanless M2.
- **Carrier-grade NAT (CGNAT)** was the other gating risk: if the home ISP's router WAN address sits in `100.64.0.0/10` (RFC 6598), no port-forward from that router can ever be reached from the Internet — the address is fundamentally private. This is the single most common false promise in home-VPN tutorials. A tool (`bin/vpn-doctor`) was built specifically to test for this via three independent signals (own observed public IP inside `100.64.0.0/10`, a traceroute hop through CGNAT-typical private space, and a UPnP-reported router WAN address that disagrees with the observed one).
- A `vpn-doctor` audit also had to determine whether the network was even one the user administers (home vs. institutional/managed) — because on a managed network, port-forwarding isn't yours to arrange and tunneling across the boundary is usually a policy violation regardless of engineering quality.

**Decision:** pivot the server to a small, always-on cloud VM with a real public IP, eliminating the CGNAT and laptop-uptime problems entirely. `vpn-doctor` was kept as a genuinely useful **client-side** tool — "can a WireGuard client work from the network I'm standing on right now" (schools, cafés, hotels that block outbound UDP) — a different, still-relevant question from where the server lives.

---

## 3. Phase 2–4 — Oracle Cloud VM + WireGuard (the original working VPN)

**Server:** a free-tier "Always Free" Oracle Cloud Ubuntu VM with a reserved public IPv4 (`137.23.22.149`). This VM's own uplink became the VPN's Internet connection — full-tunnel traffic exits at Oracle's speed, from Oracle's IP, not the home IP.

**Architecture:**
```
Client → WireGuard (ChaCha20-Poly1305, Curve25519, BLAKE2s), UDP :51820
       → Internet
       → Oracle Security List ingress rule (UDP/51820)
       → Oracle Cloud VM: wireguard kernel module on wg0
       → iptables NAT (MASQUERADE) + FORWARD rules
       → net.ipv4.ip_forward = 1
       → Oracle uplink → rest of Internet
```

**Real bugs hit and fixed during this build:**

1. **`FORWARD` chain catch-all REJECT.** Oracle's default Ubuntu image ships an `INPUT` chain with a catch-all `REJECT` (needing an explicit SSH allow rule above it) — and the **same pattern exists on `FORWARD`**, which is easy to miss because it only breaks routed traffic, not the tunnel itself. Symptom: the WireGuard handshake succeeds, the tunnel's own address (`10.77.0.1`) is pingable, but nothing beyond it works — `1.1.1.1` comes back "ICMP administratively prohibited" from the server itself. Fixed by inserting two rules above the `FORWARD` REJECT line:
   ```
   iptables -I FORWARD 1 -i wg0 -j ACCEPT
   iptables -I FORWARD 2 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
   ```
   then `netfilter-persistent save`. **Lesson that recurred later:** Oracle's stock image has *two separate* iptables chains with this catch-all-reject pattern (`INPUT` and `FORWARD`), and fixing one never implies the other is fixed.

2. **`wg-quick`'s full-tunnel mode on macOS** replaces the client's entire default route (two `/1` routes) and rewrites DNS on **every** network service on the machine, not just the active one — worth testing a new server with a restricted `AllowedIPs` (just the tunnel address, then one external IP) before ever trying `0.0.0.0/0`, so a forwarding bug can't strand the client with no route anywhere.

3. **`wg syncconf` process-substitution bug** when hot-adding a peer without dropping existing connections: `sudo wg syncconf wg0 <(wg-quick strip wg0)` fails with `fopen: No such file or directory`, because the `<(...)` substitution runs as the invoking user while `wg-quick strip` needs root to read the 600-permission config — so `sudo` sees nothing. Fixed by routing through a real temp file:
   ```
   sudo wg-quick strip wg0 > /tmp/wg0.stripped
   sudo wg syncconf wg0 /tmp/wg0.stripped
   rm /tmp/wg0.stripped
   ```
   `wg syncconf` (unlike `wg-quick down`+`up`) never tears down the interface, so already-connected peers keep their session.

4. **`PermissionError` reading `/var/run/wireguard/<name>.name`** from the local dashboard: `wg-quick` creates that file as root, so an unprivileged process's `os.path.exists()` succeeds (only needs directory search permission) but `open()` raises `PermissionError` (needs the file's own read bit). Fixed via a narrowly-scoped passwordless-`sudo` grant for the exact commands needed, added in a dedicated `/etc/sudoers.d/` file (never edit `/etc/sudoers` directly), validated with `visudo -c`.

5. **IP-lookup fallback not triggering on HTTP 429** in the local dashboard's public-IP display — fixed to actually fall back to a second provider (`ipwho.is` / `ipapi.co`) on rate-limit responses, not just outright failures.

**Multi-client peer support confirmed working:** a MacBook and an Android phone connected simultaneously as independent WireGuard peers, added by hand over SSH (`bin/vpn peer add` automation was never built — Phase 6, tracked as future work). The manual runbook that was documented and tested:
1. Generate keypair + preshared key **on the client device itself** (private key must never leave the device it belongs to).
2. Pick the next free address in `10.77.0.0/24` (server is `.1`).
3. Append the `[Peer]` block to the server's `/etc/wireguard/wg0.conf` with only the public key + preshared key.
4. Hot-reload via the `wg syncconf` + temp-file trick above.
5. Build the client's own `[Interface]`/`[Peer]` config referencing the server's public key and reserved IP.
6. Deliver to the device: `qrencode -t ansiutf8 < client.conf` for a phone (camera-scannable straight from the terminal), plain file copy for a second computer.
7. Verify with `sudo wg show wg0` — a real `endpoint` and recent `latest handshake` only appear after the client actually connects.

**Design decisions locked in for this phase (see `docs/architecture.md`):**
- VPN subnet `10.77.0.0/24`, chosen from a conflict scan against likely client networks, not hard-coded.
- DNS: a local forwarder (`dnsmasq`/`unbound`) bound to the tunnel address only, forwarding to a public resolver — never deferring to whatever a home router handed out, since a cloud VM has no such router to defer to. (Documented as "not started" — clients get `1.1.1.1` directly for now.)
- IPv6 inside the tunnel: advertised only once the VM's own IPv6 path is confirmed working end-to-end — never assumed just because the VM has a public IPv4, since a broken advertised `::/0` blackholes traffic (worse than no IPv6).

**Local dashboard (`bin/vpn-connect-ui.py` + `.html`):** a one-click Connect/Disconnect web page for the macOS client, replacing typing `sudo wg-quick up/down` by hand. Binds `127.0.0.1` only — never a public interface — specifically because a public webpage cannot flip a device's own VPN on itself; this only works because the page and the command-runner are the same machine. Explicitly **not** part of any friend-facing sharing mechanism.

**Later in the project this dashboard was redesigned** from a dark "hacker terminal" / matrix-rain aesthetic to a calm, light, professional look — the stated reason: friends connecting as peers were seeing the dashboard and it looked like something that would steal their data, undermining trust even though the tool does nothing untoward. All JS function names, element IDs, and the `IP_PROVIDERS` fallback array were preserved so the existing Python backend kept working unchanged. Committed as "Redesign the dashboard as a calm, trustworthy VPN UI."

**Non-goals stated permanently in `docs/limitations.md`:** no custom cryptography, no custom protocol, obscurity never treated as a security control, no tooling built specifically to defeat a network filter (an alternate UDP port is fine as ordinary config; wrapping the tunnel in TCP specifically to beat a UDP-blocking policy was ruled out **at that time** — see Section 6 below for why this line moved).

Roadmap snapshot at this point: Phases 1–4 done, DNS (5) not started, TCP/443 cloak (5b) designed but not built, peer management (6) manual-only, CLI (7) / monitoring (8) / automation (9) / hardening (10) not started, testing (11) primitives-only, docs (12) in progress. 126 test assertions across five suites (`test-stun.py`, `test-primitives.sh`, `test-cgnat.sh`, `test-ownership.sh`, `test-report.sh`) plus syntax/shellcheck, all pure and network-independent so they run anywhere even though `vpn-doctor` itself is macOS-only.

---

## 4. The pivot: from "defeat UDP-blocking" to "defeat active DPI" (stealth VPN)

The original obfuscation design (`docs/obfuscation.md`, decided but never built) was a `wstunnel`-based TCP/443 cloak: wrap WireGuard's UDP inside a real TLS session on port 443 so a network that blocks outbound UDP (school, some corporate Wi-Fi) can't tell the difference from ordinary HTTPS. Explicitly scoped as **transport camouflage only** — WireGuard stayed the sole security boundary, and the doc was explicit that this defeats UDP-blocking and simple DPI but **not** a network doing full TLS fingerprinting or destination allowlisting by SNI. That build was gated on a home-network CGNAT audit that became moot once the server moved to Oracle Cloud (a real public IP made the gate irrelevant).

**The actual pivot happened here, mid-project:** the user explicitly said "I don't want to use WireGuard" and, after clarification, that the real goal was **a stealth and obfuscated VPN** — one that can defeat active DPI probing, port blocking, protocol fingerprinting, and traffic analysis, not just simple UDP filtering. This is a materially different threat model than anything the WireGuard+cloak design targeted.

**Options compared against that exact threat list:** wstunnel, AmneziaWG, and Shadowsocks/V2Ray+Reality. **Decision: VLESS + Reality**, explicitly authorized by the user ("Please go ahead with the Reality-Based Setup... My goal is just to create a very powerful and excellent Stealth VPN"), to run **alongside** the existing WireGuard setup on the same Oracle server — not replacing it. WireGuard stays the "direct/fast" path on UDP/51820, untouched; VLESS+Reality becomes the "stealth" path on TCP/443.

### Why VLESS + Reality
- **Reality** borrows the live TLS handshake of a real, existing website (the "disguise target") — no fake/self-signed certificate needed, and active DPI probing (a censor connecting to the server itself to check if it's really the website it claims to be) sees a completely genuine handshake from that real site, because Reality actually proxies to it for anyone who doesn't hold the right key.
- Runs on **Xray-core** (`XTLS/Xray-core`), installed via the official install script (`XTLS/Xray-install`).

---

## 5. Building the Reality server (what was actually done)

1. **Install Xray-core** via the official script — first attempt failed with `bash: /usr/local/bin/xray: No such file or directory` because an earlier SSH tab had been closed mid-install; second attempt failed with `error: You must run this script as root!` until `sudo` was added.
2. **Generate the x25519 keypair**: `xray x25519` → `PrivateKey`, `PublicKey`, `Hash32`. The private key stays server-side only; the public key (`pbk`) goes into every client link.
3. **Write `/usr/local/etc/xray/config.json`** — final working shape:
   ```json
   {
     "log": { "loglevel": "warning" },
     "inbounds": [{
       "listen": "0.0.0.0", "port": 443, "protocol": "vless",
       "settings": {
         "clients": [{ "id": "<uuid>" }],
         "decryption": "none"
       },
       "streamSettings": {
         "network": "tcp", "security": "reality",
         "realitySettings": {
           "show": false,
           "dest": "itunes.apple.com:443",
           "xver": 0,
           "serverNames": ["itunes.apple.com"],
           "privateKey": "<server private key>",
           "shortIds": ["<short id>"]
         }
       }
     }],
     "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
   }
   ```
   Note: **no `"flow": "xtls-rprx-vision"`** in the final working config — see the flow-removal debugging step below.
4. **Client link format:**
   ```
   vless://<uuid>@137.23.22.149:443?security=reality&encryption=none&pbk=<public key>&fp=chrome&sni=itunes.apple.com&sid=<short id>&type=tcp#MHS-Stealth
   ```
5. **Firewall, two independent layers, both had to be opened separately** (a recurring theme — see Section 8): Oracle Security List ingress (cloud-level) and the VM's own local `iptables` INPUT chain (OS-level). TCP/443 for Xray, plus later TCP/8081 temporarily for a debugging file server.
6. Service managed via `systemd` (`xray.service`), confirmed clean startup via `journalctl -u xray`.

---

## 6. Debugging odyssey: why the Reality handshake kept failing

This was the longest, most iterative part of the project. Timeline of what was tried, in order, with what each step actually proved:

1. **Raw TCP reachability check** (`nc -zv -w5 137.23.22.149 443` from the Mac) — timed out. This turned out to be because **the Oracle Security List never had a TCP/443 ingress rule at all** (an earlier screenshot that seemed to confirm 443 was open had been misread, or was for something else). Fixed by adding it. This is a different bug from the `FORWARD`-chain issue in the WireGuard build, but the same *category* of bug: Oracle's two-layer firewall (cloud Security List + local iptables) needs both layers opened, every time, for every new port.

2. **After opening 443 in the Security List, `nc` connected but Hiddify still said "Timeout."** Turned the Xray log level up to `debug` (config had shipped at `warning`, which suppresses per-connection detail — and Reality is *designed* to log nothing on a non-matching handshake anyway, since silence is the whole anti-probing point). This surfaced the real signal:
   ```
   REALITY: processed invalid connection from <client ip>:<port>: handshake did not complete successfully
   ```
   repeated for every connection attempt, proving the client **was** reaching the server, but Xray was rejecting every handshake.

3. **Ruled out, in order, with concrete verification for each:**
   - **Wrong public key.** Recomputed the public key from the server's private key (`xray x25519 -i "<private key>"`) and diffed it byte-for-byte against the client's `pbk` — matched exactly.
   - **Clock skew.** Reality embeds a timestamp in the handshake and rejects anything outside a small tolerance window. `date -u` on both the Mac and the server were within 5 seconds of each other — not the cause.
   - **The `flow: xtls-rprx-vision` parameter.** Removed it from both the server config and the client link as a test, since Hiddify's underlying core (sing-box) has had known friction with Vision-flow implementations in some configurations. Did not fix it alone, but was kept removed in the final working config (a legitimate, if minor, simplification — no observed downside).
   - **The disguise target (`www.microsoft.com`) itself.** This was the actual root cause. `www.microsoft.com` is served via a large CDN (Azure Front Door), and REALITY handshakes against it failed **100% of the time**, consistent with reports elsewhere that some CDN edge nodes for large multi-tenant domains don't behave predictably enough for Reality's TLS-1.3/X25519 requirements. **Switching the `dest`/`serverNames` to `itunes.apple.com`** (a single-origin server, commonly recommended specifically for this reason) fixed it immediately — Hiddify connected on the very next attempt.

4. **Once connected, `curl -s https://api.ipify.org` still showed the real (non-VPN) IP**, even though Hiddify showed "Connected" with real traffic counters moving. Root cause: Hiddify's **Service mode** was set to *"Set system proxy"*, not *"VPN"* — system-proxy mode only routes apps that explicitly respect the OS proxy setting, and `curl` by default doesn't (browsers usually do). Switching Service mode to **VPN** (full TUN routing) then produced **"Unexpected failure — failed to start background core."**

5. **The VPN/TUN-mode failure was never fully resolved.** Diagnosis steps taken:
   - Confirmed via `lsof -i :50100` (empty) that Hiddify's local backend/core process wasn't binding to its port at all — this was actually a **separate, earlier bug** (see Section 7) from an entirely different root cause, but produced a similarly-worded failure.
   - Checked `systemextensionsctl list` → `0 extension(s)` — macOS never even registered a Network Extension request from Hiddify.
   - Checked System Settings → General → Login Items & Extensions → Network Extensions, and System Settings → Network → VPN directly — no Hiddify entry ever appeared in either, even after a full quit/reopen and re-attempting VPN mode.
   - **Conclusion:** this build of Hiddify's macOS packet-tunnel extension (`HiddifyPacketTunnel.appex`) likely isn't satisfying macOS's system-extension code-signing/approval requirements — a stricter check than the Gatekeeper "quarantine" flag that was successfully bypassed earlier (see Section 7). This is a different layer of macOS security than app-launch Gatekeeper, and removing the quarantine attribute does not touch it.
   - **Workaround adopted instead of continuing to fight it:** stayed in **"Proxy service only"** mode, and manually configured the Mac's own SOCKS proxy in System Settings → Network → Wi-Fi → Details → Proxies (`127.0.0.1`, port `12334` — Hiddify's own "Mixed port" from Settings → Inbound). Verified working via `curl -s --socks5 127.0.0.1:12334 https://api.ipify.org` → returned `137.23.22.149` correctly. Browsers pick up this system proxy automatically; command-line tools need `--socks5 127.0.0.1:12334` explicitly, or `export ALL_PROXY=socks5://127.0.0.1:12334` for a whole terminal session.
   - This is a **functional limitation to remember**: full system-wide TUN routing on this Mac isn't currently working for Hiddify; the proxy-mode workaround is what's actually in production use. Traffic is still fully Reality-encrypted once it enters the proxy — this is a routing-mode limitation, not a security downgrade — but apps that ignore the system proxy setting (most command-line tools, some apps with hardcoded networking) won't be covered unless run with the proxy explicitly.

---

## 7. Client-app installation bugs (separate from the handshake debugging)

Before any of the Reality-handshake debugging in Section 6 could even start, getting Hiddify to launch at all on the Mac took several distinct fixes:

1. **"Failed to add profile — SocketException: Connection refused... 127.0.0.1:50100."** Diagnosed as Hiddify's own internal core/backend process failing to start entirely (confirmed via `lsof -i :50100` returning empty — nothing bound to that port).
2. **Root cause found via `file /Applications/Hiddify.app/Contents/MacOS/*`** → "no matches found," and the actual bundle structure showed `Hiddify.app/Wrapper/Runner.app` and a top-level `WrappedBundle` — the unmistakable layout of an **iOS app running unmodified via "iPhone & iPad Apps on Mac"** (Apple Silicon can run App Store iOS builds natively), **not** the native macOS build. This explained everything: no `Contents/MacOS/` at the top level, no system-extension registration possible, the internal sing-box core never starting.
3. **Fix:** deleted the iOS-wrapper install (`sudo rm -rf /Applications/Hiddify.app` — needed `sudo` because App Store installs are root-owned), and downloaded the genuine **native macOS build** (a `.dmg`) from the official `hiddify/hiddify-next` GitHub releases page instead.
4. **That native build then said "app is damaged and can't be opened"** — the standard Gatekeeper message for a downloaded-outside-the-App-Store app that isn't fully notarized (common for open-source GitHub releases), not actual corruption. Confirmed via `xattr -l` showing a `com.apple.quarantine` flag. Fixed with `sudo xattr -rd com.apple.quarantine /Applications/Hiddify.app`.
5. After that, the app launched and reached real config-parsing errors (Section 8/6) — i.e. progress, since a broken bundle can't even get that far.

---

## 8. The recurring "Comet auto-linkify" clipboard corruption saga

This consumed a large amount of debugging time and is worth recording as a pattern, since it's likely to recur in any future session using this same environment.

**Symptom:** any command or file content containing a domain-looking string (e.g. `www.microsoft.com`) would frequently display, when pasted back into the chat or even when copy-pasted between the user's own Terminal and other native macOS apps, as `[www.microsoft.com](https://www.microsoft.com...)` — Markdown link syntax literally injected into what should have been plain text. This repeatedly broke config files (`sed`-based edits), client link imports into Hiddify ("unable to determine config format," later "invalid url"), and even a Python `http.server`-served file.

**Root cause, established through direct testing (not assumption):**
- Verified multiple times via `grep -c '](' <file>` on the **actual server file** returning `0` — proving the underlying bytes were clean; the corruption was a **rendering/copy artifact**, not real file corruption, in most of these cases.
- The actual mechanism, confirmed by the user directly: **copying text out of the chat itself** (where the Comet browser had auto-rendered a plain-text domain as a clickable hyperlink) and pasting that into Terminal or into Hiddify's own native fields picks up the Markdown source of that rendered link, not the plain text — because that literally is what gets copied when you copy rendered link text out of a browser. This happened both when running commands copy-pasted from the assistant's messages, and when the user copied terminal output back into the chat to show the assistant (each such round-trip risked re-corrupting the system pasteboard for whatever was pasted next).
- A `ps aux | grep -i comet` check ruled out a separate background "clipboard watcher" utility — this was purely a consequence of copy/paste habits interacting with the browser's own link rendering, not a rogue app.

**Fixes used, in order of reliability (most reliable first):**
1. **Avoid the domain string appearing as literal text in any command sent through chat at all.** Build it server-side from parts via shell substitution so no dotted domain ever appears as a copyable unit in the message: `SNI=$(printf '%s.%s.%s' www microsoft com)`.
2. **base64 encode/decode as a transport** between server and Mac — `echo "$URI" | base64` on the server, then `echo '<blob>' | base64 -d | pbcopy` on the Mac. Immune to corruption because base64 text doesn't look like a URL and is decoded deterministically.
3. **Verify file content without ever displaying the domain text**, using `grep -c '](' <file>` and `wc -l <file>` (numbers only, nothing for the corruption to attach to) instead of `cat`.
4. **The most robust fix, eventually adopted for the actual client-link import:** stop using the clipboard at all. Served the link as a plain file from a temporary Python `http.server` on the Oracle box, and had Hiddify's "Manually add" URL field **fetch it directly over HTTP** (`http://137.23.22.149:8081/link.txt`) — since Hiddify's own HTTP client reads the bytes directly over the network, this never touches the Mac's clipboard or the chat at all. This is what finally got the corrected (`itunes.apple.com`) link imported cleanly.
5. **Screenshots instead of copy-pasted text** for verification once the pattern was understood — a screenshot can't carry the corruption since it's an image, not clipboard text.

**Secondary bug hit while building the file-server workaround:** the temporary `http.server` on 8081 got "Connection refused" from the Mac even after opening TCP/8081 in the Oracle Security List — because, exactly as in Section 3's `FORWARD`-chain bug, **the VM's own local iptables INPUT chain has a separate catch-all REJECT rule**, and 8081 had never been added to it (unlike 443, 22, and 51820, which had been explicitly allowed earlier). Fixed identically to the earlier pattern: `sudo iptables -I INPUT <line-before-reject> -p tcp --dport 8081 -j ACCEPT`.

**Also hit during this saga:** an SSH session silently died mid-command-block (visible only as "Read from remote host: Operation timed out" appearing *after* the next block of commands had already been typed), causing an entire multi-line command block — including `mkdir`, variable assignment, and starting the Python server — to silently execute on the **local Mac** instead of the intended remote server. This produced confusing downstream errors (`OSError: Address already in use` from a port conflict that only existed locally) until the mismatch was caught by checking which shell prompt (`ubuntu@vps-vnic` vs. the Mac's own prompt) was actually active before running anything.

---

## 9. Current working state (as of end of session)

**Server (`137.23.22.149`, Oracle Cloud "Always Free" Ubuntu VM):**
- **WireGuard**: running on UDP/51820, untouched, original "direct/fast" path. Multi-client (Mac + Android) previously confirmed working.
- **Xray/VLESS+Reality**: running as `xray.service` on TCP/443, disguised as `itunes.apple.com`. Config at `/usr/local/etc/xray/config.json`, log level should be reverted from `debug` back to `warning` for normal operation (was bumped for the debugging in Section 6):
  ```sh
  sudo sed -i 's/"loglevel": "debug"/"loglevel": "warning"/' /usr/local/etc/xray/config.json
  sudo systemctl restart xray
  ```
- **`/usr/local/bin/vpn-add-friend`**: a helper script (built at the end of this session) that generates a new UUID, safely appends it to the Xray config's `clients` array via Python's JSON parser (not text-matching, so immune to the Section 8 corruption class of bug), restarts Xray, and prints both the new client's `vless://` link and a scannable QR code (`qrencode -t ANSIUTF8`). Usage: `sudo vpn-add-friend "Friend's Name"`. Requires `qrencode` (`sudo apt install -y qrencode`).
- **Two-layer firewall reminder for any future port:** both the Oracle **Security List** (cloud-level, in the Console) and the VM's own **iptables INPUT chain** (OS-level, has a catch-all REJECT rule that every new port must be explicitly inserted above) need a rule — opening one without the other silently fails with different symptoms (Security List missing → connection timeout; iptables missing → connection refused).

**Mac client:**
- Native Hiddify (from `hiddify/hiddify-next` GitHub releases, **not** the App Store iOS build) installed at `/Applications/Hiddify.app`.
- Profile "MHS-Stealth" imported and working.
- **Service mode: "Proxy service only"** (VPN/TUN mode does not currently work on this Mac — see Section 6.5). System proxy configured manually: System Settings → Network → Wi-Fi → Details → Proxies → SOCKS, `127.0.0.1` : `12334` (Hiddify's Mixed port).
- macOS proxy settings are per network **service** (e.g. "Wi-Fi"), not per individual SSID — switching Wi-Fi networks keeps the same proxy config automatically; switching to a genuinely different service (USB/Bluetooth tethering, Ethernet) would need the same SOCKS setting added there separately.
- Verified end-to-end: `curl -s --socks5 127.0.0.1:12334 https://api.ipify.org` → `137.23.22.149` (correct — traffic is routing through the Oracle server).

**Day-to-day usage:** open Hiddify → select MHS-Stealth → tap connect → done. No terminal or SSH needed for normal use; all of that was one-time setup. To verify: check an IP-lookup site in a browser (picks up the system proxy automatically).

**Sharing with friends:** run `sudo vpn-add-friend "Name"` on the server, screenshot the printed QR code, send it. Phone-based Hiddify clients (iOS/Android) can typically scan the QR directly; laptop clients get the plain printed link pasted into "Manually add." Windows clients reportedly support full TUN/VPN mode without the macOS network-extension problem hit in Section 6.5.

**To revoke a friend's access:** manually delete their `{ "id": "..." }` entry from `/usr/local/etc/xray/config.json`'s `clients` array, then `sudo systemctl restart xray`. (A symmetrical `vpn-remove-friend` script was discussed but not built.)

---

## 10. Outstanding / unresolved items

- **VPN/TUN mode on the Mac never got fixed**, only worked around via proxy mode + manual SOCKS config. If Hiddify updates, or if a different macOS-native Reality client is tried later, worth re-attempting native VPN mode.
- **Cleanup not yet done:** the temporary `~/serve` Python file server on the Oracle box (port 8081) should be stopped if it wasn't already, and the temporary iptables ACCEPT rule for 8081 could be removed if that debugging port is no longer needed.
- **DNS (Phase 5)** was never built for the WireGuard side — clients get `1.1.1.1` directly rather than an on-VM forwarder.
- **`bin/vpn peer add` automation (Phase 6)** for WireGuard was never built; peers are still added by hand. The new `vpn-add-friend` script covers the equivalent need for the Reality/Xray side only.
- **CLI (Phase 7), monitoring (8), automation/recovery (9), security hardening (10)** — none started for the original WireGuard project.
- A `vpn-remove-friend` companion script for the Reality side was discussed but not built.

---

## 11. Key lessons worth generalizing

1. **Two-layer cloud firewalls fail silently and differently per layer.** On Oracle Cloud specifically, both the Security List (console-level) and the VM's own iptables need every port added, and the failure mode tells you which one is missing (timeout = Security List; refused = local firewall).
2. **A "handshake did not complete" or similarly generic TLS-layer error can have a completely non-obvious root cause** — in this case, a specific CDN's edge behavior for one popular disguise domain, discovered only by systematically ruling out every other variable (keys, clock, flow parameters) with concrete verification for each before moving to the next.
3. **Never trust that a downloaded macOS app is the build you think it is** — checking `Contents/MacOS/` directly exposed that an "iOS app on Mac" had been installed instead of the native build, which no amount of Gatekeeper/quarantine troubleshooting would have fixed.
4. **Browser-rendered links corrupt plain text on copy**, and this is a real, reproducible failure mode (not paranoia) whenever an AI assistant's chat responses containing domain-like strings get copy-pasted into a terminal or another app — routing critical strings through base64 or a direct file-fetch sidesteps it entirely.
5. **"Connected" in a VPN client's UI does not mean traffic is actually routing** — always verify with an actual external check (`curl` to an IP-echo service) rather than trusting the app's own status indicator, since Service Mode (proxy vs. VPN) changes what "connected" actually means.
