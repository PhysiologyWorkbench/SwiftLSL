"""A mock outlet's data phase: scripted handshake and sample bytes (SCOPE.md §2.2-2.3).

Written from SCOPE.md alone. It asserts on the inlet's bytes as rigorously as the tests
assert on its own: a handshake request that is malformed must fail here, not silently work.
"""

from __future__ import annotations

import queue
import socket
import struct
import threading
from dataclasses import dataclass, field

TAG_DEDUCED = 1
TAG_TRANSMITTED = 2

TEST_PATTERN_TIMESTAMP = 123456.789
TEST_PATTERN_OFFSETS = (4, 2)

FORMAT_BIAS = {
    "float32": 0,
    "double64": 16777217,
    "int32": 65537,
    "int16": 257,
    "int8": 1,
    "int64": 2147483649,
}
FORMAT_MAX = {"int32": 2**31 - 1, "int16": 2**15 - 1, "int8": 2**7 - 1}
VALUE_SIZE = {
    "float32": 4, "double64": 8, "string": 0,
    "int32": 4, "int16": 2, "int8": 1, "int64": 8,
}
STRUCT_CODE = {
    "float32": "f", "double64": "d",
    "int32": "i", "int16": "h", "int8": "b", "int64": "q",
}


def test_pattern_values(fmt: str, channels: int, offset: int):
    """SCOPE.md §2.2: ±(k + offset + bias), even indices positive."""
    if fmt == "string":
        return [str((k + 10) * (1 if k % 2 == 0 else -1)) for k in range(channels)]
    total = offset + FORMAT_BIAS[fmt]
    values = []
    for k in range(channels):
        value = k + total
        if fmt in FORMAT_MAX:
            value %= FORMAT_MAX[fmt]
        values.append(value if k % 2 == 0 else -value)
    return values


def encode_sample(fmt: str, values, timestamp, byte_order="<"):
    body = bytearray()
    if timestamp is None:
        body.append(TAG_DEDUCED)
    else:
        body.append(TAG_TRANSMITTED)
        body += struct.pack(byte_order + "d", timestamp)
    if fmt == "string":
        for value in values:
            raw = value.encode()
            if len(raw) <= 0xFF:
                body += bytes([1, len(raw)])
            else:
                body += bytes([4]) + struct.pack(byte_order + "I", len(raw))
            body += raw
    else:
        body += struct.pack(byte_order + STRUCT_CODE[fmt] * len(values), *values)
    return bytes(body)


@dataclass
class HandshakeRequest:
    request_line: str
    headers: dict = field(default_factory=dict)

    @property
    def uid(self):
        return self.request_line.split(" ", 1)[1]

    @property
    def version(self):
        return int(self.request_line.split(" ", 1)[0].split("/")[1])


class MockOutlet:
    """Serves one data-phase connection with a scripted handshake."""

    def __init__(
        self,
        fmt="float32",
        channels=4,
        uid="11111111-2222-3333-4444-555555555555",
        status_line=None,
        byte_order=1234,
        suppress_subnormals=0,
        data_protocol_version=110,
        corrupt_test_pattern=False,
        samples=(),
        host="127.0.0.1",
    ):
        self.fmt = fmt
        self.channels = channels
        self.uid = uid
        self.status_line = status_line or "LSL/110 200 OK"
        self.byte_order = byte_order
        self.suppress_subnormals = suppress_subnormals
        self.data_protocol_version = data_protocol_version
        self.corrupt_test_pattern = corrupt_test_pattern
        self.samples = list(samples)
        self.requests: queue.Queue[HandshakeRequest] = queue.Queue()

        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((host, 0))
        self.socket.listen(4)
        self.host, self.port = self.socket.getsockname()

        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def pack_order(self):
        return ">" if self.byte_order == 4321 else "<"

    def _serve(self):
        self.socket.settimeout(0.2)
        while not self._stop.is_set():
            try:
                client, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._session, args=(client,), daemon=True).start()

    def _session(self, client):
        try:
            request = self._read_request(client)
            self.requests.put(request)
            self._check_request(request)

            response = [self.status_line, f"UID: {self.uid}"]
            if self.status_line.split(" ")[1] == "200":
                response += [
                    f"Byte-Order: {self.byte_order}",
                    f"Suppress-Subnormals: {self.suppress_subnormals}",
                    f"Data-Protocol-Version: {self.data_protocol_version}",
                ]
            client.sendall(("\r\n".join(response) + "\r\n\r\n").encode())
            if self.status_line.split(" ")[1] != "200" or self.data_protocol_version < 110:
                client.close()
                return

            for index, offset in enumerate(TEST_PATTERN_OFFSETS):
                values = test_pattern_values(self.fmt, self.channels, offset)
                if self.corrupt_test_pattern and index == 0:
                    values = [v + 1 if not isinstance(v, str) else v + "!" for v in values]
                client.sendall(
                    encode_sample(
                        self.fmt, values, TEST_PATTERN_TIMESTAMP, self.pack_order))

            for timestamp, values in self.samples:
                client.sendall(encode_sample(self.fmt, values, timestamp, self.pack_order))
            client.close()
        except OSError:
            pass

    def _read_request(self, client) -> HandshakeRequest:
        buffer = b""
        while b"\r\n\r\n" not in buffer:
            chunk = client.recv(4096)
            if not chunk:
                raise OSError("inlet closed during the handshake")
            buffer += chunk
        head = buffer.split(b"\r\n\r\n", 1)[0].decode()
        lines = head.split("\r\n")
        headers = {}
        for line in lines[1:]:
            key, _, value = line.partition(":")
            headers[key.strip().lower()] = value.strip()
        return HandshakeRequest(request_line=lines[0], headers=headers)

    def _check_request(self, request: HandshakeRequest):
        assert request.request_line.startswith("LSL:streamfeed/"), request.request_line
        assert request.version >= 110, request.request_line
        # A wrong Value-Size makes a real outlet downgrade to protocol 1.00, so getting it
        # right is not cosmetic (SCOPE.md §2.2, §4).
        assert int(request.headers["value-size"]) == VALUE_SIZE[self.fmt], request.headers
        assert request.headers["has-ieee754-floats"] == "1", request.headers
        assert request.headers["native-byte-order"] in ("1234", "4321"), request.headers
        for required in ("max-buffer-length", "max-chunk-length", "session-id"):
            assert required in request.headers, request.headers

    def next_request(self, timeout=10.0) -> HandshakeRequest:
        return self.requests.get(timeout=timeout)

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self.socket.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
