#!/usr/bin/env python3
"""
Build an NTX-format raw image chunk: a 512-byte magic+size header sector
immediately followed by the payload, matching board/freescale/common/ntx_comm.c's
_load_ntxkernel()/_load_ntxdtb() expectations (Kobo/Netronix U-Boot).

Header format (within the 512-byte sector preceding the payload):
  bytes 496-499: magic 0xFF 0xF5 0xAF 0xFF
  bytes 504-507: payload size in bytes, little-endian uint32

Usage: mk_ntx_image.py <payload-file> <output-file>
Writes: [512-byte header][payload], ready to dd at sector (OFFSET-1).
"""
import sys
import struct

MAGIC = bytes([0xFF, 0xF5, 0xAF, 0xFF])

def build(payload_path, out_path):
    with open(payload_path, 'rb') as f:
        payload = f.read()

    header = bytearray(512)
    header[496:500] = MAGIC
    header[504:508] = struct.pack('<I', len(payload))

    with open(out_path, 'wb') as f:
        f.write(header)
        f.write(payload)

    print(f"{payload_path}: {len(payload)} bytes ({len(payload)/1024/1024:.2f} MiB), "
          f"header+payload written to {out_path}")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    build(sys.argv[1], sys.argv[2])
