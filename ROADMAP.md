# Roadmap

Implementation plan for swift-lsl. Each step is independently testable and lands only
with its exit criteria green. Protocol facts referenced below are specified in
[SCOPE.md](SCOPE.md) §2; test levels (L0 Swift unit / L1 mock-peer / L2 liblsl
interop) are defined in [TESTING.md](TESTING.md); target layout and the `lsltool`
contract in [ARCHITECTURE.md](ARCHITECTURE.md).

Dependency shape: step 1 → step 2 → steps 3–6 (mutually independent) → step 7 →
steps 8–9. Steps 3–6 can be done in any order or interleaved, because the harness
feeds each one endpoints resolved via pylsl rather than via our own resolver.

Status key: `[ ]` not started · `[~]` in progress · `[x]` done.

---

## [ ] Step 1 — Harness backbone (no protocol code)

**Goal.** A Swift executable a Python test can spawn, synchronise with, talk bytes to,
and shut down — before any LSL code exists. This proves the entire build/test loop:
SwiftPM targets, NDJSON contract, process lifecycle, pytest plumbing.

**Deliverables.**
- `Package.swift` with empty-but-compiling `LSLCore`, `LSL`, `lsltool`, and both Swift
  test targets; platforms macOS 13 / iOS 16, tools 6.0.
- `lsltool echo tcp [--port N]` — bind, emit `ready` event, accept one connection,
  echo bytes until EOF, emit a `closed` event with byte count.
- `lsltool echo udp [--port N]` — bind, emit `ready`, echo each datagram to its
  sender, emit per-datagram events.
- `tests/python/` scaffold: `pyproject.toml` (uv-managed), `conftest.py` with an
  `LslTool` fixture (spawn, wait-for-ready, NDJSON reader, SIGTERM teardown).
- pytest tests: TCP echo round-trip, UDP echo round-trip (including a >1400-byte
  datagram), ready-event port parsing, clean SIGTERM exit.
- `.gitignore` for `.build/`, `.venv/`, `__pycache__/`, `.DS_Store`.

**Exit criteria.** `swift build`, `swift test` (one placeholder test per target) and
`uv run pytest` all green on macOS, from a terminal, with no manual steps.

---

## [ ] Step 2 — LSLCore: wire codecs (no networking)

**Goal.** Every byte-level protocol decision implemented and unit-tested in pure Swift.

**Deliverables** (all in `LSLCore`; SCOPE §2 references in brackets):
- `ChannelFormat`, `StreamInfo`, `XMLElement`; StreamInfo XML decode/encode via
  `XMLParser`, including the `<desc>` tree and the `version × 100` quirk [§2.4].
- Query-string construction (`session_id` + predicates) [§2.1].
- Sample record codec: timestamp tag byte, deduced-timestamp rule, all six numeric
  formats in both byte orders, string channels with width-prefixed lengths, subnormal
  suppression [§2.3].
- Test-pattern generator (offsets 4 and 2, per-format biases) and sample equality
  [§2.2].
- Handshake: streamfeed request formatting, response status-line and header parsing —
  lower-casing, `;` comments, `Byte-Order: 0` remap [§2.2].
- Discovery and timedata message formatting/parsing [§2.1, §2.5] — the text framing
  only; no sockets.
- `LSLError` (see ARCHITECTURE.md, *Error model*).

**Exit criteria.** L0 tests green: round-trip property tests per format; fixture
tests against hand-built byte vectors transcribed from SCOPE §2; test-pattern vectors
for all seven formats × both endiannesses; handshake parse of the exact header
blocks in SCOPE §2.2 including the quirks. `LSLCore` still imports Foundation only.

---

## [ ] Step 3 — Discovery

**Goal.** Resolve real streams on the LAN and loopback.

**Deliverables.**
- `DatagramEndpoint` (BSD socket + `DispatchSourceRead` → `AsyncStream`).
- `StreamResolver`: one-shot and continuous resolves, wave scheduling, scope address
  sets and TTLs, `KnownPeers` unicast enumeration, first-responder address rule
  [SCOPE §2.1].
- `lsltool resolve [--query …] [--timeout …] [--known-peer host]`.

**Tests.**
- L1: Python mock outlet responder — asserts our query packet's exact three-line
  framing and return-port field, replies with canned shortinfo XML; cases for
  non-matching query id (must be ignored), duplicate UID (address must not be
  overwritten), malformed XML (must not crash the wave).
- L2: pylsl outlet on loopback resolved by type and by name; `KnownPeers=[localhost]`
  with multicast targets disabled; continuous resolve sees an outlet appear and
  expire.

**Exit criteria.** All above green; resolve of a pylsl outlet completes in < 2 s on
loopback.

---

## [ ] Step 4 — Data phase

**Goal.** Pull correctly decoded samples from a real liblsl outlet.

**Deliverables.**
- TCP transport over `NWConnection` (no-delay set, length-aware reads).
- Handshake execution, test-pattern validation gate, continuous sample decode loop,
  deduced-timestamp materialisation [SCOPE §2.2–2.3].
- Protocol-1.00 refusal with distinct error, both pre-connect (from discovery XML)
  and mid-handshake (server downgrade) [SCOPE §4].
- `lsltool pull --host H --port P --uid U --count N` (endpoint supplied by the
  harness via pylsl; independent of step 3).

**Tests.**
- L1: Python mock outlet server with scripted handshake — wrong test pattern
  (connection must be refused), `404`/`505` status lines, `Byte-Order: 4321` forcing
  byte-swapped decode, `Data-Protocol-Version: 100` downgrade, string channels,
  deduced timestamps.
- L2: pylsl outlets — float32 ramp at 512 Hz (values and timestamp deltas asserted),
  irregular string marker stream, int16/int32/double64 streams; a 10⁶-sample
  throughput sanity run.
- Capture golden byte traces of one handshake + first samples per format via the
  harness's recording proxy into `Tests/LSLCoreTests/Fixtures/` (see TESTING.md).

**Exit criteria.** All formats decode bit-exactly against pylsl; every L1 edge case
behaves as specified.

---

## [ ] Step 5 — Metadata

**Goal.** Full StreamInfo including the `<desc>` subtree.

**Deliverables.** `LSL:fullinfo` fetch on a fresh TCP connection, read-to-EOF,
`created_at == 0` retry rule [SCOPE §2.4]; `StreamInlet.fetchMetadata()` plumbing
(the actor itself arrives in step 7 — until then, a free function + `lsltool info`).

**Tests.** L2: pylsl outlet with channel labels/units/type in `desc`; assert the tree
round-trips node-for-node. L1: mock serving a >64 KiB desc (chunked reads), and an
invalid-info response (retry then fail).

**Exit criteria.** Above green. Small step; may be folded into the same working
session as step 4, but lands as its own commit with its own tests.

---

## [ ] Step 6 — Time synchronisation

**Goal.** Clock-offset measurement with the correct sign, filter, and cadence.

**Deliverables.** `TimeSynchroniser`: probe waves (8 × 64 ms), wave-id filtering,
min-RTT selection, ≥ 6-reply threshold, 2 s cadence, negated-offset publication,
uncertainty, reset flag on endpoint change [SCOPE §2.5]; `lsltool timesync --host
--port --waves N`.

**Tests.**
- L1: scripted Python time server returning *crafted* `t1`/`t2` so the expected
  offset and RTT are exact constants — this is the test that pins the sign convention
  (SCOPE gap #8) and the formulas; plus stale-wave-id rejection and
  insufficient-replies (no publication) cases.
- L2: pylsl outlet on loopback; measured |offset| < 5 ms and uncertainty < 5 ms
  across 10 waves.

**Exit criteria.** Sign-convention test green against scripted vectors *before* the
L2 test is even run; then both green.

---

## [ ] Step 7 — Inlet assembly: recovery, watchdog, public API

**Goal.** The `StreamInlet` actor per SCOPE §7, wiring steps 3–6 together into the
deliverable API.

**Deliverables.**
- `StreamInlet` (open/close, `pullSample`, `pullChunk`, `samples` stream,
  `clockOffset`, `clockOffsets` stream, `consumeOffsetResetFlag`).
- Recovery: watchdog (15 s no-data), re-resolve by recovery query [SCOPE §2, gap
  #16], endpoint switch, offset reset signalling.
- `StreamResolver`/`StreamInlet` integration; `lsltool record --query … --duration …`
  emitting samples and offsets as NDJSON.

**Tests.**
- L2: kill and restart a pylsl outlet (same `source_id`) mid-stream → inlet recovers,
  sample flow resumes, reset flag observed exactly once.
- L1: mock outlet that freezes (accepts, then stops sending) → watchdog triggers
  re-resolve; mock without `source_id` → no recovery, `lost` error surfaced.
- L2 soak: 10-minute loopback recording, zero sample loss, bounded memory (CI runs a
  shortened variant; the full hour-scale soak is a manual pre-release gate, step 9).

**Exit criteria.** Recovery and watchdog tests green; public API compiles against the
signatures in SCOPE §7 (deviations documented there).

---

## [ ] Step 8 — Apple platform hardening

**Goal.** Behave correctly under local-network privacy and on multi-homed hosts
[SCOPE §8].

**Deliverables.**
- `NetworkInterfaces`: `getifaddrs` + `SIOCGIFFUNCTIONALTYPE` enumeration; discovery
  sends from every broadcast-capable interface; IPv6 link-local scope-id handling.
- `LocalNetworkProbe` and `LocalNetworkAccess`; resolver failures carry access state.
- Resolver deliberately does **not** fail fast (short-lived-process prompt trap,
  SCOPE §8.3).
- `docs/PLATFORM-CHECKLIST.md`: manual test script for the privacy prompt, denial,
  and re-grant flows on a bundled macOS app and an iOS device (`KnownPeers` mode);
  Info.plist and entitlement templates for consumers.
- Empirical answer to SCOPE §12 item 1 (does UDP `NWConnection` surface
  `.localNetworkDenied`?) recorded in SCOPE.md.

**Tests.** L2 on a two-interface Mac (Wi-Fi + Ethernet): outlet reachable via each
interface is resolved. Privacy-prompt flows are manual by necessity (terminal
processes are auto-allowed; the macOS privilege cannot be reset programmatically —
SCOPE §8.3): the checklist is the test artefact.

**Exit criteria.** Multi-interface resolve green; checklist executed once with
results recorded in it; iOS multicast entitlement *requested* (approval is external
and does not block — `KnownPeers` mode needs none).

---

## [ ] Step 9 — Release readiness

**Goal.** Something a stranger can depend on.

**Deliverables.** DocC for the public surface; API audit against SCOPE §7; `LICENSE`
(MIT) + `NOTICE` (liblsl attribution per SCOPE §10); interop matrix run against at
least two liblsl release versions (current Homebrew release + the oldest version
found on target devices); hour-scale soak (step 7); CHANGELOG; tag `v0.1.0`.

**Exit criteria.** Matrix green; docs build; tag pushed.

---

## Estimates

Per-area figures and the overall three-to-five-week envelope are in SCOPE.md §11.
Rough mapping: step 1 ≈ a day; step 2 ≈ a weekend; steps 3–6 ≈ a weekend each
including their mocks; step 7 ≈ 3–4 days; step 8 ≈ 3–4 days plus external entitlement
latency; step 9 ≈ 2–3 days plus the interop-matrix tail.
