#!/usr/bin/env python3
"""
stun-probe.py — ask a public STUN server what address and port it sees this
machine sending from, over UDP.

Why this exists: WireGuard is UDP-only. Whether a WireGuard client can work on
a given network comes down to one question — does this network let arbitrary
outbound UDP out, and does it let the replies back in? A STUN binding request
answers exactly that, because a successful round trip proves both directions
worked on a non-DNS UDP port.

It also reports the public address and port the NAT mapped us to, which is a
second, independent read on NAT topology: if STUN's view of our address differs
from what an HTTPS echo service reports, traffic is taking different paths.

RFC 5389 binding request only. Sends one 20-byte datagram, reads one reply.
Allocates nothing, opens no mapping, stores nothing.

Usage:
    stun-probe.py [--server HOST:PORT] [--timeout SEC] [--json]

Exit codes: 0 reply received, 1 no reply (UDP blocked or server down), 2 error.
"""
import argparse
import json
import os
import secrets
import socket
import struct
import sys

MAGIC_COOKIE = 0x2112A442
BINDING_REQUEST = 0x0001
BINDING_SUCCESS = 0x0101
ATTR_MAPPED_ADDRESS = 0x0001
ATTR_XOR_MAPPED_ADDRESS = 0x0020

DEFAULT_SERVER = os.environ.get("STUN_SERVER", "stun.l.google.com:19302")


def build_request(txid: bytes) -> bytes:
    # type, length(0 attributes), magic cookie, 96-bit transaction id
    return struct.pack("!HHI", BINDING_REQUEST, 0, MAGIC_COOKIE) + txid


def parse_attrs(body: bytes, txid: bytes):
    """Yield (attr_type, value) pairs from a STUN message body."""
    off = 0
    while off + 4 <= len(body):
        atype, alen = struct.unpack_from("!HH", body, off)
        off += 4
        if off + alen > len(body):
            break
        yield atype, body[off:off + alen]
        off += alen + ((4 - alen % 4) % 4)  # attributes are 4-byte aligned


def decode_address(atype: int, value: bytes):
    """Return (ip, port) from a MAPPED-ADDRESS or XOR-MAPPED-ADDRESS value."""
    if len(value) < 4:
        return None
    family = value[1]
    port = struct.unpack_from("!H", value, 2)[0]
    raw = value[4:]

    if atype == ATTR_XOR_MAPPED_ADDRESS:
        port ^= MAGIC_COOKIE >> 16
        cookie = struct.pack("!I", MAGIC_COOKIE)
        if family == 0x01:  # IPv4
            raw = bytes(a ^ b for a, b in zip(raw, cookie))
        elif family == 0x02:  # IPv6 is XORed with cookie + transaction id
            return None  # not needed here; v4 is what decides WireGuard viability

    if family == 0x01 and len(raw) >= 4:
        return socket.inet_ntop(socket.AF_INET, raw[:4]), port
    if family == 0x02 and len(raw) >= 16:
        return socket.inet_ntop(socket.AF_INET6, raw[:16]), port
    return None


def probe(host: str, port: int, timeout: float):
    txid = secrets.token_bytes(12)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(build_request(txid), (host, port))
        local_port = sock.getsockname()[1]
        data, _ = sock.recvfrom(2048)
    except (socket.timeout, OSError):
        return None
    finally:
        sock.close()

    if len(data) < 20:
        return None
    mtype, mlen, cookie = struct.unpack_from("!HHI", data, 0)
    if mtype != BINDING_SUCCESS or cookie != MAGIC_COOKIE or data[8:20] != txid:
        return None

    body = data[20:20 + mlen]
    found = None
    for atype, value in parse_attrs(body, txid):
        if atype == ATTR_XOR_MAPPED_ADDRESS:
            found = decode_address(atype, value)
            break
        if atype == ATTR_MAPPED_ADDRESS and found is None:
            found = decode_address(atype, value)
    if not found:
        return None
    return {"mapped_ip": found[0], "mapped_port": found[1], "local_port": local_port}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--server", default=DEFAULT_SERVER, help="host:port of a STUN server")
    ap.add_argument("--timeout", type=float, default=3.0)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if ":" not in args.server:
        print("stun-probe: --server must be HOST:PORT", file=sys.stderr)
        return 2
    host, _, port_s = args.server.rpartition(":")
    try:
        port = int(port_s)
    except ValueError:
        print("stun-probe: port must be numeric", file=sys.stderr)
        return 2

    result = probe(host, port, args.timeout)
    if result is None:
        if args.json:
            print(json.dumps({"ok": False, "server": args.server}))
        return 1

    result["ok"] = True
    result["server"] = args.server
    if args.json:
        print(json.dumps(result))
    else:
        print(f"{result['mapped_ip']}:{result['mapped_port']}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)
