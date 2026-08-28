#!/usr/bin/env python3
"""
upnp-wan-ip.py — ask the local router, via UPnP IGD, what IPv4 address it
believes it holds on its WAN interface.

READ-ONLY. Issues exactly two kinds of request:
  1. An SSDP M-SEARCH multicast on the LAN to discover an InternetGatewayDevice.
  2. A SOAP GetExternalIPAddress call to that device.

Neither adds a port mapping, changes a setting, or writes anything.

Why this matters: comparing the router's own WAN address against the address
the Internet actually sees is the most reliable zero-cost CGNAT test there is.
If the router says it has 100.64.3.7 and the Internet sees 203.0.113.9, there
is a carrier NAT between you and the Internet, and no amount of port
forwarding on your router will make inbound connections work.

Exit codes: 0 found (address on stdout), 1 not found, 2 error.
Many routers ship with UPnP disabled. "Not found" is a normal, benign result.
"""
import re
import socket
import sys
import urllib.parse
import urllib.request

SSDP_ADDR = ("239.255.255.250", 1900)
TIMEOUT = 3.0

SEARCH_TARGETS = [
    "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
    "upnp:rootdevice",
]

CONN_SERVICES = [
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANPPPConnection:1",
    "urn:schemas-upnp-org:service:WANIPConnection:2",
]


def discover():
    """Return a list of device description URLs advertised on the LAN."""
    locations = []
    for st in SEARCH_TARGETS:
        msg = (
            "M-SEARCH * HTTP/1.1\r\n"
            f"HOST: {SSDP_ADDR[0]}:{SSDP_ADDR[1]}\r\n"
            'MAN: "ssdp:discover"\r\n'
            "MX: 2\r\n"
            f"ST: {st}\r\n\r\n"
        ).encode()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.settimeout(TIMEOUT)
        try:
            sock.sendto(msg, SSDP_ADDR)
            while True:
                try:
                    data, _ = sock.recvfrom(65507)
                except socket.timeout:
                    break
                m = re.search(rb"(?i)^location:\s*(\S+)", data, re.M)
                if m:
                    loc = m.group(1).decode("ascii", "replace")
                    if loc not in locations:
                        locations.append(loc)
        except OSError:
            pass
        finally:
            sock.close()
        if locations:
            break
    return locations


def control_url(desc_url):
    """Fetch a device description and return (control_url, service_type)."""
    try:
        with urllib.request.urlopen(desc_url, timeout=TIMEOUT) as r:
            xml = r.read().decode("utf-8", "replace")
    except Exception:
        return None, None

    for svc in CONN_SERVICES:
        # Find the <service> block declaring this serviceType, then its controlURL.
        for block in re.findall(r"<service>(.*?)</service>", xml, re.S | re.I):
            if svc.lower() in block.lower():
                m = re.search(r"<controlURL>(.*?)</controlURL>", block, re.S | re.I)
                if m:
                    return urllib.parse.urljoin(desc_url, m.group(1).strip()), svc
    return None, None


def external_ip(ctrl, svc):
    body = (
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        "<s:Body>"
        f'<u:GetExternalIPAddress xmlns:u="{svc}"/>'
        "</s:Body></s:Envelope>"
    ).encode()
    req = urllib.request.Request(
        ctrl,
        data=body,
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": f'"{svc}#GetExternalIPAddress"',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            xml = r.read().decode("utf-8", "replace")
    except Exception:
        return None
    m = re.search(r"<NewExternalIPAddress>(.*?)</NewExternalIPAddress>", xml, re.S | re.I)
    return m.group(1).strip() if m else None


def main():
    for loc in discover():
        ctrl, svc = control_url(loc)
        if not ctrl:
            continue
        ip = external_ip(ctrl, svc)
        if ip:
            print(ip)
            return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)
