"""Step 3: discovery."""

from __future__ import annotations

import time

import pytest

from lslmock.responder import shortinfo

UID_A = "aaaaaaaa-0000-0000-0000-000000000001"


def unicast_args(*extra):
    """Reach a mock responder without touching multicast or broadcast."""
    return ("resolve", "--known-peer", "127.0.0.1", "--no-multicast", *extra)


# --- L1: mock responder -----------------------------------------------------------


def test_query_packet_framing(tool, responder):
    mock = responder(reply=False)
    resolve = tool(*unicast_args("--timeout", "3", "--query", "type='EEG'"))
    resolve.wait_for("ready")

    request = mock.next_request()
    assert request.raw.startswith(b"LSL:shortinfo\r\n")
    assert request.query == "session_id='default' and type='EEG'"
    assert 1 <= request.return_port <= 65535
    assert request.query_id
    # The return port is where the reply must go, and it is the port the tool listens on,
    # not the port it sent from being assumed (SCOPE.md §2.1).
    assert request.raw.endswith(f"{request.return_port} {request.query_id}\r\n".encode())


def test_session_id_scopes_every_query(tool, responder):
    mock = responder(reply=False)
    resolve = tool(*unicast_args("--timeout", "3", "--session", "lab7"))
    resolve.wait_for("ready")
    assert mock.next_request().query == "session_id='lab7'"


def test_canned_reply_is_decoded(tool, responder):
    responder(xml=shortinfo(name="MockEEG", type="EEG", channels=7, uid=UID_A))
    resolve = tool(*unicast_args("--timeout", "3", "--minimum", "1"))
    stream = resolve.wait_for("stream")
    assert stream["name"] == "MockEEG"
    assert stream["type"] == "EEG"
    assert stream["channel_count"] == 7
    assert stream["uid"] == UID_A
    assert stream["channel_format"] == "float32"
    assert stream["protocol_version"] == 110
    # The outlet advertises no address; the reply's source is the only one there is.
    assert stream["v4address"] == "127.0.0.1"
    assert resolve.wait_for("done")["count"] == 1


def test_reply_with_wrong_query_id_is_ignored(tool, responder):
    responder(xml=shortinfo(uid=UID_A), query_id_override="not-our-id")
    resolve = tool(*unicast_args("--timeout", "2"))
    resolve.wait_for("ready")
    assert resolve.wait_for("done")["count"] == 0


def test_malformed_xml_does_not_stop_the_wave(tool, responder):
    responder(xml="<info><name>truncated")
    good = responder(xml=shortinfo(name="Good", uid=UID_A))
    resolve = tool(*unicast_args("--timeout", "3", "--minimum", "1"))
    stream = resolve.wait_for("stream")
    assert stream["name"] == "Good"
    assert good.next_request().query_id


def test_stream_missing_required_field_is_ignored(tool, responder):
    responder(xml=shortinfo(uid=""))
    resolve = tool(*unicast_args("--timeout", "2"))
    assert resolve.wait_for("done")["count"] == 0


def test_duplicate_uid_yields_one_stream(tool, responder):
    """Two peers answering for one UID are one stream, not two.

    That the *address* of the first responder survives is asserted in the Swift
    LSLTests suite, where two distinct source addresses can be constructed without a
    loopback alias.
    """
    responder(xml=shortinfo(uid=UID_A, name="First"))
    responder(xml=shortinfo(uid=UID_A, name="Second"))
    resolve = tool(*unicast_args("--timeout", "3", "--minimum", "1"))
    stream = resolve.wait_for("stream")
    assert resolve.wait_for("done")["count"] == 1
    assert stream["uid"] == UID_A


def test_repeated_waves_are_sent(tool, responder):
    """A resolve is a schedule of waves, not a single packet (SCOPE.md §2.1)."""
    mock = responder(reply=False)
    resolve = tool(*unicast_args("--timeout", "4"))
    resolve.wait_for("ready")
    first = mock.next_request()
    second = mock.next_request()
    assert second.query_id == first.query_id, "the query id is fixed for the whole resolve"


def test_no_streams_found_is_not_an_error(tool, responder):
    resolve = tool(*unicast_args("--timeout", "1"))
    assert resolve.wait_for("done")["count"] == 0
    assert resolve.wait_exit() == 0


# --- L2: real liblsl --------------------------------------------------------------


@pytest.mark.interop
def test_resolves_a_pylsl_outlet_by_type(tool, outlet):
    outlet("InteropEEG", type="EEG", channels=8, srate=256.0, source_id="interop-1")
    started = time.time()
    resolve = tool("resolve", "--timeout", "5", "--minimum", "1", "--query", "type='EEG'")
    stream = resolve.wait_for("stream")
    assert stream["name"] == "InteropEEG"
    assert stream["channel_count"] == 8
    assert stream["nominal_srate"] == 256.0
    assert stream["source_id"] == "interop-1"
    assert stream["v4data_port"] > 0
    resolve.wait_for("done")
    assert time.time() - started < 2.0, "a loopback resolve must complete in under 2 s"


@pytest.mark.interop
def test_resolves_a_pylsl_outlet_by_name(tool, outlet):
    outlet("NamedStream", type="Misc")
    resolve = tool(
        "resolve", "--timeout", "5", "--minimum", "1", "--query", "name='NamedStream'")
    assert resolve.wait_for("stream")["name"] == "NamedStream"


@pytest.mark.interop
def test_a_non_matching_query_finds_nothing(tool, outlet):
    outlet("QuietStream", type="Misc")
    resolve = tool("resolve", "--timeout", "2", "--query", "type='NoSuchType'")
    assert resolve.wait_for("done")["count"] == 0


@pytest.mark.interop
def test_known_peers_reach_an_outlet_without_multicast(tool, outlet):
    """The unicast path needs no multicast entitlement at all (SCOPE.md §8.1)."""
    outlet("PeerStream", type="Peer")
    resolve = tool(
        *unicast_args("--timeout", "5", "--minimum", "1", "--query", "type='Peer'"))
    assert resolve.wait_for("stream")["name"] == "PeerStream"


@pytest.mark.interop
def test_machine_scope_resolves_on_loopback(tool, outlet):
    outlet("MachineStream", type="Machine")
    resolve = tool(
        "resolve", "--scope", "machine", "--timeout", "5", "--minimum", "1",
        "--query", "type='Machine'")
    assert resolve.wait_for("stream")["name"] == "MachineStream"


@pytest.mark.interop
def test_continuous_resolve_sees_a_stream_appear_and_expire(tool, outlet):
    resolve = tool(
        "resolve", "--continuous", "--forget-after", "1.5", "--query", "type='Transient'")
    resolve.wait_for("ready")

    live = outlet("TransientStream", type="Transient")
    while True:
        event = resolve.wait_for("streams", timeout=15)
        if event["count"] == 1:
            break
    assert resolve.wait_for("stream")["name"] == "TransientStream"

    live.stop()

    while True:
        event = resolve.wait_for("streams", timeout=20)
        if event["count"] == 0:
            break

    assert resolve.terminate() == 0
