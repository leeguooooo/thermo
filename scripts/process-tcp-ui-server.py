"""Owned loopback-only child for the native process-detail acceptance window."""
from pathlib import Path
import json
import os
import signal
import socket
import sys
import time

root = Path(sys.argv[1]).resolve()
mode = sys.argv[2]
assert root.name.startswith('thermo-process-tcp-ui-') and (root / '.thermo-process-tcp-ui').is_file()
assert mode in ('target', 'sentinel')
parent = os.getppid()
stopping = False


def stop(_signal, _frame):
    global stopping
    stopping = True


def publish(state, endpoints):
    temporary = root / (mode + '.temporary.json')
    temporary.write_text(json.dumps({'pid': os.getpid(), 'state': state, 'endpoints': endpoints}, sort_keys=True))
    temporary.replace(root / (mode + '.json'))


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
sockets = []
endpoints = []
try:
    for family, address, label in [(socket.AF_INET, '127.0.0.1', 'IPv4'), (socket.AF_INET6, '::1', 'IPv6')]:
        listener = socket.socket(family, socket.SOCK_STREAM)
        sockets.append(listener)
        if family == socket.AF_INET6:
            listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        listener.bind((address, 0))
        listener.listen(2)
        endpoints.append({'address': address, 'port': listener.getsockname()[1], 'family': label})
    publish('listening', endpoints)
    deadline = time.monotonic() + 600
    closed = False
    while not stopping and os.getppid() == parent and time.monotonic() < deadline:
        if not closed and (root / ('close-' + mode)).exists():
            for listener in sockets:
                listener.close()
            sockets.clear()
            closed = True
            publish('closed', [])
        time.sleep(0.02)
finally:
    for listener in sockets:
        listener.close()
    publish('stopped', [])
