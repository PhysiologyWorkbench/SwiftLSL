"""Shared harness plumbing for the L1/L2 test suites.

The `LslTool` fixture is the only way tests run Swift code (TESTING.md): spawn
`lsltool`, block on NDJSON events, terminate with SIGTERM, assert exit 0. No sleeps
are used for synchronisation, ever.
"""

from __future__ import annotations

import gc
import json
import queue
import signal
import subprocess
import sys
import threading
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_EVENT_TIMEOUT = 10.0
DEFAULT_EXIT_TIMEOUT = 10.0


class ToolExited(Exception):
    """Raised when the tool's stdout reaches EOF while an event was expected."""


#: Every `lsltool` still running in the current test.
#:
#: liblsl's `StreamOutlet` destructor blocks while an inlet is still attached, so any
#: fixture that destroys an outlet must take the tools down first, whatever order pytest
#: would otherwise finalise the fixtures in.
_active_tools: list["LslTool"] = []


def terminate_active_tools() -> None:
    for instance in list(_active_tools):
        if instance.process.poll() is None:
            instance.process.send_signal(signal.SIGTERM)
            try:
                instance.wait_exit()
            except subprocess.TimeoutExpired:
                instance.process.kill()
    _active_tools.clear()


class LslTool:
    """A running `lsltool` subprocess with its NDJSON stdout parsed in the background."""

    def __init__(self, binary: str, *args: str) -> None:
        self.args = args
        self.process = subprocess.Popen(
            [binary, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.stderr_lines: list[str] = []
        self._events: queue.Queue = queue.Queue()
        self._readers = [
            threading.Thread(target=self._read_stdout, daemon=True),
            threading.Thread(target=self._read_stderr, daemon=True),
        ]
        for reader in self._readers:
            reader.start()

    def _read_stdout(self) -> None:
        for line in self.process.stdout:
            line = line.strip()
            if not line:
                continue
            self._events.put(json.loads(line))
        self._events.put(None)

    def _read_stderr(self) -> None:
        for line in self.process.stderr:
            self.stderr_lines.append(line.rstrip("\n"))

    def next_event(self, timeout: float = DEFAULT_EVENT_TIMEOUT) -> dict:
        try:
            event = self._events.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError(
                f"no NDJSON event within {timeout}s from lsltool {' '.join(self.args)}"
                f"\nstderr: {self.stderr_text}"
            ) from None
        if event is None:
            raise ToolExited(
                f"lsltool {' '.join(self.args)} closed stdout"
                f"\nstderr: {self.stderr_text}"
            )
        return event

    def wait_for(self, name: str, timeout: float = DEFAULT_EVENT_TIMEOUT) -> dict:
        """Returns the next event named `name`, failing on an `error` event first."""
        while True:
            event = self.next_event(timeout)
            if event["event"] == name:
                return event
            if event["event"] == "error":
                raise AssertionError(f"lsltool reported an error: {event}")

    def drain(self) -> list[dict]:
        """Every event queued so far, without blocking."""
        events = []
        while True:
            try:
                event = self._events.get_nowait()
            except queue.Empty:
                return events
            if event is None:
                return events
            events.append(event)

    @property
    def stderr_text(self) -> str:
        return "\n".join(self.stderr_lines)

    def wait_exit(self, timeout: float = DEFAULT_EXIT_TIMEOUT) -> int:
        return self.process.wait(timeout=timeout)

    def terminate(self, expected_exit: int | None = 0) -> int:
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        try:
            code = self.wait_exit()
        except subprocess.TimeoutExpired:
            self.process.kill()
            raise AssertionError(
                f"lsltool {' '.join(self.args)} ignored SIGTERM"
                f"\nstderr: {self.stderr_text}"
            ) from None
        if expected_exit is not None:
            assert code == expected_exit, (
                f"lsltool {' '.join(self.args)} exited {code}"
                f"\nstderr: {self.stderr_text}"
            )
        return code


def require_pylsl():
    """L2 tests skip with a clear message when liblsl cannot be loaded (TESTING.md)."""
    try:
        import pylsl
    except Exception as error:  # noqa: BLE001 - pylsl raises bare RuntimeError
        pytest.skip(f"pylsl/liblsl unavailable: {error}")
    return pylsl


@pytest.fixture(scope="session")
def lsltool_binary() -> str:
    subprocess.run(
        ["swift", "build", "--product", "lsltool"], cwd=REPO_ROOT, check=True
    )
    path = REPO_ROOT / ".build" / "debug" / "lsltool"
    assert path.exists(), f"lsltool not built at {path}"
    return str(path)


@pytest.fixture
def tool(lsltool_binary):
    """Factory spawning `lsltool` subcommands; every spawned tool is torn down."""
    spawned: list[LslTool] = []

    def spawn(*args: str) -> LslTool:
        instance = LslTool(lsltool_binary, *args)
        spawned.append(instance)
        _active_tools.append(instance)
        return instance

    yield spawn

    terminate_active_tools()


class OutletHandle:
    """Owns a pylsl outlet so a test can destroy it on demand.

    liblsl tears an outlet down in its destructor, so "the outlet goes away" means
    dropping the last reference — which is why the handle, not the outlet, is what the
    fixture retains.
    """

    def __init__(self, instance):
        self._instance = instance

    def __getattr__(self, name):
        if self._instance is None:
            raise AttributeError(f"outlet already stopped (asked for {name})")
        return getattr(self._instance, name)

    def stop(self):
        self._instance = None
        gc.collect()


@pytest.fixture
def outlet():
    """Factory for live pylsl outlets, torn down at the end of the test."""
    pylsl = require_pylsl()
    created: list[OutletHandle] = []

    def make(name, type="Test", channels=1, srate=0.0, fmt="float32", source_id=None, desc=None):
        info = pylsl.StreamInfo(
            name, type, channels, srate,
            getattr(pylsl, f"cf_{fmt}"),
            source_id if source_id is not None else f"src-{name}",
        )
        if desc is not None:
            desc(info.desc())
        handle = OutletHandle(pylsl.StreamOutlet(info))
        created.append(handle)
        return handle

    yield make

    terminate_active_tools()
    for handle in created:
        handle.stop()


def pylsl_endpoint(pylsl, name, timeout=10.0):
    """Resolve an outlet with pylsl and return (host, data_port, uid, info).

    Endpoints for pull/info/timesync tests are obtained on the Python side, which is what
    keeps roadmap steps 3-6 mutually independent (TESTING.md).
    """
    import re
    import time

    deadline = time.time() + timeout
    while time.time() < deadline:
        for info in pylsl.resolve_streams(1.0):
            if info.name() == name:
                xml = info.as_xml()

                def field(tag):
                    match = re.search(rf"<{tag}>(.*?)</{tag}>", xml)
                    return match.group(1) if match else ""

                return ("127.0.0.1", int(field("v4data_port")), field("uid"), info)
    raise AssertionError(f"pylsl could not resolve an outlet named {name}")


@pytest.fixture
def mock_outlet():
    """Factory for scripted mock outlets, closed at the end of the test."""
    from lslmock.outlet import MockOutlet

    created = []

    def make(**kwargs):
        instance = MockOutlet(**kwargs)
        created.append(instance)
        return instance

    yield make

    for instance in created:
        instance.close()


class OutletProcess:
    """A pylsl outlet running in its own process, killable at any moment."""

    def __init__(self, **options):
        arguments = []
        for key, value in options.items():
            arguments += [f"--{key.replace('_', '-')}", str(value)]
        self.process = subprocess.Popen(
            [sys.executable, "-m", "lslmock.outlet_process", *arguments],
            cwd=Path(__file__).parent,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        line = self.process.stdout.readline()
        assert line.strip() == "ready", f"outlet process did not start: {line!r}"

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=10)


@pytest.fixture
def outlet_process():
    """Factory for out-of-process pylsl outlets, killed at the end of the test."""
    require_pylsl()
    created: list[OutletProcess] = []

    def make(**options):
        instance = OutletProcess(**options)
        created.append(instance)
        return instance

    yield make

    for instance in created:
        instance.kill()


@pytest.fixture
def time_server():
    """Factory for mock time servers, closed at the end of the test."""
    from lslmock.timeserver import MockTimeServer

    created = []

    def make(**kwargs):
        instance = MockTimeServer(**kwargs)
        created.append(instance)
        return instance

    yield make

    for instance in created:
        instance.close()


@pytest.fixture
def info_server():
    """Factory for mock LSL:fullinfo servers, closed at the end of the test."""
    from lslmock.inforesponder import MockInfoServer

    created = []

    def make(documents):
        instance = MockInfoServer(documents)
        created.append(instance)
        return instance

    yield make

    for instance in created:
        instance.close()


@pytest.fixture
def responder():
    """Factory for mock discovery responders, closed at the end of the test."""
    from lslmock.responder import MockResponder

    created = []

    def make(**kwargs):
        instance = MockResponder(**kwargs)
        created.append(instance)
        return instance

    yield make

    for instance in created:
        instance.close()
