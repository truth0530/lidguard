#!/usr/bin/env python3
"""Double-fork so `osascript` 'do shell script' cannot reap the watchdog."""
import os
import sys

if len(sys.argv) < 3:
    sys.stderr.write("usage: daemonize.py PIDFILE COMMAND [ARGS...]\n")
    sys.exit(2)

pidfile = sys.argv[1]
cmd = sys.argv[2:]

if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)

with open(pidfile, "w") as handle:
    handle.write(str(os.getpid()) + "\n")

os.chdir("/")
try:
    devnull = os.open("/dev/null", os.O_RDWR)
    os.dup2(devnull, 0)
except OSError:
    pass

os.execvp(cmd[0], cmd)
