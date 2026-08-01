"""Step 7: the assembled inlet — recovery, watchdog, public API."""

from __future__ import annotations

import time

import pytest

from conftest import require_pylsl
from lslmock.responder import shortinfo

UID = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"


def record_args(*extra):
    return ("record", "--known-peer", "127.0.0.1", "--no-multicast", *extra)


# --- L1: mock peers ---------------------------------------------------------------


def test_records_from_a_mock_stream(tool, responder, mock_outlet):
    samples = [(1.0, [1.0, 2.0]), (2.0, [3.0, 4.0]), (3.0, [5.0, 6.0])]
    outlet = mock_outlet(fmt="float32", channels=2, uid=UID, samples=samples)
    responder(
        xml=shortinfo(
            name="MockRec", channels=2, uid=UID, source_id="rec-src",
            data_port=outlet.port, service_port=outlet.port))

    run = tool(*record_args("--count", "3", "--query", "name='MockRec'"))
    assert run.wait_for("ready")["uid"] == UID
    assert [run.wait_for("sample")["t"] for _ in range(3)] == [1.0, 2.0, 3.0]
    assert run.wait_for("done")["count"] == 3
    assert run.wait_exit() == 0


def test_watchdog_forces_a_re_resolve_when_a_stream_freezes(tool, responder, mock_outlet):
    """A stalled outlet holds the socket open; only the watchdog notices (SCOPE.md §3)."""
    outlet = mock_outlet(fmt="float32", channels=1, uid=UID, stall=True)
    mock = responder(
        xml=shortinfo(
            name="Frozen", channels=1, uid=UID, source_id="frozen-src",
            data_port=outlet.port, service_port=outlet.port))

    run = tool(*record_args("--watchdog", "1", "--query", "name='Frozen'", "--quiet"))
    run.wait_for("ready")

    # The initial resolve, then at least one more once the watchdog fires.
    mock.next_request(timeout=10)
    before = mock.requests.qsize()
    deadline = time.time() + 20
    while time.time() < deadline and mock.requests.qsize() <= before:
        time.sleep(0.1)
    assert mock.requests.qsize() > before, "the watchdog never triggered a re-resolve"
    assert run.terminate() == 0


def test_a_stream_without_a_source_id_is_not_recovered(tool, responder, mock_outlet):
    """Nothing identifies "the same stream", so the loss is surfaced instead."""
    outlet = mock_outlet(
        fmt="float32", channels=1, uid=UID, samples=[(1.0, [1.0])])
    responder(
        xml=shortinfo(
            name="NoSource", channels=1, uid=UID, source_id="",
            data_port=outlet.port, service_port=outlet.port))

    run = tool(*record_args("--query", "name='NoSource'"))
    run.wait_for("sample")
    event = run.next_event(timeout=15)
    while event["event"] != "error":
        event = run.next_event(timeout=15)
    assert "source_id" in event["message"]
    assert run.wait_exit() == 1


def test_recovery_can_be_disabled(tool, responder, mock_outlet):
    outlet = mock_outlet(fmt="float32", channels=1, uid=UID, samples=[(1.0, [1.0])])
    responder(
        xml=shortinfo(
            name="NoRecover", channels=1, uid=UID, source_id="has-source",
            data_port=outlet.port, service_port=outlet.port))

    run = tool(*record_args("--no-recovery", "--query", "name='NoRecover'"))
    run.wait_for("sample")
    event = run.next_event(timeout=15)
    while event["event"] != "error":
        event = run.next_event(timeout=15)
    assert "lost" in event["message"]


def test_no_matching_stream_is_an_error(tool, responder):
    run = tool(*record_args("--resolve-timeout", "1", "--query", "name='Nothing'"))
    event = run.next_event(timeout=15)
    while event["event"] != "error":
        event = run.next_event(timeout=15)
    assert "no stream matched" in event["message"]
    assert run.wait_exit() == 1


# --- L2: real liblsl --------------------------------------------------------------


@pytest.mark.interop
def test_records_samples_and_offsets_from_a_pylsl_outlet(tool, outlet):
    live = outlet("FullRec", type="Full", channels=3, srate=0.0, fmt="float32",
                  source_id="full-1")
    run = tool("record", "--count", "5", "--query", "name='FullRec'")
    run.wait_for("ready")
    for index in range(5):
        live.push_sample([float(index), 1.0, 2.0])
    values = [run.wait_for("sample")["v"] for _ in range(5)]
    assert values == [[float(i), 1.0, 2.0] for i in range(5)]
    assert run.wait_for("done")["count"] == 5


@pytest.mark.interop
def test_clock_offsets_are_published_alongside_the_samples(tool, outlet):
    live = outlet("OffsetRec", type="Offset", channels=1, srate=0.0, fmt="float32",
                  source_id="offset-1")
    run = tool("record", "--duration", "5", "--query", "name='OffsetRec'", "--quiet")
    run.wait_for("ready")
    for _ in range(20):
        live.push_sample([1.0])
        time.sleep(0.05)
    offset = run.wait_for("offset", timeout=15)
    assert abs(offset["correction"]) < 5e-3
    assert offset["uncertainty"] < 5e-3


@pytest.mark.interop
def test_the_inlet_recovers_when_the_outlet_restarts(tool, outlet_process):
    """Kill and restart an outlet with the same source_id mid-stream (SCOPE.md §3).

    The outlet runs in its own process and is killed outright. Destroying a
    `StreamOutlet` in-process blocks in liblsl's destructor while an inlet is still
    attached, which is not what a device dropping off the network looks like.
    """

    def start(first_value):
        return outlet_process(
            name="Recoverable", type="Recover", channels=1, srate=0.0,
            format="float32", source_id="recover-1", rate=50, start=first_value)

    # The two outlets emit disjoint value ranges, so which one a sample came from is
    # never in doubt.
    first = start(0)
    run = tool("record", "--query", "name='Recoverable'", "--watchdog", "3")
    run.wait_for("ready", timeout=20)
    before = [run.wait_for("sample", timeout=20)["v"][0] for _ in range(3)]
    assert all(value < 1000 for value in before), before

    first.kill()
    start(1000)

    reset = run.wait_for("reset", timeout=90)
    assert reset["previous_uid"] != reset["uid"], reset
    assert reset["sample_index"] > 0

    resets_after = 0
    resumed = []
    deadline = time.time() + 20
    while time.time() < deadline and len(resumed) < 50:
        event = run.next_event(timeout=25)
        if event["event"] == "sample":
            resumed.append(event["v"][0])
        elif event["event"] == "reset":
            resets_after += 1

    assert resumed, "the sample flow did not resume after recovery"
    assert all(value >= 1000 for value in resumed), resumed[:5]
    assert resets_after == 0, "the reset flag must be observed exactly once"
    assert run.terminate() == 0


@pytest.mark.interop
def test_short_soak_loses_no_samples(tool, outlet):
    """A shortened form of the pre-release soak (ROADMAP step 9 runs the long one)."""
    total = 5000
    live = outlet("Soak", type="Soak", channels=4, srate=0.0, fmt="float32",
                  source_id="soak-1")
    run = tool("record", "--query", "name='Soak'", "--count", str(total), "--quiet")
    run.wait_for("ready")

    chunk = [[float(k) for k in range(4)] for _ in range(500)]
    for _ in range(total // 500):
        live.push_chunk(chunk)
        time.sleep(0.02)

    done = run.wait_for("done", timeout=90)
    assert done["count"] == total
    assert done["dropped"] == 0
