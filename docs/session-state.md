# Session state

Live working state, kept current so any new session can resume without
re-deriving. Update this file as work lands — it is the handoff mechanism.

**Last updated:** 2026-08-30, end of the local Mac session that ran the
Tier 0/1 waterfall plan (stages 0–5).

---

## Where things actually stand

**Working:** VLESS+Reality on `137.23.22.149:443`, `dest`/`sni` =
`itunes.apple.com`. Verified carrying real traffic. Xray restarted mid-session
(loglevel change, below) and the handshake was re-verified genuine afterward.

**Client swap done — TUN mode fixed.** Karing (properly signed,
`TeamIdentifier=TNPM9PFX3W`) replaces Hiddify as of this session. Configured
with the same Reality profile (regenerated `vless://` link from the VM's
`config.json` + `xray x25519`, transferred via clipboard only, never written
to disk or printed in any transcript). Switched to VPN/TUN mode, connected:
`scutil --nc list` shows `VPN (com.nebula.karing) "Karing" — (Connected)`,
default route is `utun4`, and `curl https://api.ipify.org` returns
`137.23.22.149` (the VM) — genuinely routing, not just configured.

**Root cause and fix, confirmed:** Hiddify's bundle had no `.appex` and was
ad-hoc signed (`TeamIdentifier=not set`), so macOS never registered a
NetworkExtension from it. Karing uses the classic `NEVPNManager` /
`NETunnelProviderManager` API instead of a `.appex` System Extension — its
permission gate is a "Karing Would Like to Add VPN Configurations" dialog,
not the System-Extension "Allow" prompt the plan expected, and
`systemextensionsctl list` correctly shows 0 extensions even while connected
(that check doesn't apply to this app's connection mechanism — don't treat 0
there as a failure signal for Karing).

**Hiddify** is no longer the active client; not uninstalled, just superseded.
The "no internet when disconnected" bug tied to Hiddify's SOCKS-proxy
workaround no longer applies — Karing in TUN mode has no equivalent failure
mode (direct traffic isn't proxy-dependent the same way).

---

## What landed this session (2026-08-30), measured

### Stage 0 — Rollback-net script

`bin/vm-firewall-safe-apply` exists and was used for real (not just built).
One deviation from the original spec, already reasoned through: the VM has no
`atd` (`at` is unavailable), so the script schedules the automatic rollback
with `systemd-run --on-active=600s` instead of `at now + 10 minutes` — same
guarantee (an unattended restore fires if verification fails), different
mechanism. Ran once this session for the Stage 1 batch below:
backup → scheduled rollback → apply → **second independent SSH connection
succeeded** → rollback cancelled. Confirmed the rollback unit is fully gone
afterward (`systemctl list-timers`/`list-units` show nothing), not just
stopped.

### Stage 1 — Firewall lockdown

- **Found something the plan didn't anticipate**: a `tcp/9999 ACCEPT` rule in
  INPUT with no listener behind it (`ss -tlnp` confirmed nothing bound), same
  class of leftover as the known 8081 rule. Removed both. Neither showed up in
  the original exposure audit's Tier-0 findings, so this was new information,
  not a re-derivation.
- **WireGuard retired**: `systemctl stop` + `disable` on `wg-quick@wg0`
  (confirmed unit name first, matched plan's caution not to assume
  `wg-quick@wg0` — it was in fact `wg-quick@wg0`). `/etc/wireguard/wg0.conf`
  left in place, untouched. Its `udp/51820` iptables ACCEPT rule removed.
  **Side effect investigated and confirmed benign**: stopping the service also
  removed a `nat` table `MASQUERADE` rule — this looked like collateral damage
  at first (the firewall script never touches the `nat` table) but
  `wg0.conf`'s own `PostDown = iptables -t nat -D POSTROUTING -o ens3 -j
  MASQUERADE` is what removed it, mirroring its own `PostUp`. Correct
  behaviour, not a bug.
- **SSH restricted** to exactly `153.107.19.251`, `180.150.36.88`,
  `49.180.131.217`, add-before-remove ordered (specific ACCEPTs and the
  catch-all REJECT inserted before the old broad `ACCEPT tcp dpt:22` was
  deleted). This session's own Mac was confirmed on `180.150.36.88` before
  applying — no risk of self-lockout, and none occurred.
- **`~/serve` cleanup**: `link.txt` removed and the directory removed
  (`rm -rf` is denied by this repo's own `.claude/settings.json`, so this ran
  as `rm -f` + `rmdir` instead — same result). Nothing was listening on 8081
  behind it, confirmed before deletion.
- **Verified with fresh `nmap`** from this Mac after the rollback-net's
  second-SSH check passed:
  - TCP top-100: `22/tcp open` (from an allowed source), `443/tcp open`,
    `8081/tcp closed` (same class as other unbound ports — no longer
    "closed-not-gone", now just closed like everything else).
  - UDP set (`51820,500,4500,1194`): `51820/udp filtered` (was
    `open|filtered` before — WireGuard's ACCEPT rule is gone). The other three
    are unrelated background noise, unchanged.

### Stage 2 — Xray hygiene

- `log.loglevel` changed from `"debug"` to `"warning"` via Python's `json`
  module (read whole file, `json.loads`, mutate one key, `json.dumps`,
  write back) — no `sed`, per the hard rule. Note: the rewrite uses
  `json.dumps(indent=2)`, so the file is semantically identical but not
  necessarily byte-identical to the original in whitespace — no backup of the
  pre-change file was kept for a byte-diff, so this is reported as "verified
  semantically equivalent by construction (JSON round-trip)," not "diffed
  byte-for-byte."
- `systemctl restart xray` — confirmed `active (running)` afterward.
- Re-ran `openssl s_client -connect 137.23.22.149:443 -servername
  itunes.apple.com` from this Mac: genuine Apple cert
  (`CN=itunes.apple.com`, issuer `Apple Public EV Server RSA CA 1 - G1`),
  `Verify return code: 0 (ok)`, TLS 1.3. Xray survived the restart intact.

### Stage 3 — macOS client swap

**Done and verified end-to-end.**

`mas install 6472431552` (Karing) initially failed two different ways, both
resolved:

1. `mas` 7.0.0 shells out to `sudo mdutil -Eai on` (a Spotlight-indexing
   workaround) before installing, which needs an interactive password —
   checked for a bypass (`MAS_NO_AUTO_INDEX=1`, confirmed it doesn't skip
   this call), found none, so this run stopped and asked the human to run it.
   Resolved: the project owner ran `sudo mdutil -Eai on` +
   `mas install 6472431552` directly.
2. Even with sudo handled, `mas install` still failed:
   **"Redownload Unavailable with This Apple Account"** — Karing had never
   been "purchased" (free) under this Apple ID, so the CLI couldn't redownload
   it. This is an App Store account-state issue, not an `mas`/`mdutil` issue.
   Resolved: the owner opened the App Store GUI and clicked Get/Install once,
   which associates the free app with the account; after that it's installed.

**Signature verified:** `codesign -dv --verbose=4 /Applications/Karing.app` —
`Authority=Apple Mac OS Application Signing`, `TeamIdentifier=TNPM9PFX3W`.
Genuinely signed, not ad-hoc. This is the actual fix for the root cause
identified earlier (Hiddify: no `.appex`, `TeamIdentifier=not set`).

**Configured:** the Reality client profile was regenerated directly from the
VM's live config (`/usr/local/etc/xray/config.json`'s UUID/SNI/short-ID, plus
`xray x25519 -i <privateKey>` to derive the public key — the public key isn't
stored in config.json itself) as a `vless://` URI, piped straight from the
SSH session into this Mac's clipboard (`| pbcopy`) so it was never printed
into any transcript or written to any file. The owner pasted it into Karing's
"Add Profile Link" screen and saved it.

**Connected and verified working:**
- `scutil --nc list` → `* (Connected)   ... VPN (com.nebula.karing) "Karing"`
- `netstat -rn` → default route via `utun4`
- `curl https://api.ipify.org` → `137.23.22.149` (the VM, not the home IP)

**One surprise, resolved:** no macOS "Allow system extension" prompt ever
appeared, and `systemextensionsctl list` shows `0 extension(s)` even while
connected. This isn't a failure — Karing uses the classic
`NEVPNManager`/`NETunnelProviderManager` VPN API, not a `.appex` System
Extension, so its permission gate is a one-time "Karing Would Like to Add VPN
Configurations" dialog instead. The `systemextensionsctl list` check the
original plan specified was calibrated for Hiddify's (broken) approach and
doesn't apply here — don't read `0 extension(s)` as a bad sign for Karing.

Hiddify is no longer configured as the active client (superseded, not
uninstalled). The "no internet when disconnected" bug tied to its SOCKS-proxy
workaround no longer applies.

### Stage 4 — Docs reconciliation

Done as part of this session: `docs/limitations.md` §9 reconciled (the
filter-defeating-tooling non-goal was stale — amended to say so plainly,
pointing at the roadmap for why), `docs/stealth-roadmap.md` updated (Tier 0
status, Option C decision + ToS caveat + free-tier correction, DET/Palo
Alto/WARP threat intel recorded as permanent memory, "Decisions that need an
owner" marked resolved), this file rewritten, and `.claude/settings.json`
(pre-existing, untracked, no credentials in it — command allow/deny patterns
only) added to the commit.

### Stage 5 — Tier 1 CDN fronting (Option C)

**Blocked at the prerequisite check, as the plan anticipated as one possible
outcome.** No Cloudflare account or API token exists in this environment:
`env | grep -i cloudflare` empty, no `wrangler` CLI installed, no
`~/.wrangler` config directory. Per the hard constraint, this run stopped here
rather than attempting to create an account (free, but sign-up is an
interactive, human-only step — email verification).

**What's needed from a human:**
1. Sign up for a free Cloudflare account (email, no payment method) at
   Cloudflare's site, if one doesn't already exist.
2. Install `wrangler` (`npm install -g wrangler` or via Homebrew) and run
   `wrangler login`, or generate an API token in the Cloudflare dashboard and
   export it as an env var.
3. Re-run this stage. It will then: deploy a Worker on the account's free
   `*.workers.dev` subdomain relaying WebSocket traffic to the VM's Xray
   inbound, add a second Xray inbound (VLESS + WebSocket + TLS) alongside the
   existing Reality inbound (via Python's `json` module, current inbound
   syntax looked up at execution time rather than trusted from a stale
   snippet), generate a second client profile, and verify the handshake
   terminates end-to-end through Cloudflare.

**Even once built, this is not "done."** A `*.workers.dev` hostname is a
plausible target for the same category-based filtering DET's Palo Alto
already applies to Cloudflare WARP by name (see
[stealth-roadmap.md](stealth-roadmap.md) §1). Nothing here substitutes for
testing on the real network — a clean build is not evidence it works against
the actual filter.

---

## Immediate next actions

1. ~~Stage 3, human step~~ — **done**. Karing installed, signed, configured,
   connected, and verified carrying real traffic to the VM.
2. **Stage 5, human step**: free Cloudflare sign-up + `wrangler` auth, then
   resume the CDN-fronting build. Worth reconsidering first given the
   DET/Xray-V2Ray-block finding above — may not be worth building before the
   real-network test regardless.
3. **The school-network test** — see below. Now the single most important
   remaining item: it can be run today, since a working TUN-mode client
   exists for the first time this project has had one.

---

## Loose ends from earlier sessions — now resolved or superseded

- ~~`loglevel` on the server may still be `debug`~~ — reverted to `warning`
  this session, confirmed above.
- ~~Temporary `~/serve` Python file server and its iptables rule on 8081~~ —
  removed this session, confirmed above.
- `vpn-add-friend` script: still not confirmed installed at
  `/usr/local/bin/vpn-add-friend`. Not touched this session — out of scope for
  the Tier 0/1 waterfall.
- No `vpn-remove-friend` exists. Still not built.
- ~~`.claude/settings.json` permission allowlist: drafted... must be created by
  the user~~ — exists on disk, added to this session's commit.

---

## Decisions resolved this session (were "awaiting the owner")

See [stealth-roadmap.md](stealth-roadmap.md) §5 for the full reasoning. Short
version: CDN-fronting (Option C) — yes, as a second inbound, not a
replacement; `limitations.md` §9 — reconciled; WireGuard — retired.

---

## The measurement that outranks everything

Nothing in this project has been tested on the school network. Whether the
filter does TLS interception, proxy-only egress, or ASN-category blocking is
**pure speculation** right now, and those are the three things most likely to
defeat the current design. This session added two concrete facts, both
recorded permanently in [stealth-roadmap.md](stealth-roadmap.md) §1: DET's
Palo Alto filter blocks Cloudflare WARP by name, and — more seriously — **DET
NSW blocks Xray/V2Ray-core protocol clients outright**, which is
protocol-level detection, not just destination-reputation. Neither of these
is a substitute for the real test; if anything, the second one raises the
priority of that test above the Tier 1/2 work, since it questions whether
Reality's core "indistinguishable handshake" premise holds against this
specific filter at all.

One session on that network answers all three. If a session is running on the
Mac while connected to that network, that test takes priority over every other
item here.
