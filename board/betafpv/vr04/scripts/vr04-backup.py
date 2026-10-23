#!/usr/bin/env python3
"""
Full NAND backup of a BetaFPV VR04 goggle (P1 GND, Artosyn PROXIMA 9311)
from its running STOCK firmware, before anything else touches the unit.

  vr04-backup.py DIR [--serial /dev/ttyUSB0] [--host-ip 192.168.3.204]
                     [--tools DIR] [--tftp-root /srv/tftp]

Reads only. Stock has no nanddump and no nc, so the prebuilt glibc aarch64
nanddump + socat (betafpv/rev, --tools) are fetched with the stock busybox
tftp from this host's TFTP server into the goggle's /tmp. Commands go over
the stock root shell on the serial console (1152000 baud); the data goes
over the stock RNDIS link (goggle 192.168.3.100 -> this host), one TCP
connection per dump, md5 taken on the goggle in the same pass and compared
with this end's.

DIR gets the layout of the P1 backups (devices/ar9311_artosyn_artlynk-p1/
scripts/ar9311-install.py backup), so the installer and sysupgrade checks
accept it:
  <partition>.bin     mtd1..mtd20, nanddump --bb=skipbad --omitoob
  mtd0-full-oob.bin   the whole chip with OOB, bad blocks skipped
  factory-files.tar   /factory as the stock system mounts it
  info/*.txt          cmdline, dmesg, /proc/mtd, hw config, versions
  MD5SUMS, manifest.json
usr_data and usr_log are mounted read-write by stock, so their data can
change between the partition dump and the whole-chip one; everything else
must be identical in both.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import sys
import threading
import time

import serial

# mtd1..mtd20 (mtd0 is the whole 128 MiB chip), as the stock GPT lays them out.
LAYOUT = [
    ("spl0", 0x40000), ("spl1", 0x40000), ("spl2", 0x40000), ("spl3", 0x40000),
    ("gpt0", 0x40000), ("gpt1", 0x40000), ("vendor", 0x80000), ("factory", 0x600000),
    ("env0", 0x60000), ("env1", 0x60000), ("uboot0", 0xc0000), ("uboot1", 0xc0000),
    ("kernel0", 0x600000), ("kernel1", 0x600000), ("dtb0", 0x60000), ("dtb1", 0x60000),
    ("userapp0", 0x2d00000), ("userapp1", 0x2d00000), ("usr_data", 0x600000), ("usr_log", 0x600000),
]
CHIP_SIZE = 0x8000000
PAGE, OOB, BLOCK = 2048, 128, 0x20000
STAGE = "/tmp/vr04"
TFTP_SUBDIR = "vr04-backup"
DEFAULT_TOOLS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "../../../../../betafpv/rev"))

# Runs on the goggle: nanddump DEV into HOST:PORT, md5 of the same stream
# through a fifo. No pipefail in the stock ash, so the exit codes go to files.
DUMP_SH = """#!/bin/sh
# dump.sh DEV OOBOPT HOST PORT
d=%s
rm -f $d/f $d/f.md5 $d/f.rc $d/f.log
mkfifo $d/f
md5sum < $d/f > $d/f.md5 &
p=$!
{ $d/nanddump --bb=skipbad $2 $1 2> $d/f.log; echo $? > $d/f.rc; } | tee $d/f | $d/socat -u - TCP:$3:$4
s=$?
wait $p
echo "RC=$(cat $d/f.rc) SRC=$s MD5=$(cut -d' ' -f1 $d/f.md5)"
cat $d/f.log
rm -f $d/f $d/f.md5 $d/f.rc $d/f.log
""" % STAGE

# ---------------------------------------------------------------- console


class Console:
    """The stock root shell on the serial console. Each command is framed by
    two markers the shell prints; the echoed command line itself cannot
    contain them (the markers are split by quotes there)."""

    def __init__(self, port, baud=1152000):
        self.s = serial.Serial(port, baud, timeout=0.2)
        self.n = 0

    def sync(self):
        self.s.write(b"\n\n")  # askfirst ("Please press Enter"), a half-typed line
        time.sleep(1)
        r = self.run("echo ok", timeout=5)
        if r.strip() != "ok":
            sys.exit(f"no shell on the serial console (got {r!r})")

    def run(self, cmd, timeout=30, check=False):
        self.n += 1
        start, end = f"__VR04_{self.n}_S__", f"__VR04_{self.n}_E__"
        q = lambda m: m[:6] + '""' + m[6:]
        self.s.reset_input_buffer()
        self.s.write(f"echo {q(start)}; {cmd}; echo {q(end)}$?\n".encode())
        buf, t0 = b"", time.time()
        pat = re.compile(re.escape(start.encode()) + rb"\r?\n(.*?)" + re.escape(end.encode()) + rb"(\d+)",
                         re.S)
        while time.time() - t0 < timeout:
            buf += self.s.read(65536)
            m = pat.search(buf)
            if m:
                out = m.group(1).decode(errors="replace").replace("\r\n", "\n")
                if check and m.group(2) != b"0":
                    sys.exit(f"goggle: `{cmd}` failed ({m.group(2).decode()}):\n{out}")
                return out
        sys.exit(f"goggle: `{cmd}` did not finish within {timeout} s")


# ---------------------------------------------------------------- transfer


class Receiver(threading.Thread):
    """Accepts one connection on host_ip and streams it into path."""

    def __init__(self, host_ip, path, total=None, label=""):
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.bind((host_ip, 0))
        self.sock.listen(1)
        self.sock.settimeout(60)
        self.port = self.sock.getsockname()[1]
        self.path, self.total, self.label = path, total, label
        self.md5, self.bytes, self.error = None, 0, None

    def run(self):
        try:
            conn, _ = self.sock.accept()
            h, last = hashlib.md5(), 0
            with conn, open(self.path, "wb") as f:
                conn.settimeout(120)
                while True:
                    d = conn.recv(1 << 20)
                    if not d:
                        break
                    f.write(d)
                    h.update(d)
                    self.bytes += len(d)
                    if self.total and self.bytes - last >= 8 << 20:
                        last = self.bytes
                        print(f"\r  {self.label:9s} {100 * self.bytes // self.total:3d}%", end="", flush=True)
            self.md5 = h.hexdigest()
        except Exception as e:
            self.error = e
        finally:
            self.sock.close()


def dump(con, host_ip, dev, oobopt, path, total, label, timeout):
    rx = Receiver(host_ip, path, total, label)
    rx.start()
    out = con.run(f"sh {STAGE}/dump.sh {dev} {oobopt} {host_ip} {rx.port}", timeout=timeout)
    rx.join(30)
    if total:
        print("\r", end="")
    m = re.search(r"RC=(\d+) SRC=(\d+) MD5=([0-9a-f]{32})", out)
    if rx.error or not m or m.group(1) != "0" or m.group(2) != "0":
        sys.exit(f"dump of {dev} failed (receiver: {rx.error}):\n{out}")
    if rx.md5 != m.group(3):
        sys.exit(f"{path}: md5 {rx.md5} here, {m.group(3)} on the goggle")
    log = out[m.end():].strip()
    stats = {k: int(v) for k, v in re.findall(r"(ECC failed|ECC corrected|Number of bad blocks"
                                               r"|Number of bbt blocks): (\d+)", log)}
    return rx.md5, rx.bytes, stats, log


def fetch_stream(con, host_ip, cmd, path, timeout=120):
    """Run `cmd | socat` on the goggle into path; returns (md5, bytes)."""
    rx = Receiver(host_ip, path)
    rx.start()
    out = con.run(f"{cmd} | {STAGE}/socat -u - TCP:{host_ip}:{rx.port}; echo SRC=$?", timeout=timeout)
    rx.join(30)
    if rx.error or "SRC=0" not in out:
        sys.exit(f"`{cmd}` transfer failed (receiver: {rx.error}):\n{out}")
    return rx.md5, rx.bytes


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- GPT


def gpt_active(path):
    """{pair: 0|1} from a gpt0/gpt1 dump (header at 0x200, entries at 0x400 in
    both the primary and the backup form), None if it holds no GPT."""
    d = open(path, "rb").read()
    if d[0x200:0x208] != b"EFI PART":
        return None
    n, esz = struct.unpack_from("<II", d, 0x200 + 80)
    active = {}
    for i in range(n):
        e = d[0x400 + i * esz:0x400 + (i + 1) * esz]
        if len(e) < 128 or e[:16] == bytes(16):
            continue
        attr = struct.unpack_from("<Q", e, 48)[0]
        name = e[56:128].decode("utf-16-le").split("\0")[0]
        if attr >> 47 & 1 and name[-1:] in "01":
            active[name[:-1]] = int(name[-1])
    return active


# ---------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("--serial", default="/dev/ttyUSB0")
    ap.add_argument("--host-ip", default="192.168.3.204", help="this host on the RNDIS link")
    ap.add_argument("--tftp-root", default="/srv/tftp")
    ap.add_argument("--tools", default=DEFAULT_TOOLS,
                    help="dir with mtd-utils/nanddump and install/bin/socat1 (glibc aarch64)")
    a = ap.parse_args()

    if os.path.exists(a.dir) and os.listdir(a.dir):
        sys.exit(f"{a.dir} exists and is not empty")
    tools = {"nanddump": os.path.join(a.tools, "mtd-utils/nanddump"),
             "socat": os.path.join(a.tools, "install/bin/socat1")}
    for t in tools.values():
        if not os.path.isfile(t):
            sys.exit(f"missing {t}")

    con = Console(a.serial)
    con.sync()

    # the unit: stock layout, which slot runs
    proc_mtd = con.run("cat /proc/mtd", check=True)
    parts = {}
    for line in proc_mtd.splitlines()[1:]:
        m = re.match(r'mtd(\d+): ([0-9a-f]+) [0-9a-f]+ "([^"]+)"', line)
        if m:
            parts[int(m.group(1))] = (m.group(3), int(m.group(2), 16))
    want = {i + 1: p for i, p in enumerate(LAYOUT)}
    if parts.get(0, (None, 0))[1] != CHIP_SIZE or {k: v for k, v in parts.items() if k} != want:
        sys.exit("goggle: /proc/mtd is not the P1 layout:\n" + proc_mtd)
    missing = con.run("for t in tftp md5sum mkfifo tee cut tar; do which $t >/dev/null || echo $t; done").split()
    if missing:
        sys.exit(f"goggle: no {' '.join(missing)} in the stock system")
    cmdline = con.run("cat /proc/cmdline", check=True).strip()
    m = re.search(r"\bubi\.mtd=(\d+)", cmdline)
    running = {17: 0, 18: 1}.get(int(m.group(1))) if m else None

    # tools into the goggle's /tmp over TFTP
    tdir = os.path.join(a.tftp_root, TFTP_SUBDIR)
    os.makedirs(tdir, exist_ok=True)
    for name, src in tools.items():
        shutil.copy(src, os.path.join(tdir, name))
    with open(os.path.join(tdir, "dump.sh"), "w") as f:
        f.write(DUMP_SH)
    con.run(f"rm -rf {STAGE}; mkdir -p {STAGE}", check=True)
    for name in (*tools, "dump.sh"):
        con.run(f"tftp -g -b 1428 -r {TFTP_SUBDIR}/{name} -l {STAGE}/{name} {a.host_ip}",
                timeout=60, check=True)
        there = con.run(f"md5sum {STAGE}/{name}", check=True).split()[0]
        if there != md5_file(os.path.join(tdir, name)):
            sys.exit(f"{name}: TFTP copy damaged ({there})")
    con.run(f"chmod +x {STAGE}/nanddump {STAGE}/socat", check=True)
    print("tools:", con.run(f"{STAGE}/nanddump --version | head -1; {STAGE}/socat -V | grep 'socat version'",
                             check=True).strip().replace("\n", ", "))

    os.makedirs(os.path.join(a.dir, "info"), exist_ok=True)
    info = {
        "uname": "uname -a", "cmdline": "cat /proc/cmdline", "proc_mtd": "cat /proc/mtd",
        "dmesg": "dmesg", "cpuinfo": "cat /proc/cpuinfo", "meminfo": "cat /proc/meminfo",
        "model": "cat /proc/device-tree/model; echo", "lsmod": "lsmod", "mounts": "cat /proc/mounts",
        "factory_ls": "ls -la /factory", "hw_ver": "cat /factory/hw_ver.txt",
        "cfg_lowdelay_hw": "cat /factory/cfg_lowdelay_hw.json",
        "ar8030_pwr": "cat /factory/ar8030_pwr.json", "sdk_version": "cat /etc/sdk.version",
        "buildtime": "cat /usr/usrdata/buildtime", "ps": "ps w",
        "mtd_sysfs": "for d in /sys/class/mtd/mtd*; do [ -f $d/name ] && "
                     "echo \"$(basename $d) $(cat $d/name) bad=$(cat $d/bad_blocks 2>/dev/null)"
                     " ecc_failures=$(cat $d/ecc_failures 2>/dev/null)"
                     " corrected=$(cat $d/corrected_bits 2>/dev/null)\"; done",
    }
    for name, cmd in info.items():
        with open(os.path.join(a.dir, "info", f"{name}.txt"), "w") as f:
            f.write(con.run(cmd, timeout=60))

    manifest = {
        "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "source": "running stock firmware, nanddump + socat staged in /tmp over TFTP",
        "proc_mtd": proc_mtd,
        "cmdline": cmdline,
        "running_slot": running,
        "format": "<partition>.bin: nanddump --bb=skipbad --omitoob (data, bad blocks "
                  "skipped); mtd0-full-oob.bin: the whole chip with OOB, bad blocks skipped",
        "partitions": {},
    }
    sums = []
    for num in range(1, 21):
        name, size = parts[num]
        path = os.path.join(a.dir, f"{name}.bin")
        md5, got, stats, log = dump(con, a.host_ip, f"/dev/mtd{num}", "--omitoob", path, size, name,
                                    timeout=600)
        bad = stats.get("Number of bad blocks", 0)
        if got != size - bad * BLOCK:
            sys.exit(f"{name}: {got} bytes, expected {size - bad * BLOCK} ({bad} bad blocks)\n{log}")
        manifest["partitions"][name] = {"mtd": num, "size": size, "bytes": got, "md5": md5, **stats}
        sums.append(f"{md5}  {name}.bin")
        print(f"  {name:9s} {got // 1024:6d} KiB  bad {bad}  ECC corrected "
              f"{stats.get('ECC corrected', '?')} failed {stats.get('ECC failed', '?')}  {md5}")

    # The stock kernel (4.9) keeps the bad block count on the partitions, the
    # whole chip's says 0: the dump must skip exactly the partitions' bad blocks
    # (they cover the chip up to 0x7d00000; one more could sit in the rest).
    path = os.path.join(a.dir, "mtd0-full-oob.bin")
    md5, got, stats, log = dump(con, a.host_ip, "/dev/mtd0", "--oob", path,
                                CHIP_SIZE // PAGE * (PAGE + OOB), "mtd0", timeout=3600)
    bad = sum(p.get("Number of bad blocks", 0) for p in manifest["partitions"].values())
    skipped, rest = divmod(CHIP_SIZE - got // (PAGE + OOB) * PAGE, BLOCK)
    if got % (PAGE + OOB) or rest or skipped < bad:
        sys.exit(f"mtd0: {got} bytes, does not match the partitions' {bad} bad blocks\n{log}")
    manifest["mtd0-full-oob.bin"] = {"bytes": got, "md5": md5, "skipped_blocks": skipped, **stats}
    sums.append(f"{md5}  mtd0-full-oob.bin")
    print(f"  mtd0 (whole chip, with OOB)  {skipped} bad blocks skipped ({bad} in the partitions)  "
          f"ECC corrected {stats.get('ECC corrected', '?')} failed {stats.get('ECC failed', '?')}  {md5}")

    md5, _ = fetch_stream(con, a.host_ip, "tar -cf - -C / factory", os.path.join(a.dir, "factory-files.tar"))
    sums.append(f"{md5}  factory-files.tar")

    # cross-checks: the factory partition read the plain way (the unit's
    # identity for the installer), and the GPT
    manifest["factory_cat_md5"] = con.run("md5sum /dev/mtd8", timeout=60, check=True).split()[0]
    manifest["gpt"] = {g: gpt_active(os.path.join(a.dir, f"{g}.bin")) for g in ("gpt0", "gpt1")}

    con.run(f"rm -rf {STAGE}")
    shutil.rmtree(tdir, ignore_errors=True)

    with open(os.path.join(a.dir, "MD5SUMS"), "w") as f:
        f.write("\n".join(sums) + "\n")
    with open(os.path.join(a.dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    fac = manifest["partitions"]["factory"]
    print(f"factory: nanddump md5 {fac['md5']}, cat /dev/mtd8 md5 {manifest['factory_cat_md5']}")
    for g, act in manifest["gpt"].items():
        print(f"{g}: " + ("no GPT" if act is None else
                          " ".join(f"{k}{v}" for k, v in sorted(act.items()))))
    print(f"backup complete: {a.dir} (running slot {'AB'[running] if running is not None else '?'})")


if __name__ == "__main__":
    main()
