# Testing

Testing strategy for SwiftLSL. The `lsltool` output contract the harness relies on is
specified in [ARCHITECTURE.md](ARCHITECTURE.md); which tests land at which step is in
[ROADMAP.md](ROADMAP.md).

## Principle: triangulation

The Swift implementation is checked against two independent references from the start:

1. **liblsl itself**, via [pylsl](https://pypi.org/project/pylsl/) — pylsl is a thin
   ctypes binding over the reference C++ implementation, so every interop test is a
   test against real liblsl behaviour, timing and bytes.
2. **Pure-Python mock peers**, written from [SCOPE.md](SCOPE.md) §2 *alone*, without
   consulting liblsl source. These give deterministic, scriptable tests (exact byte
   assertions, fault injection, crafted timestamps) that liblsl cannot provide.

If Swift agrees with the mocks *and* Swift agrees with liblsl, then SCOPE §2 itself is
validated as a sufficient specification — which was the point of the scoping exercise.
Any three-way disagreement is investigated against liblsl source and fixed in SCOPE.md
first, code second.

## Test levels

| Level | Runner | Peers | Network | What it proves |
|---|---|---|---|---|
| **L0** | `swift test` | none | none | Byte codecs, XML, handshake parsing (`LSLCore`); transport-free logic |
| **L1** | pytest | Python mocks | loopback | Protocol conformance to SCOPE §2, edge cases, fault handling |
| **L2** | pytest | pylsl / liblsl | loopback (LAN for step 8) | Interoperability with the reference implementation |

L0 lives in `Tests/`; L1 and L2 live in `Tests/python/`. Every roadmap step must add
tests at the lowest level that can express its behaviour — network tests never cover
what a unit test could.

(The Python harness sits under `Tests/` rather than a sibling `tests/` because macOS's
default APFS is case-insensitive: the two would be one directory, and `git` would
normalise the paths anyway.)

## Layout

```
Tests/python/
├── pyproject.toml          # uv project: pytest, pylsl
├── conftest.py             # LslTool fixture: spawn, wait-for-ready, NDJSON, SIGTERM
├── capture_fixture.py      # golden-trace capture, one fixture per liblsl release
├── soak.py                 # hour-scale pre-release soak (step 9)
├── lslmock/                # mock peers, written from SCOPE.md §2 only
│   ├── responder.py        # discovery: answers LSL:shortinfo with canned XML
│   ├── outlet.py           # data phase: scripted handshake + sample bytes
│   ├── outlet_process.py   # a pylsl outlet in its own process, killable mid-stream
│   ├── inforesponder.py    # LSL:fullinfo: chunked and invalid documents
│   └── timeserver.py       # timedata: crafted t1/t2 replies
└── tests/
    ├── test_harness.py     # step 1
    ├── test_resolve.py     # step 3
    ├── test_pull.py        # step 4
    ├── test_info.py        # step 5
    ├── test_timesync.py    # step 6
    ├── test_inlet.py       # step 7
    └── test_platform.py    # step 8
```

## Setup

```sh
cd Tests/python
uv sync                                     # pytest + pylsl, which bundles liblsl
uv run pytest                               # everything
uv run pytest -m "not interop"              # L1 only (no liblsl needed)
```

The pylsl wheel ships its own `liblsl.dylib`, so no Homebrew install is needed; a
system-wide liblsl works too. `PYLSL_LIB` overrides the search path, which is how the
release interop matrix runs. L2 tests carry `@pytest.mark.interop` and skip with a clear
message when pylsl cannot load liblsl at all.

**Run the suite on an otherwise quiet machine.** The L1 mocks bind the discovery port
range (16572+) and assert on every datagram they receive, so any other LSL process on the
host — another test run, a stray `lsltool`, a soak — makes them fail on a request that
was never meant for them.

## Harness conventions

- The `LslTool` fixture is the only way tests run Swift code: spawn `lsltool`, block
  on the `ready` NDJSON event, interact, `SIGTERM`, assert exit 0. No sleeps for
  synchronisation, ever — readiness and progress come from NDJSON events.
- Endpoints for `pull`/`info`/`timesync` tests are obtained on the Python side, by
  resolving the pylsl outlet with pylsl itself and reading `v4address`/ports from its
  info XML. This is what keeps roadmap steps 3–6 mutually independent.
- All peers bind loopback and ephemeral or explicitly-passed ports; tests are
  parallel-safe and leave no state.
- Mock peers assert on *our* bytes as rigorously as we assert on theirs — a mock that
  accepts a malformed query is a test bug.

## Golden traces and the release interop matrix

`capture_fixture.py` connects to a live pylsl outlet, performs a real
`LSL:streamfeed/110` handshake built from SCOPE §2 alone, and commits the response header
plus the two test-pattern records — one trace per channel format — to
`Tests/LSLCoreTests/Fixtures/test-patterns-liblsl-<version>.json`. L0 tests replay every
committed fixture through the `LSLCore` decoders, so reference bytes from each liblsl
release are exercised on every `swift test` run, without Python or a network.

That is the durable half of the release interop matrix: it keeps proving old releases
after the dylib that produced it is gone. The other half is running the L2 suite against
each version in turn:

```sh
cd Tests/python
uv run pytest                                          # bundled liblsl
PYLSL_LIB=/path/to/other/liblsl.dylib uv run pytest    # a second release
PYLSL_LIB=/path/to/other/liblsl.dylib uv run python capture_fixture.py
```

An older release generally has to be built from source; `sccn/liblsl` needs
`-DLSL_UNITTESTS=OFF -DLSL_BUILD_EXAMPLES=OFF` to configure standalone. `capture_fixture.py`
refuses to overwrite an existing fixture: a changed fixture must be explainable.

## The soak

`soak.py` is the pre-release gate that the suite's `test_short_soak_loses_no_samples` is
a CI-sized version of. It pushes at a nominal rate for an hour and asserts that every
sample arrives, none is dropped, and the recorder's resident size stays bounded:

```sh
cd Tests/python && uv run python soak.py --minutes 60
```

## Platform caveats for local runs and CI

From SCOPE.md §8.3, consequences worth knowing before trusting a green run:

- Terminal-launched processes (including `swift test`, pytest, and everything they
  spawn) are **automatically granted** local-network access on macOS. CI therefore
  needs no privacy configuration — but by the same token it exercises none of the
  denial paths. Those are covered by the manual checklist in roadmap step 8.
- The iOS simulator does not implement local-network privacy at all; nothing in this
  harness makes claims about iOS devices.
- All L1/L2 traffic is loopback; multicast tests use `ResolveScope` machine/link on
  `127.0.0.1` targets where possible to keep CI hosts quiet on shared networks.
