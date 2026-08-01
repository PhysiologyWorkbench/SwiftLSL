"""A mock outlet's LSL:timedata responder with crafted t1/t2 (SCOPE.md §2.5).

Because the reply's `t1` and `t2` are whatever the server says they are, a mock can make
the expected offset and RTT exact constants — which is the only way to pin the sign
convention (SCOPE.md gap #8) without trusting the implementation under test.
"""

from __future__ import annotations

import queue
import socket
import threading


class MockTimeServer:
    """Answers timedata probes with a fixed clock offset and a fixed processing delay."""

    def __init__(
        self,
        remote_ahead_by=10.0,
        processing_delay=0.0,
        reply_to=None,
        wave_id_override=None,
        answer_every=1,
        host="127.0.0.1",
    ):
        self.remote_ahead_by = remote_ahead_by
        self.processing_delay = processing_delay
        self.wave_id_override = wave_id_override
        self.answer_every = answer_every
        self.probes: queue.Queue = queue.Queue()
        self._seen = 0

        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((host, 0))
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
            text = payload.decode()
            assert text.startswith("LSL:timedata\r\n"), f"bad probe: {text!r}"
            assert text.endswith("\r\n"), f"probe not CRLF-terminated: {text!r}"
            wave_id, t0 = text.split("\r\n")[1].split(" ")
            wave_id, t0 = int(wave_id), float(t0)
            self.probes.put((wave_id, t0))

            self._seen += 1
            if self._seen % self.answer_every != 0:
                continue

            # t1 is the outlet's receive time, t2 its send time. Placing both at
            # t0 + offset makes the round trip symmetric, so the measured offset is
            # exactly `remote_ahead_by` and the RTT is whatever the wire took.
            t1 = t0 + self.remote_ahead_by
            t2 = t1 + self.processing_delay
            reply_wave = (
                self.wave_id_override if self.wave_id_override is not None else wave_id
            )
            # A leading space, four fields, no trailing newline (SCOPE.md §2.5).
            body = f" {reply_wave} {t0!r} {t1!r} {t2!r}"
            self.socket.sendto(body.encode(), source)

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self.socket.close()
