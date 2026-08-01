# Changelog

This project adheres to [Semantic Versioning](https://semver.org/). While the major
version is 0 the public API may change in a minor release; every such change is listed
here.

## [0.1.0] — 2026-08-01

First release. A complete LSL inlet for Apple platforms: discovery, subscription, sample
decoding, metadata, time synchronisation and recovery, in pure Swift with no third-party
dependencies.

### Added

- **Discovery.** `StreamResolver` with one-shot, minimum-count and continuous resolves;
  the `machine`/`link`/`site`/`organization`/`global` scopes and their TTLs;
  `KnownPeers` unicast enumeration across the port range; wave scheduling and the
  first-responder address rule (SCOPE §2.1).
- **Data phase.** `StreamInlet` over `NWConnection`: the `LSL:streamfeed/110` handshake,
  the test-pattern gate, and the protocol-1.10 record codec for all seven channel
  formats in both byte orders, including string channels, deduced timestamps and
  subnormal suppression (SCOPE §2.2–2.3).
- **Metadata.** `fetchMetadata()` over `LSL:fullinfo`, including the `<desc>` tree and
  the `created_at == 0` retry rule (SCOPE §2.4).
- **Time synchronisation.** Probe waves with wave-id filtering, min-RTT selection and a
  reply threshold; offsets published as a `ClockOffset` series with an uncertainty,
  never applied to the samples (SCOPE §2.5, §9).
- **Recovery.** A 15 s watchdog, re-resolve by `source_id`, endpoint switch, and an
  offset-reset flag a recorder must segment on. Recovery additionally requires a
  non-empty `source_id`, because liblsl's own recovery query can otherwise rebind to a
  different device that happens to match on name, type, channel count and format.
- **Apple platform hardening.** `getifaddrs` + `SIOCGIFFUNCTIONALTYPE` interface
  enumeration, per-interface discovery sends, IPv6 link-local scope handling, and
  `LocalNetwork.probe()` so an empty resolve can say whether local network access was
  the cause (SCOPE §8).
- **`LSLCore`** as a standalone product: the codecs import Foundation only and decode a
  captured stream with no network, no entitlement and no peer.
- **`lsltool`**, the NDJSON harness the Python test suites drive: `echo`, `resolve`,
  `pull`, `info`, `timesync`, `record`, `netinfo`.
- DocC documentation for the public surface, built by `Scripts/build-docs.sh`.
- `LICENSE` (MIT) and `NOTICE` recording the provenance of the protocol knowledge.

### Deliberately absent

- The outlet (publishing) side.
- Protocol 1.00, the Boost portable archive format. Pre-1.10 outlets are refused with
  their own error, detected from the discovery XML before connecting (SCOPE §4).
- XPath query evaluation, which is outlet-side only.
- Live clock correction and dejittering. Raw timestamps plus an offset series are
  recorded instead, so a recording can be aligned afterwards with a better fit than a
  causal filter can produce (SCOPE §9).
- Reading `lsl_api.cfg`. `ResolverConfiguration` and `InletConfiguration` expose the same
  knobs with the same defaults; nothing precludes adding the file later (SCOPE §3).

### Verified

- L0: `swift test`, including golden byte traces captured from live liblsl 1.16.2 and
  1.17.7 outlets, replayed through the decoders. The two releases' test patterns are
  byte-identical.
- L1: pytest against pure-Python mock peers written from SCOPE §2 alone, covering the
  edge cases liblsl cannot be made to produce — wrong test patterns, `404`/`505` status
  lines, byte-swapped decode, a 1.00 downgrade mid-handshake, malformed discovery XML,
  crafted `t1`/`t2` pinning the clock-offset sign convention, and a frozen outlet.
- L2: pytest against real liblsl through pylsl, on 1.17.7 and 1.16.2.
- An hour-long soak at 500 Hz × 8 channels: 1 800 000 samples, none lost, none dropped,
  resident size within 1.08× of its settled value throughout.

### Known limitations

Recorded rather than dropped, with the reasons, under *Carried forward* in ROADMAP steps
8 and 9: the local-network privacy prompt, denial and re-grant flows need a signed,
bundled app on a fresh user account; two-subnet discovery needs a second network; the
iOS multicast entitlement needs an Apple developer account. `docs/PLATFORM-CHECKLIST.md`
holds the manual script for the first two.
