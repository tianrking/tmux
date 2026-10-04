#!/bin/sh
PATH=/bin:/usr/bin
export PATH
python3 - "$1" <<'PY'
import base64
import os
import select
import subprocess
import sys
import tempfile
import time

tmux = os.path.abspath(sys.argv[1])
failures = []
with tempfile.TemporaryDirectory(prefix="tmux-osc52-") as directory:
    socket = os.path.join(directory, "socket")
    fifo = os.path.join(directory, "input")
    os.mkfifo(fifo)
    server = [tmux, "-S", socket, "-f/dev/null"]
    def run(*args):
        return subprocess.check_output(server + list(args))
    run("new-session", "-d", "-s", "probe", "-x", "80", "-y", "24",
        "exec cat '%s'" % fifo)
    writer = os.open(fifo, os.O_RDWR)
    run("set-option", "-s", "set-clipboard", "on")
    run("set-option", "-as", "terminal-features", "xterm*:clipboard")
    run("set-option", "-as", "terminal-overrides",
        r"xterm*:Ms=\E]52;%p1%s;%p2%s\007")
    pid, fd = os.forkpty()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(tmux, server + ["attach-session", "-t", "probe"])
    os.set_blocking(fd, False)
    def read(duration):
        data = b""
        until = time.monotonic() + duration
        while time.monotonic() < until:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    data += os.read(fd, 65536)
                except BlockingIOError:
                    pass
        return data
    try:
        read(1)
        clients = run("list-clients", "-F", "#{client_termfeatures}")
        if b"clipboard" not in clients:
            raise AssertionError("real PTY client lacks clipboard capability")
        cases = [
            ("plain", b"", b""),
            ("issue-adjacent", b"\033[?2026l", b"\033[?2026h"),
            ("frame-adjacent", b"\033[?2026hFRAME\033[?2026l", b""),
        ]
        for name, before, after in cases:
            os.write(writer, b"\033[?2026l")
            read(0.2)
            payload = ("probe-" + name).encode()
            encoded = base64.b64encode(payload)
            packet = before + b"\033]52;c;" + encoded + b"\033\\" + after
            if os.write(writer, packet) != len(packet):
                raise AssertionError("short application write")
            data = read(1)
            expected = b"\033]52;c;" + encoded + b"\007"
            buffer = run("show-buffer")
            ok = expected in data and buffer == payload
            print("%s %s terminal=%s buffer=%s raw=%r" %
                (name, "PASS" if ok else "FAIL", expected in data,
                 buffer == payload, data), flush=True)
            if not ok:
                failures.append(name)
    finally:
        subprocess.run(server + ["kill-server"], check=False)
        os.close(writer)
        os.close(fd)
        os.waitpid(pid, 0)
if failures:
    raise AssertionError("original OSC52 failures: " + ", ".join(failures))
PY
