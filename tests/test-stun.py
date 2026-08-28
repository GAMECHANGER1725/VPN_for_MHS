#!/usr/bin/env python3
"""
Unit tests for the STUN message parser in bin/stun-probe.py.

The probe's answer decides whether we tell the user "WireGuard will work on
this network" or "it will not". The network path can't be relied on in CI, so
the parser is tested against synthetic RFC 5389 messages instead.
"""
import os
import struct
import sys
import socket
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("stun", os.path.join(HERE, "..", "bin", "stun-probe.py"))
stun = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stun)

PASS = 0
FAIL = 0


def ok(desc):
    global PASS
    PASS += 1
    print(f"  ok   {desc}")


def bad(desc, extra=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL {desc}")
    if extra:
        print(f"       {extra}")


def eq(desc, expected, actual):
    if expected == actual:
        ok(desc)
    else:
        bad(desc, f"expected {expected!r}, got {actual!r}")


def xor_mapped_v4(ip, port):
    """Build a well-formed XOR-MAPPED-ADDRESS attribute value."""
    xport = port ^ (stun.MAGIC_COOKIE >> 16)
    cookie = struct.pack("!I", stun.MAGIC_COOKIE)
    raw = bytes(a ^ b for a, b in zip(socket.inet_aton(ip), cookie))
    return struct.pack("!BBH", 0, 0x01, xport) + raw


def mapped_v4(ip, port):
    """Build a plain (legacy, un-XORed) MAPPED-ADDRESS attribute value."""
    return struct.pack("!BBH", 0, 0x01, port) + socket.inet_aton(ip)


def attr(atype, value):
    pad = (4 - len(value) % 4) % 4
    return struct.pack("!HH", atype, len(value)) + value + b"\x00" * pad


print("build_request")
txid = b"\x01" * 12
req = stun.build_request(txid)
eq("request is exactly 20 bytes", 20, len(req))
mtype, mlen, cookie = struct.unpack_from("!HHI", req, 0)
eq("type is Binding Request", stun.BINDING_REQUEST, mtype)
eq("length is zero (no attributes)", 0, mlen)
eq("magic cookie is correct", stun.MAGIC_COOKIE, cookie)
eq("transaction id is carried verbatim", txid, req[8:20])

print()
print("decode_address — XOR-MAPPED-ADDRESS (what real servers send)")
eq("typical public address",
   ("203.0.113.9", 54321),
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, xor_mapped_v4("203.0.113.9", 54321)))
eq("port 1",
   ("8.8.8.8", 1),
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, xor_mapped_v4("8.8.8.8", 1)))
eq("port 65535",
   ("1.2.3.4", 65535),
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, xor_mapped_v4("1.2.3.4", 65535)))
eq("CGNAT-space mapping is decoded, not swallowed",
   ("100.90.4.7", 40000),
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, xor_mapped_v4("100.90.4.7", 40000)))
eq("the school's observed egress address",
   ("153.107.19.251", 51820),
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, xor_mapped_v4("153.107.19.251", 51820)))

print()
print("decode_address — legacy MAPPED-ADDRESS")
eq("un-XORed address decodes without XOR applied",
   ("203.0.113.9", 3478),
   stun.decode_address(stun.ATTR_MAPPED_ADDRESS, mapped_v4("203.0.113.9", 3478)))

print()
print("decode_address — malformed input must return None, never garbage")
eq("empty value", None, stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, b""))
eq("truncated header", None, stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, b"\x00\x01"))
eq("family v4 but no address bytes", None,
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, struct.pack("!BBH", 0, 0x01, 1234)))
eq("unknown address family", None,
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, struct.pack("!BBH", 0, 0x09, 1234) + b"\x00" * 4))

print()
print("parse_attrs — attribute walking")
body = attr(0x8022, b"test-software") + attr(stun.ATTR_XOR_MAPPED_ADDRESS, xor_mapped_v4("203.0.113.9", 1234))
found = dict((t, v) for t, v in stun.parse_attrs(body, txid))
eq("both attributes are walked", 2, len(found))
eq("XOR-MAPPED-ADDRESS survives an unaligned attribute before it",
   ("203.0.113.9", 1234),
   stun.decode_address(stun.ATTR_XOR_MAPPED_ADDRESS, found[stun.ATTR_XOR_MAPPED_ADDRESS]))

body = attr(0x8022, b"x")  # 1-byte value, 3 bytes of padding
eq("odd-length attribute is padded correctly", 1, len(list(stun.parse_attrs(body, txid))))

truncated = struct.pack("!HH", stun.ATTR_XOR_MAPPED_ADDRESS, 200) + b"\x00" * 4
eq("attribute claiming more length than exists is dropped",
   0, len(list(stun.parse_attrs(truncated, txid))))

print()
print("─────────────────────────────────")
print(f"passed: {PASS}   failed: {FAIL}")
sys.exit(1 if FAIL else 0)
