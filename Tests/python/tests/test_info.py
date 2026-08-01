"""Step 5: metadata over LSL:fullinfo."""

from __future__ import annotations

import pytest

from conftest import pylsl_endpoint, require_pylsl
from lslmock.inforesponder import full_info, large_desc


def find(node, name):
    for child in node["children"]:
        if child["name"] == name:
            return child
    raise AssertionError(f"no <{name}> in {[c['name'] for c in node['children']]}")


# --- L1: mock info server ---------------------------------------------------------


def test_full_info_is_requested_and_parsed(tool, info_server):
    server = info_server([full_info()])
    info = tool("info", "--host", server.host, "--port", str(server.port)).wait_for("info")
    assert info["name"] == "MetaStream"
    assert info["type"] == "Meta"
    assert info["uid"] == "fullinfo-uid"
    assert info["created_at"] == 1000.0
    assert info["desc"] is None
    assert server.requests.get(timeout=5) == b"LSL:fullinfo\r\n"


def test_large_desc_spans_several_reads(tool, info_server):
    document = full_info(desc_body=large_desc(2000))
    assert len(document) > 64 * 1024
    server = info_server([document])
    info = tool(
        "info", "--host", server.host, "--port", str(server.port)
    ).wait_for("info", timeout=20)
    channels = find(info["desc"], "channels")
    assert len(channels["children"]) == 2000
    assert find(channels["children"][0], "label")["value"] == "Ch0"
    assert find(channels["children"][1999], "unit")["value"] == "microvolts"


def test_created_at_zero_is_retried(tool, info_server):
    """created_at == 0 means the response was not a valid stream info (SCOPE.md §2.4)."""
    server = info_server([full_info(created_at="0.000000000000000"), full_info()])
    info = tool("info", "--host", server.host, "--port", str(server.port)).wait_for("info")
    assert info["created_at"] == 1000.0
    assert server.attempts == 2, "the first response must have been discarded"


def test_persistent_invalid_response_fails(tool, info_server):
    server = info_server([full_info(created_at="0.000000000000000")])
    run = tool("info", "--host", server.host, "--port", str(server.port), "--attempts", "3")
    event = run.next_event()
    while event["event"] != "error":
        event = run.next_event()
    assert "created_at" in event["message"]
    assert run.wait_exit() == 1
    assert server.attempts == 3


def test_malformed_document_is_retried_then_fails(tool, info_server):
    server = info_server(["<info><name>truncated"])
    run = tool("info", "--host", server.host, "--port", str(server.port), "--attempts", "2")
    event = run.next_event()
    while event["event"] != "error":
        event = run.next_event()
    assert run.wait_exit() == 1
    assert server.attempts == 2


# --- L2: real liblsl --------------------------------------------------------------


@pytest.mark.interop
def test_desc_round_trips_node_for_node(tool, outlet):
    pylsl = require_pylsl()

    def build(desc):
        desc.append_child_value("manufacturer", "Acme")
        channels = desc.append_child("channels")
        for label in ("C3", "C4", "Cz"):
            channel = channels.append_child("channel")
            channel.append_child_value("label", label)
            channel.append_child_value("unit", "microvolts")
            channel.append_child_value("type", "EEG")

    outlet("DescStream", type="EEG", channels=3, srate=256.0, fmt="float32", desc=build)
    host, port, uid, _ = pylsl_endpoint(pylsl, "DescStream")

    info = tool("info", "--host", host, "--port", str(port)).wait_for("info")
    assert info["name"] == "DescStream"
    assert info["uid"] == uid
    assert info["created_at"] > 0
    assert info["channel_count"] == 3
    assert info["nominal_srate"] == 256.0

    desc = info["desc"]
    assert find(desc, "manufacturer")["value"] == "Acme"
    channels = find(desc, "channels")["children"]
    assert [find(c, "label")["value"] for c in channels] == ["C3", "C4", "Cz"]
    assert all(find(c, "unit")["value"] == "microvolts" for c in channels)
    assert all(find(c, "type")["value"] == "EEG" for c in channels)


@pytest.mark.interop
def test_a_stream_without_metadata_has_an_empty_desc(tool, outlet):
    pylsl = require_pylsl()
    outlet("BareStream", type="Bare", channels=1, srate=0.0, fmt="string")
    host, port, _, _ = pylsl_endpoint(pylsl, "BareStream")
    info = tool("info", "--host", host, "--port", str(port)).wait_for("info")
    assert info["desc"] is None


@pytest.mark.interop
def test_full_info_carries_the_transport_fields_shortinfo_lacks(tool, outlet):
    pylsl = require_pylsl()
    outlet("PortStream", type="Ports", channels=1, srate=0.0, fmt="int8")
    host, port, _, _ = pylsl_endpoint(pylsl, "PortStream")
    info = tool("info", "--host", host, "--port", str(port)).wait_for("info")
    assert info["v4data_port"] == port
    assert info["v4service_port"] > 0
    assert info["hostname"]
