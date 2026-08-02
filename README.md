# SwiftLSL

A minimal, native-Swift implementation of the Lab Streaming Layer (LSL) protocol,
**inlet (recorder) side only**: stream discovery, subscription, sample reception,
metadata retrieval, and time synchronisation. No outlet (publishing) support.

Pure Swift over Apple system frameworks — no C++/Boost bridge, no third-party
dependencies in the library targets. Designed to be generic and reusable by any Swift
project that needs to receive LSL streams; it assumes nothing about its consumers.

Co-authored with Claude, mostly Opus 5 but also Fable 5 at occasions.
Not thoroughly reviewed by a human.  Caveat emptor.

## Status

**v0.1.0.** All nine steps of [ROADMAP.md](ROADMAP.md) are complete. Interoperability is
verified against liblsl 1.16.2 and 1.17.7, across all seven channel formats, on loopback.
What is *not* verified on real hardware is listed under *Carried forward* in ROADMAP
steps 8 and 9 — chiefly the local-network privacy prompt flows, which no automated test
can reach, and discovery across two subnets.

## Usage

```swift
import LSL

let resolver = StreamResolver()
let info = try await resolver.resolveFirst(query: "type='EEG'", timeout: .seconds(5))

let inlet = try StreamInlet(info, resolver: resolver)
try await inlet.open()

for try await sample in inlet.samples {
    print(sample.timestamp, sample.values)
}
```

Timestamps are delivered raw, in the outlet's clock domain; clock corrections arrive as a
separate `inlet.clockOffsets` series, so a recording can be aligned afterwards rather
than filtered live. On networks that block multicast — and on iOS without the multicast
entitlement — set `ResolverConfiguration.knownPeers` and `useMulticast = false`.

## Documents

| File | Contents |
|---|---|
| [SCOPE.md](SCOPE.md) | Protocol analysis at byte level, documentation gaps, platform constraints, effort estimate. **The wire-format authority for this repository.** |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Package layout, target dependency rules, concurrency model, the `lsltool` harness contract. |
| [ROADMAP.md](ROADMAP.md) | Implementation plan: successive, independently testable steps, and what each one left undone. |
| [TESTING.md](TESTING.md) | Testing strategy: Python harness, liblsl interop, mock peers, the release interop matrix. |
| [CHANGELOG.md](CHANGELOG.md) | Release history. |
| [docs/PLATFORM-CHECKLIST.md](docs/PLATFORM-CHECKLIST.md) | Local network privacy: Info.plist and entitlement templates, and the manual test script the automated suites cannot replace. |
| [CLAUDE.md](CLAUDE.md) | Working rules for AI-assisted sessions in this repository. |
| [swift-lsl-recorder-scope.md](swift-lsl-recorder-scope.md) | The original scoping brief that produced SCOPE.md. |

## Requirements

- macOS 13+ / iOS 16+, Swift 6.0 toolchain.
- For the test harness: Python 3.12+ with [uv](https://docs.astral.sh/uv/). The pylsl
  wheel bundles its own `liblsl`, so no separate install is needed. See
  [TESTING.md](TESTING.md).

## Building and testing

```sh
swift build
swift test                                  # Swift unit tests (no network)
cd Tests/python && uv run pytest            # protocol + interop tests
Scripts/build-docs.sh                       # DocC archive into .build/documentation
```

## Licence

MIT — see [LICENSE](LICENSE). [NOTICE](NOTICE) records the provenance of the protocol
knowledge: the wire format was reconstructed from the public documentation and from
reading `sccn/liblsl` (MIT, © 2012 Christian A. Kothe), but no code was taken from it.
