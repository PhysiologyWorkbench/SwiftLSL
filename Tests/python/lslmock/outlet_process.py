"""A pylsl outlet in its own process, so a test can kill it outright.

Destroying a `StreamOutlet` in-process blocks in liblsl's destructor while an inlet is
still attached, which is not what "the device dropped off the network" looks like. Killing
a subprocess is.
"""

from __future__ import annotations

import argparse
import time

import pylsl


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--type", default="Test")
    parser.add_argument("--channels", type=int, default=1)
    parser.add_argument("--srate", type=float, default=0.0)
    parser.add_argument("--format", default="float32")
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--rate", type=float, default=50.0, help="samples per second")
    parser.add_argument("--start", type=float, default=0.0)
    arguments = parser.parse_args()

    info = pylsl.StreamInfo(
        arguments.name, arguments.type, arguments.channels, arguments.srate,
        getattr(pylsl, f"cf_{arguments.format}"), arguments.source_id)
    outlet = pylsl.StreamOutlet(info)

    print("ready", flush=True)
    value = arguments.start
    interval = 1.0 / arguments.rate
    while True:
        outlet.push_sample([value] * arguments.channels)
        value += 1
        time.sleep(interval)


if __name__ == "__main__":
    main()
