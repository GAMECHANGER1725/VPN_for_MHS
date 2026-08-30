# Stealth roadmap: critical analysis and pathway

Written after the 2026 deep-research survey on VPN obfuscation, DPI detection
and Reality hardening. This document does three things: corrects the threat
model the research assumed, separates what the research got right from what it
got wrong or missed, and lays out a tiered pathway with concrete actions.

Read [VPN_PROJECT_HISTORY.md](../VPN_PROJECT_HISTORY.md) first for how we got
here. This supersedes [obfuscation.md](obfuscation.md), which describes the
earlier wstunnel design we never built.

---

## 1. The threat model correction

The research report is written about **nation-state censors** — the Great
Firewall, Iran's DPI, Russia's TSPU. Almost every technique it describes
(active probing at scale, reverse-DNS correlation, statistical flow analysis,
JA4 databases) is a capability of an adversary with a national budget and a
tap on every border link.

**That is not our adversary.** Our adversary is a school network filter.
Concretely, in descending order of likelihood, a school blocks a VPN by:

| # | Mechanism | Cost to them | Beats current setup? |
|---|---|---|---|
| 1 | **IP/ASN reputation feed** — commercial category lists mark cloud/hosting/VPN ranges and block by category | Near zero. Comes with the appliance. | **Yes, completely.** |
| 2 | **TLS interception** (MITM proxy + org root CA on managed devices) | Low on managed laptops | **Yes, completely.** |
| 3 | **Explicit-proxy-only egress** (PAC file; direct :443 dropped) | Zero, it is the default design | **Yes, completely.** |
| 4 | Port/protocol blocking (UDP, non-443) | Zero | No — we are on TCP/443 |
| 5 | Signature DPI for known VPN protocols | Low | No — Reality has no signature |
| 6 | Active probing of destination IPs | Moderate, rarely done | No — Reality's whole point |
| 7 | Statistical flow analysis | High, essentially never done at school scale | No |

The research spends most of its length on rows 5–7, which we already beat, and
barely mentions rows 1–3, which are the ones that will actually stop us.

**Concrete threat intel, confirmed 2026-08-30, permanent project record:** the
target network is a DET (Australian public-school) network running **Palo
Alto** filtering, and it blocks **Cloudflare WARP / 1.1.1.1 by name** — DET's
stated rationale is forcing all traffic through official, monitored DNS and
blocking "unauthorized VPN protocols." This confirms the filter does active,
vendor-grade App-ID/category-based blocking, not just naive port/keyword
rules. It does not automatically doom Tier 2's CDN-fronting plan — WARP is a
distinct consumer VPN app with its own recognisable protocol signature,
architecturally unrelated to VLESS-over-WebSocket relayed through a Cloudflare
Worker, which just looks like ordinary HTTPS/WebSocket traffic to some
website. But Palo Alto's PAN-DB URL categorisation is separate from App-ID
signature matching, and `*.workers.dev` is a well-known, heavily-abused
proxy-hosting namespace — plausible enough that a K-12 filtering profile has
it pre-categorised under something block-worthy regardless of what is
actually happening inside the tunnel. **This cannot be resolved by more
research or engineering, only by testing on the real network** (Tier 3,
below).

**Second, more direct threat intel, confirmed by the project owner
2026-08-30, permanent project record:** DET NSW (the target network's actual
operator — a NSW Department of Education network) blocks **Xray/V2Ray-core
protocol clients** outright, not just Cloudflare WARP. This is a materially
bigger problem than the SNI↔ASN mismatch above: it implies detection at the
protocol-client level, not merely the destination-reputation level. Reality's
entire design premise is that its handshake is indistinguishable from genuine
TLS to `dest` — if DET's block is a Palo Alto App-ID signature keyed on
V2Ray/Xray's TLS *behaviour* (not just known SNIs or IP ranges), Reality could
still get flagged even after Tier 1's ASN fix, because App-ID and PAN-DB URL
categorisation are separate detection layers (as already noted above for
`workers.dev`). Exactly what "blocked" means here — an App-ID signature
match, a blocked IP/ASN range shared with known Xray providers, TLS
fingerprint heuristics, or something else — is **unknown and cannot be
determined without testing on the real network with this specific
deployment**. Do not treat this as disproving the current design; treat it as
raising the priority of Tier 3's real-network test above everything else in
this document, including Tier 1/2 work that assumes the protocol itself is
invisible.

**This is the single most important finding.** Reality is over-engineered for
this threat model in one dimension (handshake indistinguishability) and
under-engineered in another (where the packets are going, and whether we can
even open a direct socket).

A second point that should be stated plainly: [limitations.md](limitations.md)
§9 listed "tooling whose purpose is defeating a network filter" as a permanent
non-goal. The project crossed that line when it adopted Reality. That was a
deliberate choice, but the document still says otherwise and should be
reconciled rather than left contradictory.

---

## 2. Critical read of the research

### 2.1 What it got right

- **Reality's camouflage model is accurately described.** TLS 1.3 only, real
  handshake proxied to the `dest` site, unauthenticated probes see the genuine
  certificate. This matches the Xray documentation and our deployment.
- **Reality is not magic.** The report's core honest conclusion — that Reality
  defeats *active probing* but does nothing about *IP reputation and
  destination correlation* — is correct and is the finding that should drive
  our next architectural decision.
- **"Download the client before you need it"** is the correct answer to the
  blocklisted-download-site problem, and it is much simpler than the report's
  discussion of Telegram mirrors and sideloading. Once the app is installed,
  whether hiddify.com is blocked is irrelevant.
- **Keep Xray current.** Real Reality bugs (TLS record buffer limits causing
  malformed handshakes) have shipped and been fixed. Free correctness.

### 2.2 What it got wrong or overstated

**The reverse-DNS / PTR argument is weak as stated.** The report leans on two
GitHub discussion threads from Iranian users (#2778, #3269) — community
speculation, not measurement. As literally described ("censor does `dig -x` on
the destination IP and compares to the SNI"), the technique would produce
enormous false positives: every Cloudflare origin, every cloud-hosted site,
essentially the whole modern web has a PTR record unrelated to its hostname.

But there is a **much stronger version of the same idea that the report failed
to isolate**, and it is real:

> A ClientHello with `SNI=itunes.apple.com` destined for an **Oracle Cloud IP**
> is anomalous, because `itunes.apple.com` genuinely resolves to Apple/Akamai
> address space. Detecting this needs one IP→ASN lookup against a table the
> filter already ships with. It is cheap, it is deterministic, and it produces
> almost no false positives.

That is the real vulnerability in our current configuration, and it applies
even to a mid-tier commercial filter — not just to nation-states. Fixing it is
Tier 1 below.

**The JA3/JA4 section treats solved work as open.** Our client link already
carries `fp=chrome`; Xray's uTLS generates a genuine Chrome ClientHello. The
report's step "adjust client TLS profiles until the fingerprint matches a
browser" is already done. The residual risk is not the hash — it is
*behavioural*: a Chrome-shaped handshake that then carries a single long-lived
symmetric flow and never does anything else Chrome-shaped. No amount of
fingerprint tuning addresses that.

**The testing methodology contains a measurement error.** The report suggests
verifying your fingerprint by hitting `tlsinfo.me`. If you do that *through*
the tunnel, you measure the ClientHello that **the Xray server** sends to
tlsinfo.me — not the one your Mac sends to your server. The hop we care about
is the only one that service cannot see. Measuring it requires a packet capture
on the Mac or on the VM. Anyone following the report's steps literally would
conclude they had verified something they had not.

**The traffic-shaping advice is unactionable.** "Consider splitting traffic
across multiple endpoints to approximate typical browsing patterns" is not a
thing a single-user personal VPN can meaningfully do, and the adversary who
would notice does not exist in our threat model. Deprioritise entirely.

**Sources are uneven.** Roughly a third of the citations are VPN-vendor
marketing or SEO blogs (`snapvpn.net`, `proxypoland.com`, `bypasscore.com`,
`vpnvertex.com`). The load-bearing claims should be traced to the Xray docs,
the ACM OpenVPN-fingerprinting paper, and the arXiv censorship surveys; the
rest is corroboration at best.

### 2.3 What it missed entirely — and these are the important ones

**(a) Everything else listening on our IP undoes Reality completely.**

Reality's premise is "this IP is a web server." Our IP currently also answers:

- **UDP/51820 — WireGuard.** WireGuard is trivially identified by a single
  probe packet; its handshake response is a fixed, unambiguous signature. An
  IP that serves "Apple's website" on 443 *and* speaks WireGuard on 51820 is
  not a web server, and one `nmap -sU` settles it.
- **TCP/22 — SSH**, presumably open to the world.
- Any leftovers, e.g. the temporary Python file server on **8081** from the
  clipboard-corruption debugging session.

This is a self-inflicted wound that no amount of camouflage-domain tuning
fixes, it is specific to our deployment, and the research never raises it
because the research does not know our deployment. **Highest-value, lowest-cost
fix on this entire list.**

**(b) TLS interception breaks Reality outright.**

On a managed device with an organisational root CA installed, a MITM proxy
terminates TLS and re-originates it. Reality cannot survive this: the client
validates against the real site's certificate parameters, and the proxy's
substituted certificate will not match. The connection simply fails. There is
no configuration that fixes this within Reality.

The countermeasure is a different transport entirely — tunnelling *through*
the school's proxy (HTTP CONNECT) rather than around it, which Xray supports
via outbound chaining / `sockopt.dialerProxy`. We have not built this and have
no idea whether we need it, because we have never tested on the target network.

**(c) Explicit-proxy-only networks.**

Same shape: if direct outbound :443 is dropped and everything must traverse a
PAC-configured proxy, a direct Reality connection never leaves the building.
Same countermeasure — upstream proxy chaining.

**(d) The DNS asymmetry.**

Our client dials an IP literal and puts `itunes.apple.com` in the SNI. On a
network that logs DNS, there is a ClientHello for a hostname the host never
resolved. Low severity, but it is a free correlation signal and worth knowing
exists.

**(e) IP reputation categorisation** gets one passing sentence in the report,
despite being mechanism #1 in the table above.

---

## 3. Three architectures, honestly compared

The research implicitly assumes we stay on Reality forever. We should
explicitly consider the alternatives, because the ASN-mismatch problem is
structural to how we are using Reality, not a tuning issue.

### Option A — Reality, as-is (current)

`client → TCP/443 → OCI IP, SNI=itunes.apple.com`

- **Strong against:** active probing, signature DPI, TLS fingerprinting.
- **Weak against:** IP/ASN reputation, SNI↔ASN mismatch, TLS interception,
  proxy-only egress.
- **Cost:** zero. Already built and working.

### Option B — Reality with an ASN-plausible `dest`

Same architecture, but the camouflage domain is one whose genuine addresses
live in the same cloud/ASN as our VM, so the SNI↔IP join stops being anomalous.

- **Strong against:** everything A is, plus SNI↔ASN correlation.
- **Weak against:** IP/ASN reputation (unchanged), TLS interception (unchanged),
  proxy-only egress (unchanged).
- **Cost:** zero, but requires finding a suitable domain genuinely served from
  Oracle Cloud that also meets Reality's criteria (TLS 1.3, HTTP/2, no
  redirect, OCSP stapling, non-political, high reputation). This is the hard
  part and may not have a good answer — OCI hosts far less public web presence
  than AWS/GCP/Cloudflare do.

### Option C — CDN-fronted (VLESS + WebSocket + TLS behind Cloudflare)

`client → TCP/443 → Cloudflare edge IP, SNI=our-domain.com → origin (our VM)`

- **Strong against:** IP reputation (destination is Cloudflare, uncategorisable
  without collateral damage), SNI↔ASN mismatch (our domain legitimately
  resolves to Cloudflare), proxy-only egress (works through CONNECT proxies),
  and it survives on networks that block hosting ranges wholesale.
- **Weak against:** TLS interception (still broken); and it introduces a
  **third party into the data path**, which is precisely the A-vs-B distinction
  [limitations.md](limitations.md) §4 promised we would never blur silently.
  Cloudflare terminates TLS at its edge; VLESS carries no encryption of its
  own, so the CF→origin leg must itself be TLS or Cloudflare can read the
  stream.
- **Cost:** zero, using a free Cloudflare Workers `*.workers.dev` subdomain
  instead of a purchased domain — no `~$10/yr` domain needed. Free tier only
  needs an email signup, no payment method. **Real caveat, not previously
  documented:** Cloudflare's Workers ToS prohibits using Workers for VPN/proxy
  traffic, and flags heavy usage for account suspension. This risk is inherent
  to the architecture (relaying VLESS through a Worker), not to the choice of
  `workers.dev` vs. a paid domain — accepted here as a known trade-off, not an
  oversight.

**Decision made (owner call, 2026-08-30):** Option C, as a **second Xray
inbound alongside the existing Reality inbound** — not a replacement. **Built
and verified 2026-08-30** — see [session-state.md](session-state.md) for the
full build record. Initially blocked on there being no Cloudflare
account/token in this environment (correctly, per the hard rule against
autonomous sign-up); the owner then authorized manually (plugin install +
OAuth), and the rest — Worker deployment, second Xray inbound, firewall
opening on both layers (iptables and, newly discovered, the OCI Security
List) — proceeded. The Worker is a dumb WS↔TCP relay, not a VLESS
implementation in JS: it terminates WebSocket+TLS at Cloudflare's edge and
forwards raw bytes to a **plain-TCP** Xray inbound on the VM, since a real
Xray server already exists there. Transport path verified end-to-end (a
genuine Cloudflare IP observed connecting straight into the `xray` process on
the VM); not yet exercised through a full real-client VLESS session.

**Assessment:** Option C is the strongest answer to the threat model we
actually face, and the weakest answer to the project's founding principle of
being genuinely self-hosted. That trade-off is a decision for the project
owner, not a technical detail to be resolved by me. Option B is a free partial
improvement that does not require making that decision, and should be
attempted regardless.

The pragmatic route is **B now, C as a second profile in the client** — two
configs, switch when one stops working. Redundancy beats trying to build one
perfect tunnel.

**A clean build of Option C is not the same as a working one.** Even once
deployed, a `*.workers.dev` hostname is a plausible target for exactly the
kind of category-based filtering DET's Palo Alto already does to Cloudflare
WARP (see §1's threat-intel note) — this is unverified until tested on the
real network, regardless of how cleanly the Worker and second inbound build
and handshake in isolation.

---

## 4. The pathway

### Tier 0 — Do first. Cheap, high-impact, no decisions required.

**Status as of 2026-08-30: items 1–6 done and measured, item 7 still open.**
See [session-state.md](session-state.md) for exact verification evidence.

1. **Audit what our IP exposes.** From an off-network host:
   ```sh
   nmap -Pn -sS -p- <IP>          # every open TCP port
   sudo nmap -Pn -sU -p 51820,500,4500,1194 <IP>   # VPN-shaped UDP
   ```
   Anything other than 443 answering is a leak of the "just a web server"
   story.
2. **Restrict WireGuard.** Either firewall UDP/51820 to known source addresses,
   or shut it down when not in use. Leaving a world-reachable WireGuard
   responder on the same IP as a Reality endpoint negates Reality.
3. **Restrict SSH** to known source addresses (OCI security list + `iptables`),
   or move it off 22.
4. **Remove debugging leftovers** — the 8081 file server and its iptables rule,
   if still present.
5. **Confirm the Reality handshake is genuine** from off-network:
   ```sh
   openssl s_client -connect <IP>:443 -servername itunes.apple.com </dev/null 2>&1 | head -30
   openssl s_client -connect <IP>:443 -servername example.com </dev/null 2>&1 | head -20
   openssl s_client -connect <IP>:443 </dev/null 2>&1 | head -20   # no SNI
   ```
   All three should behave like the real destination, and the first should show
   a valid Apple certificate chain. Divergence between them is a fingerprint.
6. **Revert `loglevel` to `warning`** and confirm Xray is on a current release.
7. **Fix macOS TUN mode.** Unrelated to stealth, but it is the live daily-use
   blocker and the cause of the "no internet when disconnected" bug. Diagnostics
   already specified: `codesign -dv --verbose=4` on the app and its `.appex`,
   Console.app filtered on `subsystem:com.apple.system-extension`, and a check
   for a missed "System Extension Blocked" notification.

### Tier 1 — Close the SNI↔ASN mismatch.

8. Establish what our IP actually looks like to a filter: its ASN, its
   published category, and its PTR record.
   ```sh
   whois <IP> | grep -iE 'orgname|netname|origin|country'
   dig +short -x <IP>
   ```
9. Find candidate `dest` domains served from the same cloud, and test each
   against Reality's criteria (TLS 1.3, HTTP/2, no redirect, OCSP stapling):
   ```sh
   curl -sI --tlsv1.3 --http2 https://<candidate>/ | head -5
   openssl s_client -connect <candidate>:443 -tls1_3 -status </dev/null 2>&1 | grep -iE 'OCSP|Protocol|Cipher'
   dig +short <candidate> | head -3      # then whois those IPs for ASN
   ```
   If no acceptable candidate exists, that is a finding — it means Option B is
   unavailable and the choice is A-as-is or C.

### Tier 2 — Build a second, differently-shaped path.

10. ~~Stand up a second inbound so the client has two profiles to switch
    between.~~ **Done 2026-08-30** — CDN-fronted (Option C) is live as a
    second inbound; see §3 above and [session-state.md](session-state.md).
    Chosen because it fails differently from Reality: it survives
    IP-reputation blocking and proxy-only egress, which Reality does not. It
    inherits an open question Reality doesn't have to answer, though: whether
    it also survives the protocol-level Xray/V2Ray block DET is confirmed to
    run (§1) — untested.
11. If TLS interception turns out to be present on the target network,
    configure Xray outbound chaining through the school's own proxy. Do not
    build this speculatively — test first.

### Tier 3 — Measure, don't assume.

12. **The only test that matters is a test from the target network.** Every
    other check in this document is a proxy for it. Record what actually
    happens: does the TCP connection open, does the handshake complete, does
    traffic flow, and if it fails, at which stage.
13. Measure the real client→server ClientHello with a capture, not a web
    service:
    ```sh
    sudo tcpdump -i any -s0 -w /tmp/ch.pcap "host <IP> and port 443"
    ```
    then extract the JA4 from the first ClientHello. This is the measurement
    the research got wrong.
14. Watch the server's Xray log for handshake failures from addresses that are
    not ours — that is what active probing would look like if it ever happened.

---

## 5. Decisions that need an owner

These were live questions before 2026-08-30. All three are now resolved by the
project owner; recorded here so a future session doesn't re-litigate them.

1. **Third party in the data path — yes or no?** ~~Option C is the strongest
   available design and violates the founding "genuinely self-hosted"
   principle.~~ **Resolved: yes.** Option C, as a second inbound alongside
   Reality — see §3 above for status.
2. **Reconcile [limitations.md](limitations.md) §9.** ~~The stated non-goal of
   filter-defeating tooling no longer matches what is built.~~ **Resolved:**
   amended 2026-08-30.
3. **Is WireGuard still worth keeping?** ~~It costs us the "just a web server"
   story on our only IP, and Reality covers every network WireGuard
   covers.~~ **Resolved: no.** Retired 2026-08-30 — service stopped and
   disabled, its firewall rule removed, config left in place.

---

## 6. What remains genuinely unknown

- Whether the target network does TLS interception, uses explicit-proxy-only
  egress, or blocks hosting ASNs by category. All three are answerable with one
  session on that network and are currently pure speculation.
- Whether Reality is detectable in ways not yet public. The Iranian reports are
  suggestive but are community threads, not measurement studies.
- How long browser-fingerprint mimicry stays sufficient as composite
  fingerprinting (TLS + OS + ALPN + HTTP/2 settings) spreads. Not our problem
  at school-filter scale, but it is the direction of travel.
