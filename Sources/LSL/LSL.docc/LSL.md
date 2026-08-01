# ``LSL``

Receive Lab Streaming Layer streams natively in Swift.

## Overview

SwiftLSL is an LSL **inlet**: it finds outlets on the network, subscribes to one,
decodes its samples, fetches its metadata, and measures the offset between its clock and
yours. There is no outlet side — this package cannot publish a stream.

It speaks LSL protocol 1.10 over the same wire format as `liblsl`, but shares no code
with it: everything here is Swift over Foundation, Network and the BSD sockets, with no
third-party dependencies. Pre-1.10 outlets are refused with a diagnostic rather than
half-supported.

Two modules ship. `LSL` is what you normally import; it re-exports `LSLCore`, which holds
the pure codecs and can be used on its own to decode a captured stream offline.

### Receiving a stream

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

Pass the same resolver to the inlet. Recovery after an outlet restart is a re-resolve, so
the inlet needs the settings the stream was found with — `knownPeers` above all.

### Timestamps

``LSLCore/Sample/timestamp`` is raw, in the *outlet's* clock domain, and is never corrected in
place. Corrections arrive separately as a ``ClockOffset`` series:

```swift
Task {
    for await offset in inlet.clockOffsets {
        record(offset)          // localTime, remoteTime, correction, uncertainty
    }
}
```

Add ``ClockOffset/correction`` to a remote timestamp to map it into the local clock.
Keeping the two series apart means a recording can be re-aligned afterwards, with a
better fit than a live filter can produce, and that a synchronisation glitch cannot
corrupt the sample data. Call ``StreamInlet/consumeOffsetResetFlag()`` as you record: a
`true` means the outlet was replaced and the offset series is discontinuous, so the
recording must be segmented there.

### Networks that block multicast

Discovery is multicast and broadcast by default. Where that is filtered — many
institutional networks, and iOS without the multicast entitlement — name the hosts
instead:

```swift
var settings = ResolverConfiguration()
settings.knownPeers = ["rig-2.local", "192.168.1.40"]
settings.useMulticast = false
let resolver = StreamResolver(configuration: settings)
```

This path is plain unicast and needs no entitlement on any platform.

### Local network privacy

On recent Apple systems any local-network traffic is gated by a user privilege, and a
denial is *silent* on UDP: a blocked resolve returns an empty list, exactly like a
network with no outlets on it. ``StreamResolver/resolveFirst(query:timeout:)`` therefore
probes the privilege before reporting failure and puts the answer in the error:

```swift
do {
    let info = try await resolver.resolveFirst(timeout: .seconds(5))
} catch LSLError.noStreamsFound(let access) where access == .denied {
    // Tell the user to grant local network access, not to check their cabling.
}
```

``LSLCore/LocalNetworkAccess/unknown`` is a legitimate and common answer; there is no system API
that gives a definite one. See *Deployment* below, and `docs/PLATFORM-CHECKLIST.md` in
the repository, for the Info.plist keys and entitlements a shipping app needs.

### Deployment

- **macOS**: no entitlement is required for any discovery mode. Sandboxed apps need
  `com.apple.security.network.client` and `com.apple.security.network.server`.
- **iOS**: multicast and broadcast discovery require
  `com.apple.developer.networking.multicast`, which Apple grants by request. The
  `knownPeers` path needs none.
- Both: an `NSLocalNetworkUsageDescription` string, shown in the system prompt.

## Topics

### Finding streams

- ``StreamResolver``
- ``ResolverConfiguration``
- ``ResolveScope``
- ``LSLCore/StreamInfo``

### Receiving

- ``StreamInlet``
- ``InletConfiguration``
- ``LSLCore/Sample``
- ``LSLCore/SampleValues``
- ``LSLCore/ChannelFormat``

### Metadata

- ``LSLCore/MetadataElement``

### Time synchronisation

- ``ClockOffset``
- ``lslClock()``

### Diagnosing the network

- ``LocalNetwork``
- ``LSLCore/LocalNetworkAccess``
- ``NetworkInterface``
- ``NetworkInterfaces``
- ``SocketAddress``

### Errors

- ``LSLCore/LSLError``
