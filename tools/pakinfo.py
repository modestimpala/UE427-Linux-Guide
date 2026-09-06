#!/usr/bin/env python3
"""Print a UE4 .pak file's version and mount point.

The mount point is the prefix the shipped game resolves entries against, so it is
the single most useful thing to check when a pak "does nothing" in game. It lives
at the start of the pak index, which the footer points at - do not grep for
"../../../" in the raw file, because cooked assets contain such strings too and
you will read the wrong one.

Usage: pakinfo.py MyMod.pak
"""

import struct
import sys

# FPakInfo::PakFile_Magic
PAK_MAGIC = 0x5A6F12E1

# The footer's size varies with pak version (the compression-method name table
# grew over time), so find the magic instead of assuming a fixed offset.
FOOTER_SEARCH_BYTES = 256


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    path = sys.argv[1]
    with open(path, "rb") as handle:
        data = handle.read()

    tail = data[-FOOTER_SEARCH_BYTES:]
    found = tail.rfind(struct.pack("<I", PAK_MAGIC))
    if found < 0:
        print(f"{path}: no pak footer magic found (not a .pak?)", file=sys.stderr)
        return 1

    base = len(data) - len(tail) + found
    version, index_offset, index_size = struct.unpack_from("<iqq", data, base + 4)

    length = struct.unpack_from("<i", data, index_offset)[0]
    mount = data[index_offset + 4: index_offset + 4 + length - 1].decode("utf-8", "replace")

    print(f"file:        {path}")
    print(f"version:     {version}")          # 11 for UE4.27
    print(f"index:       offset={index_offset} size={index_size}")
    print(f"mount point: {mount}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
