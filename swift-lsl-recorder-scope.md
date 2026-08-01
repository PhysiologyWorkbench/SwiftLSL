# Scoping brief: minimal native-Swift LSL inlet (recorder-side) implementation

## Context

A downstream project needs to record multi-stream physiological measurement data into an
HDF5 file (SWMR mode) from LSL-speaking devices. Three implementation routes were
considered for the network/protocol layer:

1. Bridge the existing desktop `liblsl` (C++, MIT-licensed, Boost/pugixml-based) via a
   Swift bridging header.
2. Reimplement the wire protocol natively in Swift, from the public specification.
3. Port `sccn/secureLSL`'s `liblsl-ESP32` component (a compact clean-room C
   reimplementation for microcontrollers) to Apple platforms.

Route 3 is now **excluded**: `secureLSL`'s licensing terms are unacceptable for a
component intended for standalone, permissive (MIT or Unlicense) release. Route 1 remains
technically viable but pulls a C++/Boost dependency into the app. This brief scopes
route 2: a minimal, native Swift implementation covering only the **recorder (inlet)
side** — stream discovery, subscription, sample/chunk reception, and time
synchronisation. Publishing (the outlet side) is out of scope.

The resulting package should be genuinely independent and useful beyond its immediate
consumer: general-purpose enough for other Swift projects that want to receive LSL
streams, not written narrowly around one downstream recorder's needs. It will eventually
feed a separate HDF5/SWMR-based recorder project, but should not depend on it or assume
anything about it.

This is a scoping exercise, not the implementation. The deliverable is a written plan.

## Hard constraint — read this first

**Do not open, clone, fetch, or otherwise consult `sccn/secureLSL` or anything hosted
under `eeglab.org/secureLSL/` in this task, for any reason, including general
orientation.** This applies regardless of how directly relevant it might seem partway
through the work. If information appears to exist only there, record it as a gap in the
report rather than looking.

Note the naming trap: `sccn/liblsl` (the desktop C++ library) is a **different,
MIT-licensed repository** and is fine to read and cite. `sccn/secureLSL` (which contains
`liblsl-ESP32`) is the one to avoid, despite the similar name. If in doubt which
repository you're looking at, stop and check the URL before reading further.

If a web search for anything LSL/Swift-related surfaces `secureLSL` or
`eeglab.org/secureLSL` results, skip them — don't open the link or read past noticing
what it is.

## Objective

Answer, in writing:

1. What is the minimal protocol subset a standards-compliant recorder actually needs —
   discovery query/response, StreamInfo XML, the TCP data-phase handshake, binary
   sample/chunk decoding for the mandated channel formats, the time-synchronisation
   exchange, and enough of the multicast-scope/`KnownPeers` machinery to be usable on a
   real LAN? Which parts (if any) can reasonably be deferred for a first version?
2. Where do the public protocol docs genuinely run out of detail — i.e., where would an
   implementation need to consult liblsl's own MIT-licensed source, or observe real
   network traffic, rather than working from prose? List every such gap found, and how
   it would be resolved.
3. What's a sensible Swift package structure: which system frameworks to build on
   (`Network.framework` for sockets/multicast, `Foundation.XMLParser` or similar for
   StreamInfo, structured concurrency vs GCD), and a first-cut module/target layout.
4. A sketch of the minimal public API surface — types and function signatures only, no
   implementation — for stream resolution, inlet creation, pulling samples/chunks, and
   exposing per-stream clock offset/correction.
5. What Apple-platform-specific constraints apply that don't exist on the reference
   desktop/embedded targets: iOS 14+'s local-network privacy prompt and its Bonjour
   service-type declaration requirement, macOS App Sandbox networking entitlements, and
   any IPv6 link-local scope-id handling quirks in `Network.framework`'s multicast
   support.
6. How should time-synchronisation be handled: live correction during recording, or
   storing raw per-sample timestamps plus periodic clock-offset samples and deferring
   alignment to a later pass? (`sccn/liblsl`'s `src/common.h`, roughly lines 77–89,
   defines post-processing sync flags; note that the reference recorder, LabRecorder,
   defers most of this to file-import time rather than doing it live — worth
   understanding why before choosing.)
7. A rough effort estimate, broken down by protocol area (discovery, data phase,
   timesync, metadata parsing, packaging/testing), in the same weekend / one–two weeks /
   longer terms as a prior assessment this follows on from.

## Primary sources (fine to read and cite)

- https://labstreaminglayer.readthedocs.io/info/intro.html
- https://labstreaminglayer.readthedocs.io/info/user_guide.html
- https://github.com/sccn/labstreaminglayer/blob/master/docs/info/network-connectivity.rst
- https://github.com/sccn/labstreaminglayer/blob/master/docs/info/lslapicfg.rst
- https://www.biorxiv.org/content/10.1101/2024.02.13.580071v1.full (Kothe et al., "The
  Lab Streaming Layer for Synchronized Multimodal Recording" — open-access preprint;
  describes the five protocols: discovery, subscription, stream transmission, metadata
  transmission, time synchronisation)
- https://github.com/sccn/liblsl (MIT-licensed C++ reference implementation — read
  `include/lsl_c.h` and `src/common.h` for anything the prose docs leave underspecified)

If any of these are unreachable, say so explicitly and name which ones — don't fill gaps
from training-data memory of how liblsl works. That's exactly the kind of unverified
claim this exercise exists to avoid.

## Steps

1. Read the protocol docs and the paper. Write out the five protocols (discovery,
   subscription, stream transmission, metadata transmission, time synchronisation) in
   your own words, with enough precision that someone could implement from your summary
   alone.
2. Flag every point where the prose doesn't give byte-level or algorithmic precision —
   e.g. the exact binary layout of a sample/chunk on the wire, or the clock-offset
   smoothing/outlier-rejection logic behind the NTP-like exchange.
3. For each flagged gap, check whether `sccn/liblsl`'s own source resolves it, and record
   the file/line. If it doesn't, or you can't tell, say so — don't guess at a plausible
   binary format.
4. Sketch the Swift package structure and public API per Objective items 3–4.
5. Investigate and record the Apple-platform constraints per Objective item 5.
6. Work through the time-sync question per Objective item 6 and record a recommendation.
7. Produce the effort estimate per Objective item 7.

## Report

Write findings to `SCOPE.md` at the repo root, containing:

- **Executive summary**: overall feasibility and effort estimate, up front.
- **Protocol coverage table**: which parts of the spec are in scope for v1, which are
  deferred, and why.
- **Documentation gaps**: a list, each with how it was (or wasn't) resolved and the
  source.
- **Proposed package structure**: targets/modules and the frameworks each depends on.
- **Proposed public API sketch**: signatures only.
- **Apple-platform constraints**: entitlements and privacy-prompt requirements needed.
- **Time-synchronisation strategy**: recommendation and reasoning.
- **Licensing note**: what MIT requires if `liblsl` source was consulted for
  gap-filling (attribution/notice, not licence to copy implementation wholesale); a
  one-line view on MIT vs Unlicense for this package, left as the user's decision.
- **Effort estimate**: by protocol area.
- **Uncertainties**: anything not resolved, stated plainly.

## Non-goals

No functioning networking code in this pass — API sketches only, no bodies. No touching
`sccn/secureLSL` in any form (see Hard constraint above). Budget roughly 30–45 minutes;
if you're well past that, stop, write up what you have, and flag what's unexamined.
