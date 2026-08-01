"""Hour-scale soak: the manual pre-release gate of ROADMAP step 9.

`test_short_soak_loses_no_samples` is the CI-sized version of this; the long run lives
here rather than in the suite because an hour is not a unit test. It asserts the same
two properties over a duration where a leak or a slow drift becomes visible: every
pushed sample arrives, and the recorder's resident size stays bounded.

    cd Tests/python && uv run python soak.py --minutes 60

Exits 0 on success, 1 on any failed assertion, and prints a summary either way.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import threading
import time

from conftest import LslTool, REPO_ROOT

NAME = "SwiftLSLSoak"


def resident_kib(pid: int) -> int:
    output = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True
    ).stdout.strip()
    return int(output) if output else 0


def push(outlet, total: int, channels: int, rate: float, chunk: int) -> None:
    """Pushes `total` samples, pacing on the wall clock so the rate stays nominal."""
    block = [[float(c) for c in range(channels)] for _ in range(chunk)]
    start = time.monotonic()
    pushed = 0
    while pushed < total:
        size = min(chunk, total - pushed)
        outlet.push_chunk(block[:size])
        pushed += size
        due = start + pushed / rate
        delay = due - time.monotonic()
        if delay > 0:
            time.sleep(delay)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minutes", type=float, default=60.0)
    parser.add_argument("--rate", type=float, default=500.0)
    parser.add_argument("--channels", type=int, default=8)
    parser.add_argument("--chunk", type=int, default=50)
    arguments = parser.parse_args()

    import pylsl

    total = int(arguments.minutes * 60 * arguments.rate)
    info = pylsl.StreamInfo(
        NAME, "Soak", arguments.channels, arguments.rate, "float32", "swiftlsl-soak")
    outlet = pylsl.StreamOutlet(info, chunk_size=arguments.chunk)

    subprocess.run(
        ["swift", "build", "--product", "lsltool"], cwd=REPO_ROOT, check=True)
    binary = str(REPO_ROOT / ".build" / "debug" / "lsltool")

    run = LslTool(binary, "record", "--query", f"name='{NAME}'",
                  "--count", str(total), "--quiet")
    run.wait_for("ready", timeout=30)

    pusher = threading.Thread(
        target=push, args=(outlet, total, arguments.channels, arguments.rate,
                           arguments.chunk),
        daemon=True)
    pusher.start()

    # The recorder's own resident size is the thing under test: a per-sample leak at
    # this rate shows up as a monotonic climb long before the hour is out.
    samples: list[tuple[float, int]] = []
    started = time.monotonic()
    deadline = started + arguments.minutes * 60 + 120
    while pusher.is_alive() and time.monotonic() < deadline:
        elapsed = time.monotonic() - started
        samples.append((elapsed, resident_kib(run.process.pid)))
        print(f"[{elapsed / 60:6.1f} min] rss {samples[-1][1] / 1024:7.1f} MiB",
              flush=True)
        time.sleep(30)
    pusher.join(timeout=60)

    done = run.wait_for("done", timeout=120)
    run.terminate()

    settled = [kib for elapsed, kib in samples if elapsed > 60] or [s[1] for s in samples]
    first, peak = settled[0], max(settled)
    growth = peak / first if first else float("inf")

    print(f"\npushed   {total}")
    print(f"received {done['count']}")
    print(f"dropped  {done['dropped']}")
    print(f"rss      {first / 1024:.1f} MiB after 1 min -> {peak / 1024:.1f} MiB peak "
          f"({growth:.2f}x)")

    failures = []
    if done["count"] != total:
        failures.append(f"received {done['count']} of {total} samples")
    if done["dropped"] != 0:
        failures.append(f"{done['dropped']} samples dropped")
    if growth > 1.5:
        failures.append(f"resident size grew {growth:.2f}x")
    for failure in failures:
        print(f"FAIL: {failure}")
    print("PASS" if not failures else "FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
