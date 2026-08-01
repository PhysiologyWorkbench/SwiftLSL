"""Step 8: interface enumeration, multi-interface discovery, local network access."""

from __future__ import annotations

import socket

import pytest

from conftest import require_pylsl


def netinfo(tool, *extra):
    """Runs `lsltool netinfo` and returns (interfaces, summary, access)."""
    run = tool("netinfo", *extra)
    run.wait_for("ready")
    interfaces = []
    while True:
        event = run.next_event(timeout=15)
        if event["event"] == "interface":
            interfaces.append(event)
        elif event["event"] == "interfaces":
            summary = event
            break
    access = None
    if "--no-probe" not in extra:
        access = run.wait_for("access", timeout=15)["state"]
    assert run.wait_exit() == 0
    return interfaces, summary, access


# --- L1: enumeration against Python's own view of the host ------------------------


def test_every_interface_the_os_reports_is_enumerated(tool):
    interfaces, summary, _ = netinfo(tool)
    assert summary["count"] == len(interfaces)

    # socket.if_nameindex is the independent oracle: same names, same indices.
    expected = dict(socket.if_nameindex())
    for entry in interfaces:
        assert entry["index"] in expected, entry
        assert expected[entry["index"]] == entry["name"], entry


def test_loopback_is_present_and_classified_by_type(tool):
    interfaces, _, _ = netinfo(tool)
    loopback = [entry for entry in interfaces if entry["loopback"]]
    assert loopback, "every host has a loopback interface"
    assert all(entry["functional_type"] == "loopback" for entry in loopback)
    assert any(entry["address"] == "127.0.0.1" for entry in loopback)


def test_discovery_never_uses_a_peer_to_peer_or_cellular_link(tool):
    """AWDL and cellular are not local networks (SCOPE.md §8.2)."""
    interfaces, summary, _ = netinfo(tool)
    excluded = {"wifiAWDL", "cellular", "coprocessor", "companionLink"}
    for entry in interfaces:
        if entry["functional_type"] in excluded:
            assert not entry["discovery"], entry

    carriers = [entry for entry in interfaces if entry["discovery"]]
    assert summary["discovery_count"] == len(carriers)
    assert carriers, "discovery must have at least the loopback interface to send from"


def test_a_scoped_ipv6_address_names_its_interface(tool):
    interfaces, _, _ = netinfo(tool)
    for entry in interfaces:
        if entry["family"] == "inet6" and entry["address"].startswith("fe80::"):
            assert entry["address"].endswith("%" + entry["name"]), entry


def test_the_local_network_probe_reports_a_state(tool):
    _, _, access = netinfo(tool)
    assert access in {"allowed", "denied", "unknown"}


def test_probing_can_be_skipped(tool):
    _, _, access = netinfo(tool, "--no-probe")
    assert access is None


def test_a_failed_resolve_carries_the_access_state(tool):
    """An empty resolve is ambiguous on Apple platforms, so it is never a bare failure."""
    run = tool(
        "record", "--known-peer", "127.0.0.1", "--no-multicast", "--resolve-timeout", "1",
        "--query", "name='NothingAtAll'")
    event = run.next_event(timeout=15)
    while event["event"] != "error":
        event = run.next_event(timeout=15)
    assert "no stream matched" in event["message"]
    assert event["local_network_access"] in {"allowed", "denied", "unknown"}
    assert run.wait_exit() == 1


# --- L2: real liblsl over the per-interface send path ------------------------------


@pytest.mark.interop
def test_an_outlet_is_found_over_multicast_and_broadcast(tool, outlet):
    """No known peers: the only path to the outlet is the per-interface wave."""
    outlet("IfaceMulticast", type="Iface", channels=1, srate=0.0, fmt="float32",
           source_id="iface-1")
    run = tool(
        "resolve", "--scope", "link", "--timeout", "5", "--minimum", "1",
        "--query", "name='IfaceMulticast'")
    run.wait_for("ready")
    assert run.wait_for("stream")["name"] == "IfaceMulticast"
    assert run.wait_for("done")["count"] == 1


@pytest.mark.interop
def test_multi_homed_discovery_still_resolves(tool, outlet):
    """The multi-homed case, as far as one host can test it (ROADMAP step 8).

    Requires two or more non-loopback interfaces carrying discovery — a Mac with both
    Wi-Fi and Ethernet active. It proves the per-interface wave does not break discovery
    when several interfaces are pinned in turn; that an outlet on *each* network is
    reached needs an outlet on each, and is a manual item in docs/PLATFORM-CHECKLIST.md.
    """
    require_pylsl()
    interfaces, _, _ = netinfo(tool, "--no-probe")
    routable = {
        entry["name"]
        for entry in interfaces
        if entry["discovery"] and not entry["loopback"] and entry["family"] == "inet"
    }
    if len(routable) < 2:
        pytest.skip(f"needs two non-loopback IPv4 interfaces, host has {sorted(routable)}")

    outlet("MultiHomed", type="Iface", channels=1, srate=0.0, fmt="float32",
           source_id="multi-1")
    run = tool(
        "resolve", "--scope", "link", "--timeout", "8", "--minimum", "1",
        "--query", "name='MultiHomed'")
    run.wait_for("ready")
    stream = run.wait_for("stream", timeout=15)
    assert stream["name"] == "MultiHomed"
    assert stream["v4address"], "the reply's source address must be recorded"
