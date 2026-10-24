#!/usr/bin/env python3
"""
Back up, install and switch the NAND slots of the BetaFPV VR04 goggles (P1
GND, Artosyn PROXIMA 9311) over SSH: to this build RAM-booted through the
stock U-Boot (vr04-uboot-boot.py --mode ram) for a first install or a
rescue, or to an installed OpenIPC. None of it goes through the stock
firmware (its own backup: vr04-backup.py). Port of the OpenIPC builder's
ar9311-install.py (P1 air unit).

  vr04-install.py backup DIR
      every partition (data, bad blocks skipped) and the whole chip (with OOB)
      into DIR, md5 checked on both ends, plus MD5SUMS and manifest.json
  vr04-install.py install IMAGE --backup DIR [--parts=LIST] [--set-password=PASS] [-n]
      an update image -- BetaFPV's stock P1_GND_*.img or this build's
      P1_GND_*_OpenIPC_*.img -- into the slot not running, by the board's own
      /sbin/sysupgrade; the active slot stays as it is
  vr04-install.py activate a|b [--backup DIR]
      the slot the stock SPL boots next (openipc-bsel, the GPT's bit 47);
      gpt0/gpt1 as they were are saved into DIR first
  vr04-install.py status

--dry-run makes install and activate do every check and write nothing.

Slots: the SPL boots whichever of the env/uboot/kernel/dtb/userapp pairs the
GPT marks active and points the kernel at that slot's userapp. An update goes
into the other slot, so the previous firmware stays one "activate" away; stock
comes back from BetaFPV's own image the same way. Activate a slot only after
it booted once through U-Boot (vr04-uboot-boot.py --mode slot-a): the GND
has no tested mask-ROM rescue yet.

Safety: install refuses unless DIR is a backup of this very unit (its factory
partition -- RF calibration, unique per unit -- must match), and checks the
image's SHA-256 here before the upload; sysupgrade checks it again, refuses
an image that would change the SPL or the vendor partition (both slots share
them), and reads every raw partition back.

SSH: one master connection (the root password is asked for once, or your key
is used), every command over it. A fresh RAM boot has no root password and
runs no commands until one is set: log in once (ssh root@HOST) to set it. The
RAM system makes new host keys every boot, so they are not checked.
(sbc-groundstations sets root's password at build time: 12345.)
"""
import argparse
import datetime
import time
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

# mtd1..mtd20 (mtd0 is the whole 128 MiB chip), as the stock GPT and the
# ml-kernel DTS lay them out.
LAYOUT = [
    ("spl0", 0x40000), ("spl1", 0x40000), ("spl2", 0x40000), ("spl3", 0x40000),
    ("gpt0", 0x40000), ("gpt1", 0x40000), ("vendor", 0x80000), ("factory", 0x600000),
    ("env0", 0x60000), ("env1", 0x60000), ("uboot0", 0xc0000), ("uboot1", 0xc0000),
    ("kernel0", 0x600000), ("kernel1", 0x600000), ("dtb0", 0x60000), ("dtb1", 0x60000),
    ("userapp0", 0x2d00000), ("userapp1", 0x2d00000), ("usr_data", 0x600000), ("usr_log", 0x600000),
]
CHIP_SIZE = 0x8000000
IMAGE_MAGIC = 0x4152544F
STAGE = "/tmp/vr04-install.img"
# P1_GND_VR04 up to 2.0.x, IGNORE since 2.1.x; not the VR04 PRO's image
PRODUCTS = (b"P1_GND_VR04", b"IGNORE")
MODEL = "Artosyn Proxima-9311 (BetaFPV VR04 goggle)"

# ---------------------------------------------------------------- SSH


class Board:
    def __init__(self, host):
        self.host = host
        self.tmp = tempfile.mkdtemp(prefix="vr04-install-")
        self.sock = os.path.join(self.tmp, "ssh")
        self.opts = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                     "-o", "LogLevel=ERROR", "-o", "ServerAliveInterval=10", "-S", self.sock]

    def __enter__(self):
        if subprocess.run(["ssh", *self.opts, "-o", "ConnectTimeout=10", "-M", "-fN",
                           f"root@{self.host}"]).returncode:
            shutil.rmtree(self.tmp)
            sys.exit(f"cannot log in to root@{self.host} (RAM-booted with vr04-uboot-boot.py?)")
        r = self.run("echo ok", check=False)
        if r.returncode or r.stdout.strip() != b"ok":
            self.close()
            if b"not been set up" in r.stderr:
                sys.exit(f"the board has no root password yet: log in once (ssh root@{self.host}), "
                         "set one, then run this again")
            sys.exit(f"root@{self.host}: {r.stderr.decode(errors='replace').strip()}")
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        subprocess.run(["ssh", *self.opts, "-O", "exit", f"root@{self.host}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run(self, cmd, check=True, stdin=None, stdout=subprocess.PIPE, input=None):
        r = subprocess.run(["ssh", *self.opts, f"root@{self.host}", cmd],
                           stdin=stdin, input=input, stdout=stdout, stderr=subprocess.PIPE)
        if check and r.returncode:
            sys.exit(f"board: `{cmd}` failed: {r.stderr.decode(errors='replace').strip()}")
        return r

    def text(self, cmd):
        return self.run(cmd).stdout.decode(errors="replace")

    def mtd(self):
        """{name: (num, size)} after checking /proc/mtd is the P1 layout."""
        parts = {}
        for line in self.text("cat /proc/mtd").splitlines()[1:]:
            m = re.match(r'mtd(\d+): ([0-9a-f]+) [0-9a-f]+ "([^"]+)"', line)
            if m:
                parts[int(m.group(1))] = (m.group(3), int(m.group(2), 16))
        want = {i + 1: p for i, p in enumerate(LAYOUT)}
        if parts.get(0, (None, 0))[1] != CHIP_SIZE or {k: v for k, v in parts.items() if k} != want:
            sys.exit("board: /proc/mtd is not the P1/VR04 layout:\n" +
                     "\n".join(f"  mtd{k}: {n} {s:#x}" for k, (n, s) in sorted(parts.items())))
        return {name: (num, size) for num, (name, size) in parts.items() if num}

    def ram_boot(self):
        cmdline = self.text("cat /proc/cmdline")
        return "root=/dev/ram0" in cmdline or "rdinit=" in cmdline and "root=" not in cmdline

    def active_slot(self):
        """0 or 1 from the GPT (gpt0 or gpt1), None if it is unreadable or mixed."""
        r = self.run("openipc-bsel check_flash", check=False)
        m = re.search(rb"bank=([01])", r.stdout)
        return int(m.group(1)) if m else None

    def md5(self, cmd, pipefail=True):
        """md5 of cmd's output. pipefail off where cmd ends in head -c, which
        closes the pipe on a writer that may still be writing."""
        out = self.text(f"{'set -o pipefail; ' if pipefail else ''}{cmd} | md5sum")
        return out.split()[0]

    def bad_blocks(self, num):
        return int(self.text(f"cat /sys/class/mtd/mtd{num}/bad_blocks"))


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


SLOT_NAME = {0: "A", 1: "B"}

# ---------------------------------------------------------------- backup


def dump(board, dev, path, oob):
    """nanddump dev into path; md5 taken on the board in the same pass."""
    fifo = "/tmp/vr04-dump"
    cmd = (f"set -o pipefail; rm -f {fifo}; mkfifo {fifo}; md5sum < {fifo} > {fifo}.md5 & "
           f"nanddump --bb=skipbad {'--oob' if oob else '--omitoob'} -q {dev} | tee {fifo} || exit 1; "
           f"wait; cat {fifo}.md5 >&2; rm -f {fifo} {fifo}.md5")
    with open(path, "wb") as f:
        r = board.run(cmd, check=False, stdout=f)
    m = re.search(rb"\b([0-9a-f]{32})\b", r.stderr)
    if r.returncode or not m:
        sys.exit(f"dump of {dev} failed: {r.stderr.decode(errors='replace').strip()}")
    local = md5_file(path)
    if local != m.group(1).decode():
        sys.exit(f"{path}: md5 {local} here, {m.group(1).decode()} on the board")
    return local


def cmd_backup(a):
    if os.path.exists(a.dir) and os.listdir(a.dir):
        sys.exit(f"{a.dir} exists and is not empty")
    os.makedirs(a.dir, exist_ok=True)
    with Board(a.host) as board:
        parts = board.mtd()
        manifest = {
            "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "proc_mtd": board.text("cat /proc/mtd"),
            "cmdline": board.text("cat /proc/cmdline").strip(),
            "active_slot": board.active_slot(),
            "format": "<partition>.bin: nanddump --bb=skipbad --omitoob (data, bad blocks "
                      "skipped); mtd0-full-oob.bin: the whole chip with OOB, bad blocks skipped",
            "partitions": {},
        }
        sums = []
        for name, (num, size) in sorted(parts.items(), key=lambda p: p[1][0]):
            bad = board.bad_blocks(num)
            md5 = dump(board, f"/dev/mtd{num}", os.path.join(a.dir, f"{name}.bin"), oob=False)
            got = os.path.getsize(os.path.join(a.dir, f"{name}.bin"))
            manifest["partitions"][name] = {"mtd": num, "size": size, "bad_blocks": bad,
                                            "bytes": got, "md5": md5}
            sums.append(f"{md5}  {name}.bin")
            print(f"  {name:9s} {got // 1024:6d} KiB  bad blocks {bad}  {md5}")
        md5 = dump(board, "/dev/mtd0", os.path.join(a.dir, "mtd0-full-oob.bin"), oob=True)
        manifest["mtd0-full-oob.bin"] = {"bad_blocks": board.bad_blocks(0), "md5": md5,
                                         "bytes": os.path.getsize(os.path.join(a.dir, "mtd0-full-oob.bin"))}
        sums.append(f"{md5}  mtd0-full-oob.bin")
        print(f"  mtd0 (whole chip, with OOB)      {md5}")
    with open(os.path.join(a.dir, "MD5SUMS"), "w") as f:
        f.write("\n".join(sums) + "\n")
    with open(os.path.join(a.dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"backup complete: {a.dir} (active slot {SLOT_NAME.get(manifest['active_slot'], '?')})")

# ---------------------------------------------------------------- install


def check_image(path):
    """The image's kind ("OpenIPC" or the stock customer string), after its hash."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 0x220 or struct.unpack_from("<I", data, 0)[0] != IMAGE_MAGIC:
        sys.exit(f"{path}: not an ARTO update image")
    hext = struct.unpack_from("<H", data, 8)[0]
    body = 0x100 + hext + 0x120
    if hashlib.sha256(data[body:]).digest() != data[0x100 + hext:0x100 + hext + 32]:
        sys.exit(f"{path}: SHA-256 mismatch (damaged or truncated)")
    if data[0x80:0xc0].split(b"\0")[0] not in PRODUCTS:
        sys.exit(f"{path}: not a VR04 goggle image")
    return data[0x2c:0x40].split(b"\0")[0].decode(errors="replace")


def cmd_install(a):
    kind = check_image(a.image)
    try:
        backup = dict(reversed(line.split()) for line in open(os.path.join(a.backup, "MD5SUMS")))
    except OSError as e:
        sys.exit(f"--backup {a.backup}: {e}")
    with Board(a.host) as board:
        parts = board.mtd()
        factory = board.md5(f"nanddump --bb=skipbad --omitoob -q /dev/mtd{parts['factory'][0]}")
        if backup.get("factory.bin") != factory:
            sys.exit(f"{a.backup} is not a backup of this unit (factory differs): run backup first")
        print(f"uploading {os.path.basename(a.image)} ({kind}) ...")
        with open(a.image, "rb") as src:
            board.run(f"cat > {STAGE}", stdin=src)
        if board.md5(f"cat {STAGE}") != md5_file(a.image):
            board.run(f"rm -f {STAGE}", check=False)
            sys.exit("the uploaded copy differs")
        opts = [f"--slot={'ab'.index(a.slot)}", "--no-activate", f"--parts={a.parts}"]
        opts += (["-n"] if a.wipe_overlay else []) + (["-d"] if a.dry_run else [])
        if a.set_password:
            opts.append("--set-password='" + a.set_password.replace("'", "'\\''") + "'")
        r = board.run(f"sysupgrade --image={STAGE} {' '.join(opts)}; rc=$?; rm -f {STAGE}; exit $rc",
                      check=False, stdout=None)
        sys.stderr.write(r.stderr.decode(errors="replace"))
        if r.returncode:
            sys.exit("sysupgrade failed")
        if not a.dry_run:
            active = SLOT_NAME.get(board.active_slot(), "?")
            if active == a.slot.upper():
                print(f"slot {active} (the active one) written in place: power-cycle to start it")
            else:
                print(f"slot {a.slot.upper()} written; slot {active} stays active. Boot the new slot "
                      "once through U-Boot (vr04-uboot-boot.py slot-a) before activating it.")

# ---------------------------------------------------------------- activate / status


def dtb_model(blob):
    """The root node's model property of a flattened device tree, or None."""
    if blob[:4] != b"\xd0\x0d\xfe\xed":
        return None
    off_struct, off_strings = struct.unpack_from(">II", blob, 8)
    pos, depth = off_struct, 0
    while pos + 4 <= len(blob):
        token = struct.unpack_from(">I", blob, pos)[0]
        pos += 4
        if token == 1:          # BEGIN_NODE
            end = blob.index(b"\0", pos)
            pos = (end + 4) & ~3
            depth += 1
        elif token == 2:        # END_NODE
            depth -= 1
        elif token == 3:        # PROP
            length, nameoff = struct.unpack_from(">II", blob, pos)
            name = blob[off_strings + nameoff:blob.index(b"\0", off_strings + nameoff)]
            value = blob[pos + 8:pos + 8 + length]
            if depth == 1 and name == b"model":
                return value.rstrip(b"\0").decode(errors="replace")
            pos = (pos + 8 + length + 3) & ~3
        elif token == 4:        # NOP
            continue
        else:
            return None
    return None


def slot_content(board, parts, n):
    """(kernel is OTRA, dtb model, userapp is UBI, dtb has our flash command line)."""
    head = board.run(f"nanddump --bb=skipbad --omitoob -q -l 2048 /dev/mtd{parts[f'kernel{n}'][0]} | head -c 4").stdout
    dtb = board.run(f"nanddump --bb=skipbad --omitoob -q -l 32768 /dev/mtd{parts[f'dtb{n}'][0]}").stdout
    ubi = board.run(f"nanddump --bb=skipbad --omitoob -q -l 2048 /dev/mtd{parts[f'userapp{n}'][0]} | head -c 4").stdout
    return head == b"OTRA", dtb_model(dtb), ubi == b"UBI#", b"root=ubi0:rootfs" in dtb


def save_gpt(board, parts, backup):
    d = os.path.join(backup, f"gpt-before-activate-{time.strftime('%Y%m%d-%H%M%S')}")
    os.makedirs(d)
    for g in ("gpt0", "gpt1"):
        dump(board, f"/dev/mtd{parts[g][0]}", os.path.join(d, f"{g}.bin"), oob=False)
    print(f"gpt0/gpt1 saved in {d}")


def activate(board, parts, slot, force=False, dry_run=False, backup=None):
    # Either firmware: a slot with stock in it is the way back to stock.
    if not force:
        kernel, model, ubi, ours = slot_content(board, parts, slot)
        if not (kernel and model and ubi):
            sys.exit(f"slot {SLOT_NAME[slot]} is not complete (kernel {kernel}, dtb {model!r}, "
                     f"UBI {ubi}): not activated (--force activates it anyway)")
        if ours and model != MODEL:
            sys.exit(f"slot {SLOT_NAME[slot]}'s dtb is {model!r}, not the VR04 goggle's: not activated")
    if dry_run:
        print(f"dry run: slot {SLOT_NAME[slot]} would be activated "
              f"(now: {SLOT_NAME.get(board.active_slot(), '?')})")
        return
    if backup:
        save_gpt(board, parts, backup)
    print(board.text(f"openipc-bsel set {slot}").strip())
    if board.active_slot() != slot:
        sys.exit("the GPT does not read back the new slot -- check it before power-cycling")
    print(f"slot {SLOT_NAME[slot]} is active from the next power-up (power-cycle, not reboot)")


def cmd_activate(a):
    with Board(a.host) as board:
        activate(board, board.mtd(), {"a": 0, "b": 1}[a.slot], a.force, a.dry_run, a.backup)


def cmd_status(a):
    with Board(a.host) as board:
        parts = board.mtd()
        cmdline = board.text("cat /proc/cmdline")
        m = re.search(r"ubi\.mtd=(\d+)", cmdline)
        running = "RAM" if board.ram_boot() else {"17": "slot A", "18": "slot B"}.get(m and m.group(1), "?")
        print(f"running from: {running}")
        print(f"active slot:  {SLOT_NAME.get(board.active_slot(), 'unclear (openipc-bsel check_flash)')}")
        for n in (0, 1):
            kernel, model, ubi, ours = slot_content(board, parts, n)
            print(f"slot {'AB'[n]}: {'OpenIPC' if ours else 'stock or other'}: kernel{n} "
                  f"{'OTRA' if kernel else '-'}, dtb{n} {model!r}, userapp{n} {'UBI' if ubi else '-'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="192.168.3.100", help="the goggles (default %(default)s)")
    ap.add_argument("--dry-run", action="store_true", help="install/activate: check, write nothing")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("backup", help="dump every partition and the whole chip")
    p.add_argument("dir")
    p.set_defaults(fn=cmd_backup)
    p = sub.add_parser("install", help="flash an update image into the slot not running")
    p.add_argument("image", help="P1_GND_*.img (stock) or P1_GND_*_OpenIPC_*.img")
    p.add_argument("--backup", required=True, help="this unit's backup directory")
    p.add_argument("--slot", choices=("a", "b"), default="a",
                   help="refuse unless this is the slot not running (default %(default)s)")
    p.add_argument("--parts", default="kernel,dtb,userapp",
                   help="the slot's partitions to write (default %(default)s)")
    p.add_argument("--set-password", help="root's password on what is flashed")
    p.add_argument("-n", "--wipe-overlay", action="store_true",
                   help="OpenIPC image: start the new slot without the running system's settings")
    p.set_defaults(fn=cmd_install)
    p = sub.add_parser("activate", help="the slot the SPL boots next")
    p.add_argument("slot", choices=("a", "b"))
    p.add_argument("--force", action="store_true", help="activate the slot whatever it holds")
    p.add_argument("--backup", help="save gpt0/gpt1 into this unit's backup directory first")
    p.set_defaults(fn=cmd_activate)
    p = sub.add_parser("status", help="running and active slot, what each slot holds")
    p.set_defaults(fn=cmd_status)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
