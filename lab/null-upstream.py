#!/usr/bin/env python3
"""Answer NXDOMAIN to every DNS query on 127.0.0.1:5353.

During the edge tests and the miss harness the lab server uses this as its
forwarder, so an unblocked query fails fast instead of going upstream. Recursion stays allowed
for private clients, which means the app's blocking handler still runs.
"""
import socket
import struct

HOST = "127.0.0.1"
PORT = 5353


def question_end(data: bytes) -> int:
    index = 12
    while index < len(data):
        length = data[index]
        if length == 0:
            return index + 1 + 4
        if length & 0xC0:
            return index + 2 + 4
        index += 1 + length
    return len(data)


def main() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((HOST, PORT))
    while True:
        try:
            data, address = sock.recvfrom(4096)
        except OSError:
            continue
        if len(data) < 12:
            continue
        end = question_end(data)
        if end > len(data):
            continue
        flags = 0x8183  # QR + RD + RA + NXDOMAIN
        response = data[:2] + struct.pack("!HHHHH", flags, 1, 0, 0, 0) + data[12:end]
        sock.sendto(response, address)


if __name__ == "__main__":
    main()
