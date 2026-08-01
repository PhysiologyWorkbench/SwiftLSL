"""A mock outlet's discovery responder: answers LSL:shortinfo (SCOPE.md §2.1)."""

from __future__ import annotations

import queue
import socket
import threading
from dataclasses import dataclass

SHORTINFO_TEMPLATE = """<?xml version="1.0"?>
<info>
\t<name>{name}</name>
\t<type>{type}</type>
\t<channel_count>{channels}</channel_count>
\t<channel_format>{format}</channel_format>
\t<source_id>{source_id}</source_id>
\t<nominal_srate>{srate}</nominal_srate>
\t<version>1.100000000000000</version>
\t<created_at>1000.000000000000</created_at>
\t<uid>{uid}</uid>
\t<session_id>{session}</session_id>
\t<hostname>mock</hostname>
\t<v4address></v4address>
\t<v4data_port>{data_port}</v4data_port>
\t<v4service_port>{service_port}</v4service_port>
\t<v6address></v6address>
\t<v6data_port>{data_port}</v6data_port>
\t<v6service_port>{service_port}</v6service_port>
\t<desc />
</info>
"""


def shortinfo(
    name="Mock",
    type="Test",
    channels=4,
    format="float32",
    source_id="mock-src",
    srate="0.000000000000000",
    uid="11111111-2222-3333-4444-555555555555",
    session="default",
    data_port=16574,
    service_port=16572,
):
    return SHORTINFO_TEMPLATE.format(
        name=name,
        type=type,
        channels=channels,
        format=format,
        source_id=source_id,
        srate=srate,
        uid=uid,
        session=session,
        data_port=data_port,
        service_port=service_port,
    )


@dataclass
class Request:
    """A parsed LSL:shortinfo query, exactly as it arrived."""

    raw: bytes
    query: str
    return_port: int
    query_id: str
    source: tuple


class MockResponder:
    """Binds a UDP port, validates incoming queries, and replies with canned XML.

    Binds inside 16572..16603 by default so a resolver configured with
    `--known-peer <host> --no-multicast` reaches it by enumerating the port range
    (SCOPE.md §2.1).
    """

    def __init__(
        self,
        xml=None,
        host="127.0.0.1",
        port=None,
        reply=True,
        query_id_override=None,
    ):
        self.xml = xml if xml is not None else shortinfo()
        self.reply_enabled = reply
        self.query_id_override = query_id_override
        self.requests: queue.Queue[Request] = queue.Queue()

        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if port is not None:
            self.socket.bind((host, port))
        else:
            for candidate in range(16572, 16604):
                try:
                    self.socket.bind((host, candidate))
                    break
                except OSError:
                    continue
            else:
                raise AssertionError("no free port in 16572..16603 for the mock responder")
        self.host, self.port = self.socket.getsockname()

        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        self.socket.settimeout(0.2)
        while not self._stop.is_set():
            try:
                payload, source = self.socket.recvfrom(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            request = self._parse(payload, source)
            self.requests.put(request)
            if not self.reply_enabled:
                continue
            query_id = (
                self.query_id_override
                if self.query_id_override is not None
                else request.query_id
            )
            body = (query_id + "\r\n").encode() + self.xml.encode()
            self.socket.sendto(body, (source[0], request.return_port))

    def _parse(self, payload: bytes, source) -> Request:
        # Three CRLF-terminated lines, nothing else (SCOPE.md §2.1). A mock that tolerates
        # a malformed query would hide a real defect.
        text = payload.decode()
        assert text.startswith("LSL:shortinfo\r\n"), f"bad request line: {text!r}"
        assert text.endswith("\r\n"), f"query not CRLF-terminated: {text!r}"
        lines = text.split("\r\n")
        assert len(lines) == 4 and lines[3] == "", f"expected three lines, got {lines!r}"
        header, query, tail, _ = lines
        parts = tail.split(" ")
        assert len(parts) == 2, f"bad return-port line: {tail!r}"
        return Request(
            raw=payload,
            query=query,
            return_port=int(parts[0]),
            query_id=parts[1],
            source=source,
        )

    def next_request(self, timeout=10.0) -> Request:
        return self.requests.get(timeout=timeout)

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self.socket.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
