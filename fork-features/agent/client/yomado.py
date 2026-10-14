"""yomado agent session client for Python (omp eval code mode).

Protocol and operations: fork-features/agent/README.md, operations.md.

    import sys; sys.path.insert(0, "/Applications/Yomado.app/Contents/Resources/agent")
    import yomado
    ym = yomado.connect(screen="Agent")
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

SOCKET = Path.home() / "Library/Application Support/dev.chekusu.yomado/agent.sock"
# Installed in Yomado.app/Contents/Resources/agent/; the helper is the nested bundle
# Contents/Helpers/YomadoAgent.app.
HELPER = (Path(__file__).resolve().parent / "../../Helpers/YomadoAgent.app/Contents/MacOS/YomadoAgent").resolve()
LOG = Path.home() / "Library/Logs/yomado-agent.log"


class SessionError(Exception):
    """A request failed; `code` is the protocol error code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code


def _try_connect() -> socket.socket | None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(str(SOCKET))
    except OSError:
        sock.close()
        return None
    return sock


class Session:
    """One agent session. Methods mirror the protocol operations and return `result`."""

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._reader = sock.makefile("rb")
        self._next_id = 0
        self._events: list[dict[str, Any]] = []
        self.session: int = 0
        self.screen: dict[str, Any] = {}

    def request(self, op: str, **args: Any) -> dict[str, Any]:
        self._next_id += 1
        payload = {**{k: v for k, v in args.items() if v is not None}, "id": self._next_id, "op": op}
        self._sock.sendall(json.dumps(payload).encode() + b"\n")
        line = self._reader.readline()
        if not line:
            raise SessionError("yomado_unreachable", "the helper closed the session")
        reply = json.loads(line)
        self._events.extend(reply.get("events", []))
        if not reply["ok"]:
            raise SessionError(reply["error"]["code"], reply["error"]["message"])
        return reply["result"]

    def drain_events(self) -> list[dict[str, Any]]:
        """Returns and clears the events received so far."""
        events, self._events = self._events, []
        return events

    def status(self): return self.request("status")
    def windows(self): return self.request("windows")
    def launch(self, app: str): return self.request("launch", app=app)
    def adopt(self, window: int): return self.request("adopt", window=window)
    def capture(self, window: int | None = None, path: str | None = None, pointer: bool | None = None):
        return self.request("capture", window=window, path=path, pointer=pointer)
    def ax(self, window: int): return self.request("ax", window=window)
    def press(self, ref: str, action: str | None = None): return self.request("press", ref=ref, action=action)
    def set(self, ref: str, value: str): return self.request("set", ref=ref, value=value)
    def move(self, window: int, x: float, y: float): return self.request("move", window=window, x=x, y=y)
    def click(self, window: int, x: float | None = None, y: float | None = None, button: str | None = None, count: int | None = None):
        return self.request("click", window=window, x=x, y=y, button=button, count=count)
    def drag(self, window: int, to: dict, from_: dict | None = None, steps: int | None = None):
        return self.request("drag", window=window, to=to, **({"from": from_} if from_ else {}), steps=steps)
    def scroll(self, window: int, dy: int, dx: int | None = None, x: float | None = None, y: float | None = None):
        return self.request("scroll", window=window, dy=dy, dx=dx, x=x, y=y)
    def type(self, window: int, text: str): return self.request("type", window=window, text=text)
    def key(self, window: int, keys: list[str]): return self.request("key", window=window, keys=keys)
    def handoff(self, windows: list[int]): return self.request("handoff", windows=windows)
    def quit(self, app: int | str): return self.request("quit", app=app)

    def close(self) -> None:
        self._reader.close()
        self._sock.close()


def connect(screen: str = "Agent") -> Session:
    """Opens a session on the named yomado screen (started or created if needed)."""
    sock = _try_connect()
    if sock is None:
        if not os.access(HELPER, os.X_OK):
            raise SessionError("yomado_unreachable", f"helper not found at {HELPER}")
        with open(LOG, "ab") as log:
            subprocess.Popen([str(HELPER)], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        for _ in range(50):
            time.sleep(0.1)
            sock = _try_connect()
            if sock:
                break
        if sock is None:
            raise SessionError("yomado_unreachable", f"the helper did not open {SOCKET} within 5 s; see {LOG}")
    session = Session(sock)
    opened = session.request("open", screen=screen)
    session.session = opened["session"]
    session.screen = opened["screen"]
    return session
