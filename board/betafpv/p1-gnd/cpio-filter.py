#!/usr/bin/env python3
"""Copy a newc cpio archive, leaving out the entries a pattern matches.

The RAM boot unpacks its initramfs into a tmpfs of half the RAM the kernel
gets, so post-image.sh builds it from rootfs.cpio without the video stack
(the RAM boot only installs). Patterns are fnmatch globs on the archive path
(no leading "./"); "dir/" drops a directory and everything below it.
Hard-linked files stay or go as a group: newc keeps their data in the last
link only.

usage: cpio-filter.py IN.cpio OUT.cpio PATTERN...
"""
import fnmatch
import sys

HEADER = 110
FIELDS = ("ino", "mode", "uid", "gid", "nlink", "mtime", "filesize",
          "devmajor", "devminor", "rdevmajor", "rdevminor", "namesize", "check")


def pad4(n):
    return (4 - n % 4) % 4


def entries(data):
    off = 0
    while True:
        hdr = data[off:off + HEADER]
        if hdr[:6] not in (b"070701", b"070702"):
            sys.exit(f"cpio-filter: no newc header at offset {off}")
        f = {k: int(hdr[6 + 8 * i:14 + 8 * i], 16) for i, k in enumerate(FIELDS)}
        name_end = off + HEADER + f["namesize"]
        name = data[off + HEADER:name_end - 1].decode()
        data_start = name_end + pad4(HEADER + f["namesize"])
        end = data_start + f["filesize"] + pad4(f["filesize"])
        yield name, f, data[off:end]
        if name == "TRAILER!!!":
            return
        off = end


def dropped(name, patterns):
    for p in patterns:
        if p.endswith("/"):
            if name == p[:-1] or name.startswith(p):
                return True
        elif fnmatch.fnmatchcase(name, p):
            return True
    return False


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst, patterns = sys.argv[1], sys.argv[2], sys.argv[3:]
    data = open(src, "rb").read()
    items = list(entries(data))

    # hard-link groups: keep a group whole unless every link is dropped
    groups = {}
    for name, f, raw in items:
        if f["nlink"] > 1 and (f["mode"] & 0o170000) == 0o100000:
            groups.setdefault(f["ino"], []).append(name)
    keep_group = {ino: not all(dropped(n, patterns) for n in names)
                  for ino, names in groups.items()}

    out = bytearray()
    kept = removed = 0
    for name, f, raw in items:
        if name != "TRAILER!!!":
            if f["ino"] in keep_group and (f["mode"] & 0o170000) == 0o100000 and f["nlink"] > 1:
                drop = not keep_group[f["ino"]]
            else:
                drop = dropped(name, patterns)
            if drop:
                removed += f["filesize"]
                continue
            kept += f["filesize"]
        out += raw
    out += b"\0" * ((512 - len(out) % 512) % 512)
    open(dst, "wb").write(out)
    print(f"cpio-filter: {dst}: {kept // 1024} KB kept, {removed // 1024} KB left out")


if __name__ == "__main__":
    main()
