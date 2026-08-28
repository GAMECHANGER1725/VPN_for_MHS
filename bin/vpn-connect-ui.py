#!/usr/bin/env python3
#
# vpn-connect-ui.py — a tiny local web UI for connecting/disconnecting the
# WireGuard client tunnel on this machine.
#
# Runs on 127.0.0.1 only. Never binds to a public interface and is not meant
# to be reachable from anywhere but the machine it runs on — it exists so a
# browser button can do what previously took a `sudo wg-quick up/down`
# command, not to expose VPN control to the network.
#
# Requires a matching passwordless-sudo grant for the exact wg-quick
# up/down commands against $HOME/.wireguard/laptop.conf (see
# docs/architecture.md for the sudoers.d snippet). Without that grant,
# connect/disconnect will fail with a permission error rather than prompt,
# since this process runs `sudo -n` (non-interactive) deliberately — a
# background server should never sit there waiting on a password prompt.

import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

HOME = os.path.expanduser("~")
CONF = f"{HOME}/.wireguard/laptop.conf"
WG_QUICK = subprocess.run(["which", "wg-quick"], capture_output=True, text=True).stdout.strip()
NAME_FILE = "/var/run/wireguard/laptop.name"

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>VPN for MHS</title>
<style>
body{font-family:-apple-system,sans-serif;background:#111;color:#eee;display:flex;
flex-direction:column;align-items:center;justify-content:center;height:100vh;margin:0}
button{font-size:1.4rem;padding:1rem 2.5rem;border-radius:999px;border:none;cursor:pointer;
margin-top:1.5rem}
#connect{background:#2ecc71;color:#04240f}
#disconnect{background:#e74c3c;color:#2a0705}
#status{font-size:1.1rem;opacity:0.8}
#msg{margin-top:1rem;font-size:0.9rem;opacity:0.7;min-height:1.2em}
</style></head>
<body>
<h1>VPN for MHS</h1>
<div id="status">checking...</div>
<button id="connect" onclick="doAction('connect')">Connect</button>
<button id="disconnect" onclick="doAction('disconnect')" style="display:none">Disconnect</button>
<div id="msg"></div>
<script>
async function refresh() {
  const r = await fetch('/status'); const j = await r.json();
  document.getElementById('status').textContent = j.connected ? 'Connected' : 'Not connected';
  document.getElementById('connect').style.display = j.connected ? 'none' : 'inline-block';
  document.getElementById('disconnect').style.display = j.connected ? 'inline-block' : 'none';
}
async function doAction(action) {
  document.getElementById('msg').textContent = 'Working...';
  const r = await fetch('/' + action, {method: 'POST'});
  const j = await r.json();
  document.getElementById('msg').textContent = j.ok ? '' : ('Error: ' + j.output);
  await refresh();
}
refresh();
setInterval(refresh, 4000);
</script>
</body></html>"""

class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/status":
            self._json({"connected": os.path.exists(NAME_FILE)})
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
    print("VPN helper running at http://127.0.0.1:8765 (Ctrl+C to stop)")
    server.serve_forever()
