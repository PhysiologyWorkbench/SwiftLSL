"""Step 6: time synchronisation."""

from __future__ import annotations

import pytest

from conftest import pylsl_endpoint, require_pylsl


def timesync_args(server, **options):
    args = ["timesync", "--host", server.host, "--port", str(server.port)]
    for key, value in options.items():
        args += [f"--{key.replace('_', '-')}", str(value)]
    return args


# --- L1: scripted time server -----------------------------------------------------


def test_probe_framing(tool, time_server):
    server = time_server()
    run = tool(*timesync_args(server, waves=1))
    run.wait_for("ready")
    wave_id, t0 = server.probes.get(timeout=10)
    assert wave_id != 0
    assert t0 > 0
    # Every probe in a wave carries the same id and its own send time.
    second_wave_id, second_t0 = server.probes.get(timeout=10)
    assert second_wave_id == wave_id
    assert second_t0 > t0


def test_offset_sign_and_magnitude_are_exact(tool, time_server):
    """Pins the sign convention against crafted t1/t2 (SCOPE.md gap #8).

    The server's clock is exactly 10 s ahead and it replies instantly, so the measured
    offset is +10 and the published correction — what you add to a *remote* timestamp to
    get a local one — must be -10.
    """
    server = time_server(remote_ahead_by=10.0)
    run = tool(*timesync_args(server, waves=1))
    offset = run.wait_for("offset", timeout=15)
    assert abs(offset["correction"] + 10.0) < 1e-3, offset
    assert offset["remote_time"] - offset["local_time"] == pytest.approx(10.0, abs=1e-3)
    assert 0 <= offset["uncertainty"] < 0.05
    assert run.wait_for("done")["published"] == 1


def test_a_remote_clock_behind_ours_gives_a_positive_correction(tool, time_server):
    server = time_server(remote_ahead_by=-4.0)
    offset = tool(*timesync_args(server, waves=1)).wait_for("offset", timeout=15)
    assert abs(offset["correction"] - 4.0) < 1e-3, offset


def test_processing_delay_shows_up_in_the_offset_not_the_rtt(tool, time_server):
    """t2 - t1 is the outlet's own time and is subtracted out of the RTT."""
    server = time_server(remote_ahead_by=0.0, processing_delay=0.5)
    offset = tool(*timesync_args(server, waves=1)).wait_for("offset", timeout=15)
    # rtt = (t3 - t0) - (t2 - t1): the half second the server spent is removed, so the
    # measured RTT is the wire time only, and goes slightly negative on loopback.
    assert offset["uncertainty"] < 0.05
    # offset = ((t1 - t0) + (t2 - t3)) / 2 = (0 + 0.5) / 2, negated on publication.
    assert abs(offset["correction"] + 0.25) < 1e-2, offset


def test_stale_wave_ids_are_rejected(tool, time_server):
    server = time_server(wave_id_override=999999)
    run = tool(*timesync_args(server, waves=1))
    run.wait_for("ready")
    assert run.wait_for("done", timeout=15)["published"] == 0


def test_too_few_replies_publishes_nothing(tool, time_server):
    """A wave needs TimeUpdateMinProbes replies before it publishes (SCOPE.md §2.5)."""
    server = time_server(answer_every=4)  # 2 of 8 probes answered
    run = tool(*timesync_args(server, waves=1))
    assert run.wait_for("done", timeout=15)["published"] == 0


def test_the_minimum_probe_threshold_is_honoured(tool, time_server):
    server = time_server(answer_every=4)
    run = tool(*timesync_args(server, waves=1, minimum_probes=2))
    assert run.wait_for("offset", timeout=15)
    assert run.wait_for("done")["published"] == 1


def test_several_waves_each_publish(tool, time_server):
    server = time_server(remote_ahead_by=2.5)
    run = tool(*timesync_args(server, waves=3, update_interval=0.7))
    corrections = [run.wait_for("offset", timeout=20)["correction"] for _ in range(3)]
    assert all(abs(c + 2.5) < 1e-3 for c in corrections), corrections
    assert run.wait_for("done")["published"] == 3


# --- L2: real liblsl --------------------------------------------------------------


@pytest.mark.interop
def test_loopback_offset_is_near_zero(tool, outlet):
    """Two clocks in one process on one host: the offset is the loopback RTT, no more."""
    pylsl = require_pylsl()
    outlet("SyncStream", type="Sync", channels=1, srate=0.0, fmt="float32")
    host, _, _, info = pylsl_endpoint(pylsl, "SyncStream")

    import re

    service_port = int(re.search(r"<v4service_port>(\d+)</", info.as_xml()).group(1))

    run = tool(
        "timesync", "--host", host, "--port", str(service_port),
        "--waves", "10", "--update-interval", "0.7")
    offsets = [run.wait_for("offset", timeout=30) for _ in range(10)]
    for offset in offsets:
        assert abs(offset["correction"]) < 5e-3, offset
        assert offset["uncertainty"] < 5e-3, offset
        assert offset["local_time"] > 0
        assert offset["remote_time"] > 0
    assert run.wait_for("done")["published"] == 10
