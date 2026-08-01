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

L0 lives in `Tests/`; L1 and L2 live in `tests/python/`. Every roadmap step must add
tests at the lowest level that can express its behaviour — network tests never cover
what a unit test could.

## Layout

```
tests/python/
├── pyproject.toml          # uv project: pytest, pylsl
├── conftest.py             # LslTool fixture: spawn, wait-for-ready, NDJSON, SIGTERM
├── lslmock/                # mock peers, written from SCOPE.md §2 only
│   ├── responder.py        # discovery: answers LSL:shortinfo with canned XML
│   ├── outlet.py           # data phase: scripted handshake + sample bytes
│   ├── timeserver.py       # timedata: crafted t1/t2 replies
│   └── proxy.py            # byte-recording TCP proxy for golden-trace capture
└── tests/
    ├── test_harness.py     # step 1
    ├── test_resolve.py     # step 3
    ├── test_pull.py        # step 4
    ├── test_info.py        # step 5
    ├── test_timesync.py    # step 6
    └── test_inlet.py       # step 7
```

## Setup

```sh
brew install labstreaminglayer/tap/lsl      # liblsl dylib
cd tests/python
uv sync
uv run pytest                               # everything
uv run pytest -m "not interop"              # L1 only (no liblsl needed)
```

L2 tests carry `@pytest.mark.interop` and skip with a clear message when pylsl cannot
load liblsl (`PYLSL_LIB` overrides the search path if needed).

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

## Golden traces

Step 4 captures real liblsl handshake/sample bytes through `lslmock/proxy.py` into
`Tests/LSLCoreTests/Fixtures/` (one trace per channel format, committed). L0 tests
replay them through the `LSLCore` decoders, so reference bytes are exercised on every
`swift test` run without Python or a network. Re-capture only deliberately — e.g.
against a new liblsl release for the step 9 interop matrix — since changed fixtures
must be explainable.

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
