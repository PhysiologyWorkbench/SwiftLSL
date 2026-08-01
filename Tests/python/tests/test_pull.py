"""Step 4: the data phase."""

from __future__ import annotations

import struct
import time

import pytest

from conftest import pylsl_endpoint, require_pylsl
from lslmock.outlet import test_pattern_values as pattern_values

UID = "11111111-2222-3333-4444-555555555555"


def pull_args(mock, fmt="float32", channels=4, **options):
    args = [
        "pull",
        "--host", mock.host,
        "--port", str(mock.port),
        "--uid", mock.uid,
        "--channels", str(channels),
        "--format", fmt,
    ]
    for key, value in options.items():
        args += [f"--{key.replace('_', '-')}", str(value)]
    return args


# --- L1: scripted mock outlet -----------------------------------------------------


def test_handshake_request_is_well_formed(tool, mock_outlet):
    mock = mock_outlet(fmt="float32", channels=4, uid=UID)
    tool(*pull_args(mock, count=0))
    request = mock.next_request()
    assert request.request_line == f"LSL:streamfeed/110 {UID}"
    assert request.headers["value-size"] == "4"
    assert request.headers["supports-subnormals"] == "1"
    assert request.headers["data-protocol-version"] == "110"
    # 360 s at an irregular rate is 36000 samples (SCOPE.md §2.2).
    assert request.headers["max-buffer-length"] == "36000"
    assert request.headers["max-chunk-length"] == "0"
    assert request.headers["session-id"] == "default"


def test_supports_subnormals_follows_the_format(tool, mock_outlet):
    mock = mock_outlet(fmt="int16", channels=2, uid=UID)
    tool(*pull_args(mock, fmt="int16", channels=2))
    request = mock.next_request()
    assert request.headers["supports-subnormals"] == "0"
    assert request.headers["value-size"] == "2"


def test_samples_decode_after_the_test_pattern_gate(tool, mock_outlet):
    samples = [(100.0, [1.0, 2.0, 3.0, 4.0]), (100.5, [5.0, 6.0, 7.0, 8.0])]
    mock = mock_outlet(fmt="float32", channels=4, uid=UID, samples=samples)
    pull = tool(*pull_args(mock, count=2))
    assert pull.wait_for("ready")["byte_order"] == 1234

    first = pull.wait_for("sample")
    assert first["t"] == 100.0
    assert first["v"] == [1.0, 2.0, 3.0, 4.0]
    second = pull.wait_for("sample")
    assert second["t"] == 100.5
    assert pull.wait_for("done")["count"] == 2
    assert pull.wait_exit() == 0


def test_wrong_test_pattern_refuses_the_connection(tool, mock_outlet):
    mock = mock_outlet(fmt="float32", channels=4, uid=UID, corrupt_test_pattern=True)
    pull = tool(*pull_args(mock, count=1))
    error = pull.next_event()
    while error["event"] != "error":
        error = pull.next_event()
    assert "testPatternMismatch" in error["message"]
    assert pull.wait_exit() == 1


@pytest.mark.parametrize(
    "status,expected",
    [
        ("LSL/110 404 Not found", "lost"),
        ("LSL/110 505 Version not supported", "statusError"),
        ("LSL/110 302 Found", "lost"),
    ],
)
def test_error_status_lines_are_distinguished(tool, mock_outlet, status, expected):
    mock = mock_outlet(uid=UID, status_line=status)
    pull = tool(*pull_args(mock, count=1))
    event = pull.next_event()
    while event["event"] != "error":
        event = pull.next_event()
    assert expected in event["message"]


def test_downgrade_to_protocol_100_is_refused(tool, mock_outlet):
    """The outlet may unilaterally downgrade mid-handshake (SCOPE.md §4)."""
    mock = mock_outlet(uid=UID, data_protocol_version=100)
    pull = tool(*pull_args(mock, count=1))
    event = pull.next_event()
    while event["event"] != "error":
        event = pull.next_event()
    assert "unsupportedProtocolVersion(100)" in event["message"]


def test_sub_110_stream_is_refused_before_connecting(tool, mock_outlet):
    """Detected from the discovery XML, so no socket is opened at all (SCOPE.md §4)."""
    mock = mock_outlet(uid=UID)
    pull = tool(*pull_args(mock, count=1, protocol_version=100))
    event = pull.next_event()
    while event["event"] != "error":
        event = pull.next_event()
    assert "unsupportedProtocolVersion(100)" in event["message"]
    assert mock.requests.empty(), "no handshake should have been attempted"


def test_big_endian_outlet_is_decoded_byte_swapped(tool, mock_outlet):
    samples = [(7.5, [1000, -2000, 3000, -4000])]
    mock = mock_outlet(
        fmt="int32", channels=4, uid=UID, byte_order=4321, samples=samples)
    pull = tool(*pull_args(mock, fmt="int32", channels=4, count=1))
    assert pull.wait_for("ready")["byte_order"] == 4321
    assert pull.wait_for("sample")["v"] == [1000, -2000, 3000, -4000]


def test_byte_order_zero_is_remapped_to_native(tool, mock_outlet):
    """`Byte-Order: 0` means portable, for interop with liblsl ~1.13 (SCOPE.md §2.2)."""
    mock = mock_outlet(
        fmt="int16", channels=2, uid=UID, byte_order=0, samples=[(1.0, [7, -8])])
    # The mock packs little-endian when byte_order is not 4321, which is what native means
    # on this host.
    pull = tool(*pull_args(mock, fmt="int16", channels=2, count=1))
    assert pull.wait_for("ready")["byte_order"] == 1234
    assert pull.wait_for("sample")["v"] == [7, -8]


def test_string_channels_decode(tool, mock_outlet):
    long_marker = "x" * 400
    samples = [(1.0, ["start", long_marker]), (2.0, ["", "end"])]
    mock = mock_outlet(fmt="string", channels=2, uid=UID, samples=samples)
    pull = tool(*pull_args(mock, fmt="string", channels=2, count=2))
    assert pull.wait_for("sample")["v"] == ["start", long_marker]
    assert pull.wait_for("sample")["v"] == ["", "end"]


def test_deduced_timestamps_are_materialised_at_the_nominal_rate(tool, mock_outlet):
    samples = [(10.0, [1.0]), (None, [2.0]), (None, [3.0]), (20.0, [4.0]), (None, [5.0])]
    mock = mock_outlet(fmt="float32", channels=1, uid=UID, samples=samples)
    pull = tool(*pull_args(mock, fmt="float32", channels=1, srate=4, count=5))
    stamps = [pull.wait_for("sample")["t"] for _ in range(5)]
    assert stamps == [10.0, 10.25, 10.5, 20.0, 20.25]


def test_deduced_timestamps_repeat_for_an_irregular_stream(tool, mock_outlet):
    samples = [(10.0, ["a"]), (None, ["b"]), (None, ["c"])]
    mock = mock_outlet(fmt="string", channels=1, uid=UID, samples=samples)
    pull = tool(*pull_args(mock, fmt="string", channels=1, srate=0, count=3))
    assert [pull.wait_for("sample")["t"] for _ in range(3)] == [10.0, 10.0, 10.0]


def test_uid_mismatch_is_reported(tool, mock_outlet):
    mock = mock_outlet(uid=UID)
    args = pull_args(mock, count=1)
    args[args.index("--uid") + 1] = "99999999-0000-0000-0000-000000000000"
    pull = tool(*args)
    event = pull.next_event()
    while event["event"] != "error":
        event = pull.next_event()
    assert "uidMismatch" in event["message"]


def test_outlet_closing_mid_stream_is_a_lost_stream(tool, mock_outlet):
    mock = mock_outlet(fmt="float32", channels=1, uid=UID, samples=[(1.0, [1.0])])
    pull = tool(*pull_args(mock, fmt="float32", channels=1, count=5))
    pull.wait_for("sample")
    event = pull.next_event()
    while event["event"] != "error":
        event = pull.next_event()
    assert "lost" in event["message"]


# --- L2: real liblsl --------------------------------------------------------------


FORMATS = ["float32", "double64", "int8", "int16", "int32", "int64", "string"]


@pytest.mark.interop
@pytest.mark.parametrize("fmt", FORMATS)
def test_every_format_decodes_bit_exactly_against_pylsl(tool, outlet, fmt):
    pylsl = require_pylsl()
    channels = 5
    name = f"Fmt{fmt}"
    live = outlet(name, type="Fmt", channels=channels, srate=0.0, fmt=fmt)

    if fmt == "string":
        pushed = [[f"m{k}-{i}" for k in range(channels)] for i in range(4)]
    elif fmt in ("float32", "double64"):
        pushed = [[float(k + i) * 1.5 for k in range(channels)] for i in range(4)]
    else:
        pushed = [[(-1) ** k * (k + i * 7) for k in range(channels)] for i in range(4)]

    host, port, uid, _ = pylsl_endpoint(pylsl, name)
    pull = tool(
        "pull", "--host", host, "--port", str(port), "--uid", uid,
        "--channels", str(channels), "--format", fmt, "--count", "4")
    pull.wait_for("ready")

    for values in pushed:
        live.push_sample(values)

    received = [pull.wait_for("sample")["v"] for _ in range(4)]
    if fmt == "float32":
        for got, want in zip(received, pushed):
            assert [struct.unpack("f", struct.pack("f", v))[0] for v in want] == got
    else:
        assert received == pushed
    assert pull.wait_for("done")["count"] == 4


@pytest.mark.interop
def test_float32_ramp_at_512hz_keeps_its_timestamp_deltas(tool, outlet):
    pylsl = require_pylsl()
    channels = 4
    live = outlet("Ramp", type="Ramp", channels=channels, srate=512.0, fmt="float32")
    host, port, uid, _ = pylsl_endpoint(pylsl, "Ramp")

    count = 400
    pull = tool(
        "pull", "--host", host, "--port", str(port), "--uid", uid,
        "--channels", str(channels), "--format", "float32", "--srate", "512",
        "--count", str(count))
    pull.wait_for("ready")

    stamp = pylsl.local_clock()
    for i in range(count):
        live.push_sample([float(i + k) for k in range(channels)], stamp + i / 512.0)

    samples = [pull.wait_for("sample") for _ in range(count)]
    for i, sample in enumerate(samples):
        assert sample["v"] == [float(i + k) for k in range(channels)]
    deltas = [b["t"] - a["t"] for a, b in zip(samples, samples[1:])]
    assert all(abs(d - 1 / 512.0) < 1e-6 for d in deltas), f"unexpected deltas {deltas[:5]}"


@pytest.mark.interop
def test_irregular_marker_stream(tool, outlet):
    pylsl = require_pylsl()
    live = outlet("Markers", type="Markers", channels=1, srate=0.0, fmt="string")
    host, port, uid, _ = pylsl_endpoint(pylsl, "Markers")
    pull = tool(
        "pull", "--host", host, "--port", str(port), "--uid", uid,
        "--channels", "1", "--format", "string", "--count", "3")
    pull.wait_for("ready")
    for marker in ["trial-start", "stimulus", "trial-end"]:
        live.push_sample([marker])
    assert [pull.wait_for("sample")["v"][0] for _ in range(3)] == [
        "trial-start", "stimulus", "trial-end"]


@pytest.mark.interop
def test_throughput_sanity(tool, outlet):
    """A long run must not lose samples or grow without bound."""
    pylsl = require_pylsl()
    channels = 8
    total = 20000
    live = outlet("Bulk", type="Bulk", channels=channels, srate=0.0, fmt="float32")
    host, port, uid, _ = pylsl_endpoint(pylsl, "Bulk")
    pull = tool(
        "pull", "--host", host, "--port", str(port), "--uid", uid,
        "--channels", str(channels), "--format", "float32",
        "--count", str(total), "--quiet")
    pull.wait_for("ready")

    started = time.time()
    chunk = [[float(k) for k in range(channels)] for _ in range(1000)]
    for _ in range(total // 1000):
        live.push_chunk(chunk)

    done = pull.wait_for("done", timeout=60)
    assert done["count"] == total
    assert time.time() - started < 30


@pytest.mark.interop
def test_test_pattern_matches_a_live_outlet_for_every_format(tool, outlet):
    """The gate itself: connecting at all proves the pattern matched (SCOPE.md §2.2)."""
    pylsl = require_pylsl()
    for fmt in FORMATS:
        name = f"Gate{fmt}"
        outlet(name, type="Gate", channels=3, srate=0.0, fmt=fmt)
        host, port, uid, _ = pylsl_endpoint(pylsl, name)
        pull = tool(
            "pull", "--host", host, "--port", str(port), "--uid", uid,
            "--channels", "3", "--format", fmt, "--count", "0")
        assert pull.wait_for("ready")["proto"] == "tcp"
        pull.terminate()


def test_mock_patterns_agree_with_the_specification():
    """The mock's generator is written from SCOPE.md §2.2, independently of Swift's."""
    assert pattern_values("float32", 5, 4) == [4, -5, 6, -7, 8]
    assert pattern_values("int8", 5, 4) == [5, -6, 7, -8, 9]
    assert pattern_values("int16", 3, 2) == [259, -260, 261]
    assert pattern_values("int64", 3, 4) == [
        2147483653, -2147483654, 2147483655]
    assert pattern_values("string", 4, 4) == ["10", "-11", "12", "-13"]
