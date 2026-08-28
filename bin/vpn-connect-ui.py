#!/usr/bin/env python3
#
# vpn-connect-ui.py — a local web dashboard for connecting/disconnecting the
# WireGuard client tunnel on this machine, and for watching its real stats
# (handshake age, bytes transferred, connected-since) as reported live by
# `wg show` — nothing on this page is a guess or a placeholder.
#
# Runs on 127.0.0.1 only. Never binds to a public interface and is not meant
# to be reachable from anywhere but the machine it runs on — it exists so a
# browser button can do what previously took a `sudo wg-quick up/down`
# command, not to expose VPN control to the network.
#
# Requires a matching passwordless-sudo grant for the exact wg-quick
# up/down commands and the read-only `wg show all dump` against this
# machine's tunnel (see docs/architecture.md for the sudoers.d snippet).
# Without that grant, actions fail with a permission error rather than
# prompt, since this process runs `sudo -n` (non-interactive) deliberately
# — a background server should never sit there waiting on a password
# prompt. `wg show all dump`'s output includes each interface's private
# key in column 2 of the interface row — that column is deliberately
# never forwarded to the browser (see _parse_wg_dump below).

import json
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HOME = os.path.expanduser("~")
CONF = f"{HOME}/.wireguard/laptop.conf"
WG_QUICK = subprocess.run(["which", "wg-quick"], capture_output=True, text=True).stdout.strip()
WG = subprocess.run(["which", "wg"], capture_output=True, text=True).stdout.strip()
NAME_FILE = "/var/run/wireguard/laptop.name"

PAGE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vpn-connect-ui.html")


def _parse_conf():
    """Read the client's own laptop.conf for non-secret display fields.
    Never returns the private key itself — only values derived from it
    (the public key) or copied verbatim from non-secret lines."""
    fields = {"client_name": os.path.splitext(os.path.basename(CONF))[0]}
    try:
        with open(CONF, "r") as f:
            text = f.read()
        priv = None
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("Address"):
                fields["tunnel_address"] = line.split("=", 1)[1].strip()
            elif line.startswith("DNS"):
                fields["configured_dns"] = line.split("=", 1)[1].strip()
            elif line.startswith("PrivateKey"):
                priv = line.split("=", 1)[1].strip()
        if priv:
            r = subprocess.run(["wg", "pubkey"], input=priv, capture_output=True, text=True)
            if r.returncode == 0:
                fields["client_public_key"] = r.stdout.strip()
    except FileNotFoundError:
        pass
    return fields


def _interface_details(iface):
    """Best-effort MTU and active OS-level DNS for the live tunnel
    interface. Read-only, no sudo required for either lookup."""
    details = {"interface": iface}
    r = subprocess.run(["ifconfig", iface], capture_output=True, text=True)
    if r.returncode == 0:
        m = re.search(r"mtu (\d+)", r.stdout)
        if m:
            details["mtu"] = m.group(1)
    r = subprocess.run(["networksetup", "-getdnsservers", "Wi-Fi"], capture_output=True, text=True)
    if r.returncode == 0:
        out = r.stdout.strip()
        if "aren't any" not in out:
            details["active_dns"] = out.replace("\n", ", ")
    return details


def _parse_wg_dump(output):
    """Parse `wg show all dump` output into a JSON-safe dict. Never
    includes the private key that dump prints in the interface row —
    that column is dropped before this function returns anything."""
    state = {"connected": False}
    for line in output.strip().split("\n"):
        if not line:
            continue
        fields = line.split("\t")
        # interface row: <iface> <private-key> <public-key> <listen-port> <fwmark>
        if len(fields) == 5:
            state["connected"] = True
            state["listen_port"] = fields[3]
            state["server_public_key"] = None  # filled in from the peer row below
        # peer row: <iface> <pubkey> <preshared> <endpoint> <allowed-ips> <handshake> <rx> <tx> <keepalive>
        elif len(fields) == 9:
            state["connected"] = True
            state["server_public_key"] = fields[1]
            state["endpoint"] = fields[3]
            state["allowed_ips"] = fields[4]
            state["latest_handshake"] = int(fields[5])
            state["rx_bytes"] = int(fields[6])
            state["tx_bytes"] = int(fields[7])
            state["keepalive"] = fields[8]
    return state


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, body_str, code=200):
        body = body_str.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            try:
                with open(PAGE_PATH, "r") as f:
                    self._html(f.read())
            except FileNotFoundError:
                self._html("<h1>vpn-connect-ui.html not found next to this script</h1>", 500)
        elif self.path == "/state":
            conf_fields = _parse_conf()
            if not os.path.exists(NAME_FILE):
                self._json({"connected": False, **conf_fields})
                return
            since = os.path.getmtime(NAME_FILE)
            with open(NAME_FILE, "r") as f:
                iface = f.read().strip()
            r = subprocess.run(["sudo", "-n", WG, "show", "all", "dump"], capture_output=True, text=True)
            if r.returncode != 0:
                self._json({"connected": True, "since": since, "error": r.stderr.strip(), **conf_fields})
                return
            state = _parse_wg_dump(r.stdout)
            state["since"] = since
            state["now"] = time.time()
            state.update(conf_fields)
            state.update(_interface_details(iface))
            self._json(state)
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/connect":
            r = subprocess.run(["sudo", "-n", WG_QUICK, "up", CONF], capture_output=True, text=True)
            self._json({"ok": r.returncode == 0, "output": (r.stdout + r.stderr).strip()})
        elif self.path == "/disconnect":
            r = subprocess.run(["sudo", "-n", WG_QUICK, "down", CONF], capture_output=True, text=True)
            self._json({"ok": r.returncode == 0, "output": (r.stdout + r.stderr).strip()})
        else:
            self._json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8765), Handler)
    print("VPN dashboard running at http://127.0.0.1:8765 (Ctrl+C to stop)")
    server.serve_forever()
