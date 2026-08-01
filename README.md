# SwiftLSL

A minimal, native-Swift implementation of the Lab Streaming Layer (LSL) protocol,
**inlet (recorder) side only**: stream discovery, subscription, sample reception,
metadata retrieval, and time synchronisation. No outlet (publishing) support.

Pure Swift over Apple system frameworks — no C++/Boost bridge, no third-party
dependencies in the library targets. Designed to be generic and reusable by any Swift
project that needs to receive LSL streams; it assumes nothing about its consumers.

## Status

Pre-implementation. The scoping work is complete; implementation follows
[ROADMAP.md](ROADMAP.md), which begins with a test-harness backbone rather than
protocol code.

## Documents

| File | Contents |
|---|---|
| [SCOPE.md](SCOPE.md) | Protocol analysis at byte level, documentation gaps, platform constraints, effort estimate. **The wire-format authority for this repository.** |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Package layout, target dependency rules, concurrency model, the `lsltool` harness contract. |
| [ROADMAP.md](ROADMAP.md) | Implementation plan: successive, independently testable steps. |
| [TESTING.md](TESTING.md) | Testing strategy: Python harness, liblsl interop, mock peers. |
| [CLAUDE.md](CLAUDE.md) | Working rules for AI-assisted sessions in this repository. |
| [swift-lsl-recorder-scope.md](swift-lsl-recorder-scope.md) | The original scoping brief that produced SCOPE.md. |

## Requirements

- macOS 13+ / iOS 16+, Swift 6.0 toolchain.
- For the test harness: Python 3.12+ with [uv](https://docs.astral.sh/uv/), and
  `liblsl` (e.g. `brew install labstreaminglayer/tap/lsl`). See
  [TESTING.md](TESTING.md).

## Building and testing

```sh
swift build
swift test                                  # Swift unit tests (no network)
cd Tests/python && uv run pytest            # protocol + interop tests
```

## Licence

MIT (per the recommendation in [SCOPE.md](SCOPE.md) §10; `LICENSE` and `NOTICE`
files land before the first tagged release — see ROADMAP step 9).
