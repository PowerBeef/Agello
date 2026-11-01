"""Which files are APFS clones of the models in a reference folder (they share its disk blocks).

Usage: python3 -I scripts/lib/clones.py <reference folder> <file>...
Prints one line per file: "clone" or "own", its size in KB, and its path, separated by tabs.
A clone made with `cp -c` costs no space until one side is rewritten; du counts it in full.
"""

import fcntl
import os
import struct
import sys

F_LOG2PHYS_EXT = 65  # sys/fcntl.h: a file offset to its device offset


def blocks(path):
  """Device offsets of a file's first, middle and last block: equal for a file and its clone."""
  size = os.path.getsize(path)
  fd = os.open(path, os.O_RDONLY)
  try:
    found = []
    for offset in (0, (size // 2) & ~4095, max(size - 1, 0) & ~4095):
      # struct log2phys is packed to 4 bytes: flags, contiguous bytes, then the offset in and out.
      out = fcntl.fcntl(fd, F_LOG2PHYS_EXT, struct.pack("<Iqq", 0, 4096, offset))
      found.append(struct.unpack("<Iqq", out)[2])
    return tuple(found)
  except OSError:
    return None
  finally:
    os.close(fd)


def main():
  reference, files = sys.argv[1], sys.argv[2:]
  known = set()
  for folder, _, names in os.walk(reference):
    for name in names:
      if name.endswith(".litertlm"):
        key = blocks(os.path.join(folder, name))
        if key:
          known.add(key)
  for path in files:
    key = blocks(path)
    kind = "clone" if key and key in known else "own"
    print(f"{kind}\t{os.path.getsize(path) // 1024}\t{path}")


main()
