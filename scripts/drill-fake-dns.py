#!/usr/bin/env python3
# AI Warden - phase L drill helper (verify-isolation.sh). NOT part of any image.
#
# A logging DNS server: prints "QUERY <name> type <n> from <ip>" for every
# query it receives and answers NXDOMAIN - except one test name, which gets a
# LAN address (10.1.2.3) so the drill can check that an allowlisted name that
# resolves into the LAN is still refused. Pointed at by `dns_nameservers` in a
# copy of the proxy's squid.conf, it shows which names the proxy resolved.
import socket

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 53))
print("fakedns listening", flush=True)
while True:
    data, addr = s.recvfrom(2048)
    labels, i = [], 12
    try:
        while data[i]:
            n = data[i]
            labels.append(data[i + 1 : i + 1 + n].decode("ascii", "replace"))
            i += n + 1
        qtype = int.from_bytes(data[i + 1 : i + 3], "big")
    except IndexError:
        qtype = -1
    qname = ".".join(labels).lower()
    print("QUERY", qname, "type", qtype, "from", addr[0], flush=True)
    reply = bytearray(data[:12])
    reply[2] = 0x81  # QR=1, RD=1
    reply[6:12] = bytes(6)  # no answer/authority/additional records
    question = data[12 : i + 5]
    if qname == "rebind.warden-test.example" and qtype == 1:
        # one A record: the LAN address 10.1.2.3 (a DNS-rebinding answer)
        reply[3] = 0x80  # RA=1, NOERROR
        reply[7] = 1  # ANCOUNT=1
        rr = bytes([0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 1, 2, 3])
        s.sendto(bytes(reply) + question + rr, addr)
        continue
    reply[3] = 0x83  # RA=1, RCODE=3 NXDOMAIN
    s.sendto(bytes(reply) + question, addr)
