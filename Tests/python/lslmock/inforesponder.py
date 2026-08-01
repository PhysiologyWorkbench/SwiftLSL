"""A mock outlet's LSL:fullinfo responder (SCOPE.md §2.4)."""

from __future__ import annotations

import queue
import socket
import threading


def full_info(desc_body="", created_at="1000.000000000000", uid="fullinfo-uid", channels=2):
    desc = f"<desc>\n{desc_body}\t</desc>" if desc_body else "<desc />"
    return (
        '<?xml version="1.0"?>\n<info>\n'
        "\t<name>MetaStream</name>\n"
        "\t<type>Meta</type>\n"
        f"\t<channel_count>{channels}</channel_count>\n"
        "\t<channel_format>float32</channel_format>\n"
        "\t<source_id>meta-src</source_id>\n"
        "\t<nominal_srate>0.000000000000000</nominal_srate>\n"
        "\t<version>1.100000000000000</version>\n"
        f"\t<created_at>{created_at}</created_at>\n"
        f"\t<uid>{uid}</uid>\n"
        "\t<session_id>default</session_id>\n"
        "\t<hostname>mock</hostname>\n"
        "\t<v4address></v4address>\n"
        "\t<v4data_port>16574</v4data_port>\n"
        "\t<v4service_port>16572</v4service_port>\n"
        "\t<v6address></v6address>\n"
        "\t<v6data_port>16574</v6data_port>\n"
        "\t<v6service_port>16572</v6service_port>\n"
        f"\t{desc}\n</info>\n"
    )


def large_desc(entries=2000):
    """A desc comfortably past 64 KiB, so the reply cannot arrive in one read."""
    body = ["\t\t<channels>\n"]
    for index in range(entries):
        body.append(
            f"\t\t\t<channel>\n\t\t\t\t<label>Ch{index}</label>\n"
            "\t\t\t\t<unit>microvolts</unit>\n\t\t\t</channel>\n"
        )
    body.append("\t\t</channels>\n")
    return "".join(body)


class MockInfoServer:
    """Answers LSL:fullinfo, optionally with a different document per attempt."""

    def __init__(self, documents, host="127.0.0.1"):
        self.documents = list(documents)
        self.requests: queue.Queue[bytes] = queue.Queue()

        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((host, 0))
        self.socket.listen(4)
        self.host, self.port = self.socket.getsockname()

        self._attempt = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

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
            request = b""
            while b"\r\n" not in request:
                chunk = client.recv(1024)
                if not chunk:
                    return
                request += chunk
            assert request.startswith(b"LSL:fullinfo\r\n"), request
            self.requests.put(request)

            index = min(self._attempt, len(self.documents) - 1)
            self._attempt += 1
            # The outlet writes the whole document and closes; the inlet reads to EOF.
            client.sendall(self.documents[index].encode())
            client.shutdown(socket.SHUT_WR)
            client.close()
        except OSError:
            pass

    @property
    def attempts(self):
        return self.requests.qsize()

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self.socket.close()
