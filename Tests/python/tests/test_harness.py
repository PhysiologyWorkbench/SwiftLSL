"""Step 1: the harness backbone itself — process lifecycle, NDJSON contract, echo."""

from __future__ import annotations

import socket

import pytest

from conftest import ToolExited


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def recv_exactly(sock: socket.socket, count: int) -> bytes:
    chunks = []
    remaining = count
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise AssertionError(f"peer closed with {remaining} bytes outstanding")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def test_tcp_echo_roundtrip(tool):
    echo = tool("echo", "tcp")
    ready = echo.wait_for("ready")
    assert ready["proto"] == "tcp"
    assert ready["port"] > 0

    payload = b"LSL:shortinfo\r\n" * 4
    with socket.create_connection(("127.0.0.1", ready["port"]), timeout=10) as client:
        client.sendall(payload)
        assert recv_exactly(client, len(payload)) == payload
        client.shutdown(socket.SHUT_WR)
        assert client.recv(1) == b""

    closed = echo.wait_for("closed")
    assert closed == {"event": "closed", "proto": "tcp", "bytes": len(payload)}
    assert echo.wait_exit() == 0


def test_tcp_ready_event_honours_requested_port(tool):
    port = free_port()
    echo = tool("echo", "tcp", "--port", str(port))
    assert echo.wait_for("ready")["port"] == port


def test_udp_echo_roundtrip(tool):
    echo = tool("echo", "udp")
    ready = echo.wait_for("ready")
    assert ready["proto"] == "udp"
    assert ready["port"] > 0

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(10)
        # The second payload exceeds a 1400-byte Ethernet-ish MTU: the receive buffer
        # must not be sized for "typical" datagrams.
        for payload in (b"ping", bytes(range(256)) * 8):
            client.sendto(payload, ("127.0.0.1", ready["port"]))
            assert client.recv(65536) == payload
            assert echo.wait_for("echo")["bytes"] == len(payload)


def test_udp_ready_event_honours_requested_port(tool):
    port = free_port()
    echo = tool("echo", "udp", "--port", str(port))
    assert echo.wait_for("ready")["port"] == port


@pytest.mark.parametrize("proto", ["tcp", "udp"])
def test_sigterm_exits_cleanly(tool, proto):
    echo = tool("echo", proto)
    echo.wait_for("ready")
    echo.process.send_signal(15)
    assert echo.wait_for("terminated")["event"] == "terminated"
    assert echo.terminate() == 0


def test_stdout_carries_only_ndjson(tool):
    """Nothing but JSON objects is ever written to stdout (ARCHITECTURE.md)."""
    echo = tool("echo", "udp")
    echo.wait_for("ready")
    echo.terminate()
    with pytest.raises(ToolExited):
        while True:
            event = echo.next_event(timeout=1)
            assert isinstance(event, dict) and "event" in event
