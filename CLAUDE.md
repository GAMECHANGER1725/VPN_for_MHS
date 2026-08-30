# VPN_for_MHS — project memory

Read this first, every session. It is the standing context; volatile state
lives in [docs/session-state.md](docs/session-state.md).

## What this is

A self-hosted stealth VPN. Current architecture is **VLESS + Reality via
Xray-core** on an Oracle Cloud VM (`137.23.22.149`), listening on **TCP/443**,
with a legacy **WireGuard** instance on UDP/51820 on the same host.

The project began as WireGuard-on-a-MacBook, moved to Oracle Cloud, then
pivoted to Reality when the requirement became DPI evasion rather than plain
remote access. [VPN_PROJECT_HISTORY.md](VPN_PROJECT_HISTORY.md) is the full
narrative: every decision, every bug, every dead end. Read it before
concluding anything is unexplained — it probably already happened once.

## Threat model — do not drift from this

The adversary is a **school network filter**, not a nation-state censor. The
ranked list of what will actually block us is in
[docs/stealth-roadmap.md](docs/stealth-roadmap.md) §1. In short: IP/ASN
reputation, TLS interception, and proxy-only egress are the live threats.
Active probing, protocol signatures and TLS fingerprinting are already beaten
and do not need further optimisation.

Most published research on this topic is written about the GFW and Iran.
It is only partially transferable. Treat it accordingly.

## Documents, in reading order

| File | What it is |
|---|---|
| `VPN_PROJECT_HISTORY.md` | Complete project history. The source of truth for what was tried. |
| `docs/stealth-roadmap.md` | Current plan: critical analysis of the DPI research, tiered pathway, open decisions. |
| `docs/session-state.md` | Live state — what is done, what is next, what is blocked. Update it as work lands. |
| `docs/limitations.md` | Original constraints. **Known stale**: §9's non-goal about filter-defeating tooling no longer matches what was built. Reconcile, don't ignore. |
| `docs/architecture.md` | WireGuard-era design. Largely superseded. |
| `docs/obfuscation.md` | The wstunnel cloak design. **Never built** — superseded by Reality. |

## Hard rules

- **Branch:** develop and push to `claude/oracle-cloud-setup-rjrps3`.
- **Never commit credentials.** No client UUIDs, no private keys, no short IDs
  with their matching public key. The repo is currently clean of these and
  must stay that way — use placeholders like `<uuid>` and point to the file on
  the server instead. Real values live in `/usr/local/etc/xray/config.json`.
- **Edit Xray's config with Python's `json` module, never `sed`.** A whole
  class of corruption bugs came from text-matching this file. History file,
  section 8.
- **Firewall changes on the VM require a rollback net.** Back up the rules,
  schedule an automatic restore, verify SSH over a *second* connection, then
  cancel the rollback. A catch-all REJECT in the FORWARD chain has already
  broken this project once.
- **Two firewall layers.** OCI security lists are separate from `iptables`.
  A port can be open on one and closed on the other. Check both before
  concluding anything about reachability.
- **Report measured results, not expected ones.** If a check was not run, say
  so. Several past bugs were prolonged by assuming a command had taken effect.

## Legacy WireGuard codebase

`bin/`, `lib/`, and `tests/` are the original WireGuard-on-Mac/VM tooling —
still present and still tested, but not where the Reality/Xray work happens
(that's all on the VM, in `/usr/local/etc/xray/config.json` and shell
history, not in this repo).

- `bin/vpn` is a thin dispatcher (`init`, `peer add/list/show/export/remove`,
  `start/stop/restart`, `status`, `doctor`); real logic lives in `lib/*.sh`
  (`common.sh`, `ipam.sh`, `keys.sh`, `config.sh`, `peers.sh`) so it's unit
  testable. Secret material is only ever read in `bin/vpn`/`lib/keys.sh` and
  passed by value, never logged.
- `bin/vpn-doctor` is a read-only macOS network/reachability auditor (run it
  before touching sysctls, pf, or routes). `--client-check` answers "can a
  WireGuard client get out from this network" with one STUN round trip.
- Run the whole suite with `tests/run-all.sh` (bash syntax + python syntax +
  `test-*.sh` unit suites); run one file directly, e.g. `bash
  tests/test-ipam.sh`, when iterating on a single `lib/*.sh` module.
- Live state (keys, peer configs, IPAM) lives under `~/.config/vpn-for-mhs`,
  outside the repo — the working tree holds code only.

## Environment differences

A session running **locally on the Mac** has a shell on the Mac and SSH to the
VM, and can execute the roadmap directly.

A session running **in the cloud (claude.ai/code)** has the repo and nothing
else — no Mac, no VM, no SSH key. It can write and reason but cannot verify
anything about the live system. Never claim otherwise; prepare work for a
local session instead.

## Conventions

Prose docs are written plainly and admit uncertainty rather than papering over
it. Tables over bullet soup where there is real structure. Scripts go in
`bin/`, are executable, handle errors, and say what they did.
