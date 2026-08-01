# Architecture

Code organisation and design rules for swift-lsl. Wire-format details live in
[SCOPE.md](SCOPE.md) §2 and are not repeated here; the public API shape is sketched in
SCOPE.md §7. This file covers what SCOPE does not: how the code is arranged, the rules
that keep it testable, and the harness contract that [TESTING.md](TESTING.md) builds on.

## Targets

```
swift-lsl (this repository)
├── Package.swift                    // swift-tools-version 6.0; macOS 13, iOS 16
├── Sources/
│   ├── LSLCore/                     // pure codecs — Foundation only, no I/O
│   ├── LSL/                         // transports — Network.framework, Darwin, Dispatch
│   └── lsltool/                     // CLI harness executable
├── Tests/
│   ├── LSLCoreTests/                // L0: unit tests + wire-format fixtures
│   └── LSLTests/                    // L0: transport-free logic tests
└── tests/python/                    // L1/L2: pytest harness (see TESTING.md)
```

Products: `LSLCore` and `LSL` (the latter depends on and re-exports the former).
Consumers normally import `LSL`; `LSLCore` alone is useful for offline decoding.

Module contents follow the layout in SCOPE.md §6 (StreamInfo XML, sample codec,
handshake, test patterns in `LSLCore`; resolver, inlet actor, time synchroniser,
datagram endpoint, interface enumeration, local-network probe in `LSL`).

## Dependency rules

1. **`LSLCore` imports Foundation only.** No sockets, no Dispatch, no Network. Every
   byte-level decision in the protocol is testable here without a peer, an entitlement,
   or a network stack.
2. **`LSL` imports Apple frameworks only** (Network, Darwin, Dispatch, Foundation).
   No third-party packages in either library target, ever — the package's value is
   being dependency-free.
3. **`lsltool` may depend on `swift-argument-parser`.** It is a development tool, not a
   product; the dependency does not propagate to library consumers.
4. TCP legs use `NWConnection`; UDP legs use BSD sockets behind `DatagramEndpoint`.
   Rationale in SCOPE.md §6 — the choice is API fit, not capability (SCOPE.md §8.2).

## Concurrency model

Swift 6 language mode, strict concurrency throughout.

- `StreamInlet` is an `actor`; sample delivery is `AsyncThrowingStream<Sample, Error>`,
  clock offsets an `AsyncStream<ClockOffset>` (signatures in SCOPE.md §7).
- The single `DispatchSourceRead` inside `DatagramEndpoint` is bridged to an
  `AsyncStream` at that boundary and does not leak outward.
- Everything public is `Sendable`. No locks in the public surface.
- Timeouts are `Duration`; the protocol clock is `lslClock() -> Double` (seconds,
  monotonic — see SCOPE.md §12 item 3 for the sleep/wake caveat to verify).

## Error model

One public `LSLError` enum. Design intents:

- **Lost vs timeout vs refused are distinct cases**, mirroring liblsl's `lost_error` /
  `timeout_error` split, because recorders react differently to each.
- **An empty resolve is never a bare empty list.** On Apple platforms a local-network
  denial is silent on UDP (SCOPE.md §8.2), so resolve failures carry the probed
  `LocalNetworkAccess` state (`noStreamsFound(accessState:)`).
- Protocol-version refusals (pre-1.10 outlets, SCOPE.md §4) are their own case with an
  actionable message, detected before connecting from the discovery XML.

## lsltool — the harness contract

`lsltool` is the executable surface the Python harness drives. It grows one subcommand
per roadmap step and is the *only* place the harness touches Swift code, so its output
contract must stay stable:

- **stdout is NDJSON**: one JSON object per line, machine-parsed by pytest. Nothing
  else is ever printed to stdout.
- **stderr is human diagnostics**, unparsed.
- The first event after a socket is bound is a readiness line, e.g.
  `{"event":"ready","proto":"tcp","port":16572}` — the harness blocks on it instead of
  sleeping.
- Exit code 0 on success; non-zero with a final `{"event":"error",...}` line otherwise.
- `SIGTERM` produces a prompt, clean shutdown (the harness always terminates spawned
  tools this way).

Planned subcommands (added at the roadmap step shown):

| Subcommand | Step | Purpose |
|---|---|---|
| `echo tcp` / `echo udp` | 1 | Raw byte echo; proves harness plumbing with zero protocol code |
| `resolve` | 3 | Run a resolve, emit one event per discovered stream |
| `pull --host --port --uid` | 4 | Connect to an explicit endpoint, emit decoded samples |
| `info --host --port` | 5 | Fetch and emit the full StreamInfo XML |
| `timesync --host --port` | 6 | Run probe waves, emit each measurement and the selected offset |
| `record` | 7 | Full inlet lifecycle: resolve → pull + offsets → NDJSON, with recovery |

Note `pull`/`info`/`timesync` take explicit endpoints: the Python side obtains them via
pylsl's own resolution, which keeps each roadmap step testable independently of the
Swift resolver (see [TESTING.md](TESTING.md)).

## Configuration

`ResolverConfiguration` / `InletConfiguration` structs (SCOPE.md §7) expose the same
knobs as `lsl_api.cfg` with the same defaults (SCOPE.md §2.1, §2.5). Reading the
config *file* is deferred (SCOPE.md §3); nothing in the design precludes adding it.

## Out of scope, by design

- Outlet (publishing) side.
- Protocol 1.00 (Boost portable archive) — refused with a diagnostic (SCOPE.md §4).
- XPath evaluation — outlet-side only (SCOPE.md §1).
- Live clock correction / dejittering as recorded values — raw timestamps plus an
  offset series instead (SCOPE.md §9).
