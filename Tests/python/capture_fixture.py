"""Captures a golden test-pattern trace from whichever liblsl `pylsl` loads.

The two samples an outlet sends immediately after the handshake are a hard
interoperability gate (SCOPE.md §2.2), so the bytes of a real outlet are committed and
replayed by `swift test` — no network, no Python, on every run. One fixture per liblsl
release is the durable form of the release interop matrix (ROADMAP step 9).

    cd Tests/python
    uv run python capture_fixture.py                       # whatever pylsl loads
    PYLSL_LIB=/path/to/liblsl.dylib uv run python capture_fixture.py

Writes `Tests/LSLCoreTests/Fixtures/test-patterns-liblsl-<version>.json`, refusing to
overwrite an existing one: a changed fixture must be explainable (TESTING.md).

The request written here is built from SCOPE.md §2.2 alone, like the L1 mocks, so a
capture cannot inherit a misreading from the Swift implementation.
"""

from __future__ import annotations

import datetime
import json
import re
import socket
import sys
import time
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "LSLCoreTests" / "Fixtures"
CHANNELS = 5
FORMATS = ["float32", "double64", "string", "int32", "int16", "int8", "int64"]
VALUE_SIZE = {"float32": 4, "double64": 8, "string": 0,
              "int32": 4, "int16": 2, "int8": 1, "int64": 8}
TERMINATOR = b"\r\n\r\n"


def request(uid: str, fmt: str) -> bytes:
    """An `LSL:streamfeed/110` request, per SCOPE.md §2.2."""
    lines = [
        f"LSL:streamfeed/110 {uid}",
        "Native-Byte-Order: 1234",
        "Endian-Performance: 0",
        "Has-IEEE754-Floats: 1",
        f"Supports-Subnormals: {1 if fmt in ('float32', 'double64') else 0}",
        f"Value-Size: {VALUE_SIZE[fmt]}",
        "Data-Protocol-Version: 110",
        "Max-Buffer-Length: 100",
        "Max-Chunk-Length: 0",
        "Hostname: capture",
        "Source-Id: ",
        "Session-Id: default",
        "",
        "",
    ]
    return "\r\n".join(lines).encode()


def capture(pylsl, fmt: str) -> tuple[str, str]:
    """Returns (response header, hex of the two test-pattern records) for one format."""
    name = f"Capture{fmt}"
    info = pylsl.StreamInfo(name, "Capture", CHANNELS, 100.0, fmt, f"capture-{fmt}")
    outlet = pylsl.StreamOutlet(info)

    deadline = time.time() + 10
    resolved = None
    while time.time() < deadline and resolved is None:
        resolved = next((s for s in pylsl.resolve_streams(1.0) if s.name() == name), None)
    assert resolved is not None, f"could not resolve the {fmt} capture outlet"

    xml = resolved.as_xml()
    port = int(re.search(r"<v4data_port>(\d+)</v4data_port>", xml).group(1))
    uid = re.search(r"<uid>(.*?)</uid>", xml).group(1)

    with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
        connection.sendall(request(uid, fmt))
        received = b""
        while TERMINATOR not in received:
            block = connection.recv(4096)
            assert block, "the outlet closed before completing the handshake"
            received += block
        header, _, body = received.partition(TERMINATOR)

        # The outlet sends exactly two records and then waits for data to be pushed, so
        # a short read here is the end of the trace, not a truncation.
        connection.settimeout(2.0)
        try:
            while True:
                block = connection.recv(4096)
                if not block:
                    break
                body += block
        except TimeoutError:
            pass

    del outlet
    return header.decode(), body.hex()


def main() -> int:
    import pylsl

    version = pylsl.library_info().split("git:", 1)[1].split("/", 1)[0].lstrip("v")
    destination = FIXTURES / f"test-patterns-liblsl-{version}.json"
    if destination.exists():
        print(f"{destination.name} already exists; delete it deliberately to re-capture")
        return 1

    traces = {}
    header = None
    for fmt in FORMATS:
        header, traces[fmt] = capture(pylsl, fmt)
        print(f"captured {fmt}: {len(traces[fmt]) // 2} bytes", flush=True)

    # The UID differs per outlet, so the committed header is the last one captured; only
    # its shape and the constant fields are asserted on.
    document = {
        "libraryVersion": version,
        "capturedOn": datetime.date.today().isoformat(),
        "channelCount": CHANNELS,
        "provenance": (
            "Captured from a live liblsl outlet over TCP by Tests/python/capture_fixture.py: "
            "a real LSL:streamfeed/110 handshake followed by the two test-pattern samples "
            "the outlet always sends. Byte order 1234 (the capture host is little-endian); "
            "big-endian coverage is by construction in the codec tests and by mock peers at L1."
        ),
        "responseHeader": header,
        "testPatterns": traces,
    }
    destination.write_text(json.dumps(document, indent=2) + "\n")
    print(f"wrote {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
