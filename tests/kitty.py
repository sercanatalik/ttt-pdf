"""Runs ttt in a pty that reports pixel sizes like Ghostty, drives it over --listen,
and prints every Kitty graphics command it sent, grouped by step.

Usage: kitty.py TTT_BIN WORKDIR CONFIG_DIR FILE COLSxROWS CELL_WxCELL_H OUTDIR STEP...
A STEP is an --exec script for ttt, "MARK name" to start a new group, "RESIZE COLSxROWS",
or "SH command" to run a shell command in WORKDIR (to change files while ttt runs).
Transmitted images are written to OUTDIR as PNGs.
"""
import base64
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
import urllib.error
import urllib.request
import zlib

LISTEN = "http://127.0.0.1:4242/exec"


def set_size(fd, cols, rows, cw, ch):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, cols * cw, rows * ch))


def post(script, attempts=1):
    req = urllib.request.Request(LISTEN, data=script.encode(), method="POST")
    for _ in range(attempts):
        try:
            return urllib.request.urlopen(req, timeout=30).read().decode()
        except urllib.error.HTTPError as e:
            raise SystemExit(f"step failed: {script!r}: {e.read().decode().strip()}")
        except OSError:
            time.sleep(0.25)
    raise SystemExit(f"ttt is not answering on {LISTEN}")


def write_png(path, w, h, rgba):
    rows = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(rows)))
        f.write(chunk(b"IEND", b""))


def decode(stream, marks, outdir):
    def group(pos):
        name = "start"
        for n, p in marks:
            if pos >= p:
                name = n
        return name

    pending, count = None, 0
    for m in re.finditer(rb"\x1b_G([^;\x1b]*)(?:;([^\x1b]*))?\x1b\\", stream):
        params = dict(kv.split("=", 1) for kv in m.group(1).decode().split(",") if "=" in kv)
        payload = m.group(2) or b""
        if pending is not None:
            pending["chunks"].append(payload)
            if params.get("m", "0") == "0":
                count += 1
                emit(pending, outdir, count, group)
                pending = None
            continue
        ev = {"pos": m.start(), "params": params, "chunks": [payload]}
        if params.get("a") == "t" and params.get("m") == "1":
            pending = ev
            continue
        if params.get("a") == "t":
            count += 1
        emit(ev, outdir, count, group)
    for name, pos in marks:
        print(f"[{name}] bytes-from={pos}")


def emit(ev, outdir, count, group):
    p = ev["params"]
    a = p.get("a", "t")
    fields = " ".join(f"{k}={v}" for k, v in p.items() if k not in ("q", "m"))
    line = f"[{group(ev['pos'])}] {fields}"
    if a == "t":
        raw = base64.b64decode(b"".join(ev["chunks"]))
        w, h = int(p["s"]), int(p["v"])
        path = os.path.join(outdir, f"img{count}.png")
        write_png(path, w, h, raw)
        line += f" png={os.path.basename(path)}"
    print(line)


def main():
    ttt, workdir, cfg, file, size, cell, outdir = sys.argv[1:8]
    steps = sys.argv[8:]
    cols, rows = map(int, size.split("x"))
    cw, ch = map(int, cell.split("x"))
    os.makedirs(outdir, exist_ok=True)

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(workdir)
        env = dict(os.environ, TERM="xterm-256color", TERM_PROGRAM="ghostty", TTT_CONFIG_DIR=cfg)
        env.pop("TMUX", None)
        os.execve(ttt, [ttt, "--listen", file], env)

    set_size(fd, cols, rows, cw, ch)
    stream = bytearray()
    lock = threading.Lock()
    done = threading.Event()

    # ttt blocks on tty writes when nobody reads, so the pty is drained continuously.
    def reader():
        while not done.is_set():
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                with lock:
                    stream.extend(data)

    threading.Thread(target=reader, daemon=True).start()
    marks = []
    try:
        post("wait 1", attempts=80)
        for step in steps:
            if step.startswith("MARK "):
                time.sleep(0.3)
                with lock:
                    marks.append((step[5:], len(stream)))
            elif step.startswith("SH "):
                subprocess.run(step[3:], shell=True, cwd=workdir, check=True)
            elif step.startswith("RESIZE "):
                cols, rows = map(int, step[7:].split("x"))
                set_size(fd, cols, rows, cw, ch)
                os.kill(pid, signal.SIGWINCH)
                time.sleep(0.5)
            else:
                post(step)
        time.sleep(0.3)
        try:
            post("shutdown")
        except SystemExit:
            pass
    finally:
        done.set()
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    with lock:
        decode(bytes(stream), marks, outdir)


if __name__ == "__main__":
    main()
