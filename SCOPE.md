# Scope: minimal native-Swift LSL inlet (recorder side)

Assessment date: 2026-08-01.
Reference implementation consulted: `sccn/liblsl` @ `e651023` (2026-06-17), MIT.
`sccn/secureLSL` / `eeglab.org/secureLSL` was **not** consulted, per the brief's hard constraint.

---

## 1. Executive summary

**Feasible, and the protocol is smaller than its reputation suggests.** The recorder-side
subset is five short text-framed exchanges plus one trivially simple binary sample record.
There is no compression, no framing layer, no encryption, no state machine worth the name.
A single afternoon of reading `liblsl` pins down every byte.

**Effort: one weekend to a prototype that resolves and records a real `float32` stream;
three to five focused weeks to a v1 you would trust in an actual recording session.**
The protocol work is roughly one of those weeks. The rest is interoperability testing
against real `liblsl` peers, reconnection/recovery behaviour, and Apple platform plumbing.

Three findings materially change the shape of the job:

1. **The inlet needs no XPath engine.** Query matching is performed entirely by the
   *outlet* (`src/stream_info_impl.cpp:193-243`). The inlet only *constructs* query strings
   and *parses* returned XML. This removes the single hardest dependency — `XMLDocument`
   with XPath support does not exist on iOS.
2. **"Chunks" are not a wire concept.** They are sender-side write batching only
   (`src/tcp_server.cpp:764-803`); the receiver reads a flat sequence of sample records
   (`src/data_receiver.cpp:312-330`). `pullChunk` on the inlet is purely local aggregation.
3. **The multicast entitlement is an iOS-only problem, and even there it is avoidable.**
   TN3179 states plainly: "The multicast entitlement isn't required on macOS." macOS needs
   only the local network privacy prompt. On iOS, `com.apple.developer.networking.multicast`
   is required — but it gates *sending* multicast/broadcast only; the `KnownPeers` unicast
   discovery path needs no entitlement whatsoever (TN3179, *Multicast operations*: UDP
   unicast send and receive are both "no"). See §8.

Main risk is not technical difficulty; it is the long tail of interop against outlets
produced by a decade of `liblsl` versions.

One design consequence deserves flagging up front: on Apple platforms **there is no API to
ask whether you have local network access** (TN3179, FB8711182). The only documented signal
is `NWConnection`'s `unsatisfiedReason == .localNetworkDenied`. A denial on a raw UDP socket
is invisible — sends appear to succeed and replies simply never arrive, which is byte-for-byte
indistinguishable from "no outlets on this LAN". The package must therefore carry a
deliberate `NWConnection`-based authorisation probe; see §6 and §8.2.

---

## 2. The five protocols, precisely

All ports below are defaults from `docs/info/lslapicfg.rst` and `src/api_config.cpp:160-163`.

### 2.1 Discovery (UDP, port 16571)

Inlet binds a UDP socket (tries 16572–16603, falls back to an OS-assigned port —
`src/socket_utils.cpp:5-25`; **an inlet therefore has no port-range requirement**) and sends
to each configured multicast/broadcast/unicast target:

```
LSL:shortinfo\r\n
<query>\r\n
<return_port> <query_id>\r\n
```

`<query>` is an XPath 1.0 boolean expression evaluated by the outlet against its `<info>`
element, e.g. `session_id='default' and type='EEG'` (`src/resolver_impl.cpp:66-73`).
`<return_port>` is the port the inlet listens on. `<query_id>` is an **opaque echo token** —
`liblsl` uses `std::to_string(std::hash<std::string>()(query))`
(`src/resolve_attempt_udp.cpp:51`), but since the responder only echoes it back
(`src/udp_server.cpp:140`) and the querier compares it against its own value
(`src/resolve_attempt_udp.cpp:116`), any unique string works. Do not attempt to reproduce
libstdc++'s hash.

A matching outlet replies **unicast** to `<return_port>` on the querying address:

```
<query_id>\r\n<shortinfo XML>
```

The inlet records the source address of the reply as the stream's `v4address`/`v6address`,
and does **not** overwrite it if a second reply arrives for the same UID — first responder
wins, on the assumption it is the faster route (`src/resolve_attempt_udp.cpp:121-141`).

Target sets by `ResolveScope` (`src/api_config.cpp:188-263`), cumulative, with TTL:

| Scope | Adds | TTL |
|---|---|---|
| machine | `127.0.0.1` | 0 |
| link | `255.255.255.255`, `224.0.0.1`, `224.0.0.183`, `FF02:113D:6FDD:2C17:A643:FFE2:1BD1:3CD2` | 1 |
| **site (default)** | `239.255.172.215`, `FF05:113D:6FDD:2C17:A643:FFE2:1BD1:3CD2` | 24 |
| organization | `FF08:…` | 32 |
| global | `FF0E:…` | 255 |

IPv6 group addresses are composed as `FF0x:` + `IPv6MulticastGroup`
(default `113D:6FDD:2C17:A643:FFE2:1BD1:3CD2`).

`KnownPeers` bypasses multicast: each named host is resolved and enumerated across
`BasePort … BasePort+PortRange` (16572–16603), then queried by unicast
(`src/resolver_impl.cpp:36-47`).

Wave scheduling: multicast burst, then (if peers exist) a unicast burst after
`MulticastMinRTT` (0.5 s), then the next wave (`src/resolver_impl.cpp:172-194`).
One-shot resolves stop early once `minimum` results have arrived and `minimum_time` elapsed.

### 2.2 Subscription / data-phase handshake (TCP, `v4data_port`)

Inlet sends a request line and RFC-822-ish headers, blank line terminated:

```
LSL:streamfeed/<proposedVersion> <UID>\r\n
Native-Byte-Order: 1234\r\n
Endian-Performance: <float>\r\n
Has-IEEE754-Floats: 1\r\n
Supports-Subnormals: 1\r\n
Value-Size: <bytes per channel value, 0 for string>\r\n
Data-Protocol-Version: <proposedVersion>\r\n
Max-Buffer-Length: <samples>\r\n
Max-Chunk-Length: <samples>\r\n
Hostname: <…>\r\n
Source-Id: <…>\r\n
Session-Id: <…>\r\n
\r\n
```

(`src/data_receiver.cpp:168-190`.) `proposedVersion = min(ourMax, streamInfo.version)`;
`streamInfo.version` comes from the `<version>` XML field × 100.

Outlet replies:

```
LSL/<version> 200 OK\r\n
UID: <uid>\r\n
Byte-Order: <1234|4321>\r\n
Suppress-Subnormals: <0|1>\r\n
Data-Protocol-Version: <100|110>\r\n
\r\n
```

(`src/tcp_server.cpp:671-678`.) Status codes: `404` = wrong stream (UID mismatch, stale
resolve), `≥400` = error, `≥300` = redirect (treated as lost), `505` = version unsupported.
Version comparison is by *major* (`v/100`), not exact (`src/data_receiver.cpp:199-203`).

Quirks that must be replicated:
- `Byte-Order: 0` means "portable" and must be remapped to *native*, for interop with
  `liblsl` ≈1.13 (`src/data_receiver.cpp:231`).
- Header keys are lower-cased before matching, and anything after `;` is stripped as a
  comment (`src/data_receiver.cpp:219-226`).
- `Max-Buffer-Length: 0` causes the outlet to send the header and then stop
  (`src/tcp_server.cpp:730`).

Then **two test-pattern samples** are sent by the outlet, with offsets `4` and `2` in that
order, which the inlet must generate independently and compare for exact equality
(`src/tcp_server.cpp:695-706`, `src/data_receiver.cpp:276-297`). Generation is
`src/sample.cpp:356-405`: timestamp is exactly `123456.789`; per format, value `k` is
`±(k + offset + formatBias)` with alternating sign (even indices positive), and
`formatBias` is `0` for `float32`, `16777217` for `double64`, `65537` for `int32`, `257` for
`int16`, `1` for `int8`, `2147483649` for `int64`; integers are taken modulo `T::max`;
`string` channels ignore the offset entirely and use `to_string((k+10) * (k%2==0 ? 1 : -1))`.
Equality includes the timestamp (`src/sample.cpp:97-106`). This is a hard gate: fail it and
the connection is dropped as protocol-incompatible.

### 2.3 Stream transmission (same TCP connection, protocol 1.10)

After the test patterns, a **continuous, unframed sequence of sample records**. Per record
(`src/sample.cpp:189-282`):

```
uint8  tag            ; 1 = deduced timestamp, 2 = transmitted timestamp
[f64   timestamp]     ; present only if tag == 2
<channel data>        ; channel_count values, tightly packed, no padding
```

Numeric channels are raw little- or big-endian values per the negotiated `Byte-Order`;
sizes are `float32`=4, `double64`=8, `int8`=1, `int16`=2, `int32`=4, `int64`=8
(`src/sample.h:22-23`). String channels are length-prefixed with a variable-length integer:
one byte giving the *width* of the length field (1, 2, 4 or 8), then the length in that
width, then the raw bytes (`src/sample.cpp:199-216`, `240-261`). The writer never emits
width 2; the reader accepts it.

`tag == 1` means "successive timestamp": `t = lastTimestamp + (srate > 0 ? 1/srate : 0)`
(`src/data_receiver.cpp:320-325`). The sentinel value is `-1.0`
(`include/lsl/common.h:48`) but it never appears on the wire.

If `Suppress-Subnormals: 1` was negotiated, the receiver flushes subnormal floats to
signed zero after decoding (`src/sample.cpp:267-280`).

There is **no chunk header, no sample count, no length prefix**. The 1.00 protocol is a
Boost EOS `portable_binary_archive` stream instead — see §4 for why v1 should refuse it.

### 2.4 Metadata (TCP, `v4data_port`, separate connection)

```
LSL:fullinfo\r\n
```

Outlet writes the complete `<info>` XML including the `<desc>` subtree and closes; the
inlet reads to EOF (`src/info_receiver.cpp:60-68`, `src/tcp_server.cpp:508-514`).
A `created_at` of `0.0` means the response was not a valid stream info; retry.

`LSL:shortinfo\r\n<query>\r\n` over TCP is also supported and returns the `<desc>`-less
form if the query matches, otherwise closes (`src/tcp_server.cpp:502-507`, `537-558`).

StreamInfo XML field order and names (`src/stream_info_impl.cpp:60-83`): `name`, `type`,
`channel_count`, `channel_format`, `source_id`, `nominal_srate`, `version`, `created_at`,
`uid`, `session_id`, `hostname`, `v4address`, `v4data_port`, `v4service_port`, `v6address`,
`v6data_port`, `v6service_port`, `desc`. `channel_format` is one of `undefined`, `float32`,
`double64`, `string`, `int32`, `int16`, `int8`, `int64` — note the ordinal order does *not*
match the readable order. `version` is written as `version/100.0` (i.e. `1.1`) and parsed
back as `stod(...) * 100`.

### 2.5 Time synchronisation (UDP, `v4service_port`)

Inlet sends, with 16 significant digits:

```
LSL:timedata\r\n<wave_id> <t0>\r\n
```

Outlet replies (note the **leading space** and absence of a trailing newline):

```
 <wave_id> <t0> <t1> <t2>
```

where `t1` is the outlet's receive time and `t2` its send time
(`src/time_receiver.cpp:131-152`, `src/udp_server.cpp:152-168`). On receipt the inlet takes
`t3` and computes:

```
rtt    = (t3 - t0) - (t2 - t1)
offset = ((t1 - t0) + (t2 - t3)) / 2
```

A "wave" is `TimeProbeCount` = 8 probes at `TimeProbeInterval` = 0.064 s. After
`TimeProbeMaxRTT + TimeProbeInterval × TimeProbeCount` = 0.64 s, if at least
`TimeUpdateMinProbes` = 6 replies arrived, the **minimum-RTT estimate wins** (NTP clock
filter) and is published as `timeOffset = -offset`, `uncertainty = rtt`
(`src/time_receiver.cpp:187-210`). **Note the negation** — the published correction is
"local − remote", so adding it maps outlet timestamps into the local clock. Waves repeat
every `TimeUpdateInterval` = 2.0 s. Non-matching `wave_id`s are discarded, which is how
stale replies from a previous wave are rejected.

The local clock is `std::chrono::steady_clock` in nanoseconds, divided down with integer
arithmetic to preserve precision (`src/common.cpp:19-21`, `44-51`).

---

## 3. Protocol coverage table

| Area | v1 | Rationale |
|---|---|---|
| Discovery: link + site scope, IPv4 multicast + broadcast | **In** | Covers essentially every real lab LAN. |
| Discovery: IPv6 `FF02:`/`FF05:` groups | **In** | Cheap once the send path exists; macOS enables IPv6 by default in recent `liblsl`. |
| Discovery: `KnownPeers` unicast | **In** | The documented escape hatch when multicast is blocked; ~20 lines. |
| Discovery: send from *every* broadcast-capable interface | **In** *(promoted)* | `liblsl` iterates all interfaces (`src/resolve_attempt_udp.cpp:160-195`), and TN3179 (*Identify the Wi-Fi interface correctly*) explicitly directs custom discovery protocols to "run your service discovery code on *all* broadcast-capable interfaces", warning that BSD names like `en0` "aren't considered API on any Apple platform". Enumerate with `getifaddrs` and filter by `SIOCGIFFUNCTIONALTYPE`; never hard-code names. |
| Discovery: organization/global scope, `TTLOverride` | **Defer** | Configuration surface, no new protocol. |
| Continuous (background) resolver | **In** | A recorder UI needs a live stream list. |
| StreamInfo parse (short + full, incl. `<desc>` tree) | **In** | Required. |
| XPath *evaluation* | **Out** | Outlet-side only. Inlet builds query strings; never evaluates them. |
| Handshake, protocol 1.10 | **In** | The whole point. |
| Handshake, protocol 1.00 (`portable_binary_archive`) | **Out** | See §4. Refuse with a clear diagnostic. |
| Test-pattern validation | **In** | Mandatory; the outlet always sends them. |
| Formats `float32`, `double64`, `int8`, `int16`, `int32`, `int64` | **In** | Trivial once the record layout is known. |
| Format `string` | **In** | Needed for marker streams, which every experiment uses. |
| Byte-order conversion (big-endian peers) | **In** | ~10 lines; refusing it would be a latent interop bug. |
| Subnormal suppression | **In** | ~10 lines. |
| Metadata `LSL:fullinfo` | **In** | Channel labels/units live here; a recorder is useless without them. |
| Time sync: probe waves, min-RTT selection | **In** | Required for any multi-machine recording. |
| Live clock correction applied to timestamps | **Out (opt-in view only)** | See §9. |
| Live dejittering (RLS) | **Out** | See §9. |
| Reconnect / recovery by `source_id` re-resolve | **In** | Sessions run for hours; devices drop. `src/inlet_connection.cpp:149-229`. |
| Watchdog (15 s no-data → re-resolve) | **In** | ~30 lines; without it a silent stall looks like a dead stream. |
| `lsl_api.cfg` file parsing | **Defer** | Expose the same knobs as a Swift config struct; read the file later if anyone asks. |
| Outlet side (publishing) | **Out** | Explicitly out of scope. |

---

## 4. Why protocol 1.00 is out of scope

The 1.00 data path is a Boost `EOS portable_binary_archive` stream: a self-describing,
version-tagged, variable-length-integer binary serialisation with its own archive header
(`src/data_receiver.cpp:261-273`). Reimplementing it in Swift is a multi-day job with a
long correctness tail, for peers that predate 2015.

Version selection is `min(ourMax, streamInfo.version)` (`src/data_receiver.cpp:165-167`),
and `streamInfo.version` is advertised in the discovery XML — so **a Swift inlet can detect
a sub-1.10 outlet before connecting** and fail with an actionable message ("this stream is
published by liblsl < 1.10; please upgrade the source"). That is a much better outcome than
a half-correct archive decoder.

Note the outlet may *also* unilaterally downgrade to 1.00 mid-handshake if it dislikes our
declared `Value-Size` or IEEE-754 support (`src/tcp_server.cpp:641-649`). Declaring
`Has-IEEE754-Floats: 1`, `Supports-Subnormals: 1` and correct `Value-Size` avoids this; if
the outlet answers `Data-Protocol-Version: 100` anyway, abort with a distinct error.

---

## 5. Documentation gaps

Every gap below was found by reading the prose sources first and noting where they stop.
"Resolved" means the answer was extracted from `sccn/liblsl` (MIT) at the cited location.

| # | Gap | Resolution |
|---|---|---|
| 1 | Binary layout of a sample on the wire. The paper says "a losslessly delta-compressed timestamp followed by the sequence of data values". | **Resolved** — `src/sample.cpp:189-282`, `src/sample.h:19-23`. **The prose is misleading**: there is no delta compression. There is a 1-byte tag selecting "full f64 timestamp" or "deduce it". |
| 2 | Handshake header names and value encodings. Paper says only "resembles HTTP/1.1 GET". | **Resolved** — `src/data_receiver.cpp:168-259` (client), `src/tcp_server.cpp:567-717` (server). |
| 3 | Test-pattern sample values. Paper mentions "a mutually agreed-upon sequence of test-pattern data" and stops. | **Resolved** — `src/sample.cpp:356-405`; offsets `{4, 2}` at `src/tcp_server.cpp:698`; equality semantics at `src/sample.cpp:97-106`. Nothing about this exists in prose anywhere. |
| 4 | Discovery packet layout (return port, query id lines). | **Resolved** — `src/resolve_attempt_udp.cpp:53-58`, `src/udp_server.cpp:122-150`. |
| 5 | Is `query_id` semantically meaningful? | **Resolved** — no. Opaque echo token; `std::hash` is implementation-defined and never compared across hosts. `src/resolve_attempt_udp.cpp:51`, `:116`. |
| 6 | Time-sync packet wire format (the paper gives the *formulas* but not the bytes). | **Resolved** — `src/time_receiver.cpp:136`, `src/udp_server.cpp:159-161`. The leading space and missing trailing newline in the reply are only discoverable from source. |
| 7 | Clock-filter parameters. Paper says "ten times across 200 ms" and "every 5 s". | **Resolved but contradictory** — actual defaults are 8 probes × 64 ms, aggregate after 640 ms, minimum 6 replies, repeat every 2 s (`docs/info/lslapicfg.rst`; `src/time_receiver.cpp:110-129`). Treat the paper's figures as illustrative. |
| 8 | Sign convention of `time_correction()`. | **Resolved, and it is a trap** — `timeoffset_ = -best_offset` at `src/time_receiver.cpp:205`. No prose source states this. Getting it backwards produces plausible-looking but doubly-wrong alignment. |
| 9 | Deduced-timestamp rule for irregular-rate streams. | **Resolved** — `src/data_receiver.cpp:320-325`: for `srate == 0` the previous timestamp is repeated verbatim. |
| 10 | Byte-order negotiation encoding. | **Resolved** — `src/util/endian.hpp:10-17` (1234/4321, plus 0/1/2 legacy values); the `0 → native` compatibility remap at `src/data_receiver.cpp:231`. |
| 11 | Subnormal suppression semantics. | **Resolved** — `src/sample.cpp:267-280` (mask to signed zero, per format). |
| 12 | String channel length encoding. | **Resolved** — `src/sample.cpp:199-216` / `240-261`. Width byte then length, not a plain varint. |
| 13 | Multicast address sets and TTLs per scope. | **Resolved, with doc/source divergence** — `src/api_config.cpp:188-263`. `docs/info/lslapicfg.rst` documents `MachineAddresses = {FF31:…}`; the source default is `{127.0.0.1}` and IPv6 groups are *composed* per scope as `FF0x:` + `IPv6MulticastGroup`. Trust the source. |
| 14 | Are chunks a wire-level construct? | **Resolved** — no. `src/tcp_server.cpp:764-803` batches writes; `src/data_receiver.cpp:312-330` reads a flat stream. The docs' framing of chunking as a transmission feature is about throughput, not format. |
| 15 | Local clock definition. | **Resolved** — `std::chrono::steady_clock`, ns, integer-divided (`src/common.cpp:19-21`, `44-51`). |
| 16 | Recovery query construction after a stream is lost. | **Resolved** — `src/inlet_connection.cpp:154-174`. Note `nominal_srate` is deliberately *excluded* from the query because float round-tripping breaks matching. |
| 17 | Must an inlet bind within 16572–16603? | **Resolved** — no. `src/socket_utils.cpp:5-25` falls back to an OS-assigned port and the return port is carried in the query. |
| 18 | Post-processing flag definitions. | **Resolved, but not where the brief said.** The brief cites `src/common.h:77-89`; that range holds the `lost_error`/`timeout_error` classes. The flags are `lsl_processing_options_t` at `include/lsl/common.h:99-130`. |
| 19 | Apple TN3179 "Understanding local network privacy". | **Resolved** — the page is JS-rendered and could not be fetched as text; supplied separately as PDF (revision 2026-02-17) and read in full. §8 is rewritten against it. |
| 20 | Whether the local-network and multicast gates apply to BSD sockets as well as Network.framework. | **Resolved, and the answer is yes** — TN3179, *Local network operations*: "The system implements these TCP and UDP checks deep in the networking stack, and thus they apply to all networking APIs. This includes Network framework, BSD Sockets, URLSession, and any APIs implemented on top of those." Choice of socket API is therefore a pure API-fit decision, not a capability one. |
| 21 | How a program detects that local network access was denied. | **Resolved, unhappily** — TN3179, *Check for local network access*: "There's no general API that returns whether the current process has local network access (FB8711182)." The documented signals are `NWConnection` entering `.waiting` with `currentPath?.unsatisfiedReason == .localNetworkDenied`, and `kDNSServiceErr_PolicyDenied` (-65570) for Bonjour. Neither covers a raw UDP socket. See §8.2. |

Sources that were unreachable: the bioRxiv full-text HTML (`biorxiv.org/…/v1.full`) returns
HTTP 403; the same paper was read via PubMed Central (`PMC12434378`, the published
*Imaging Neuroscience* version). Apple TN3179, as above. Nothing was filled in from memory.

---

## 6. Proposed package structure

Two library targets. The split is not decorative: `LSLCore` has no I/O, so it is testable
in CI with no network, no entitlements and no peer, which is where the majority of the
correctness risk lives (record layout, test patterns, endianness, XML).

```
SwiftLSL/
├── Package.swift                    // platforms: .macOS(.v13), .iOS(.v16)
├── Sources/
│   ├── LSLCore/                     // Foundation only
│   │   ├── StreamInfo.swift         // fields + <desc> tree
│   │   ├── ChannelFormat.swift
│   │   ├── StreamInfoXML.swift      // XMLParser-based decode; no XPath
│   │   ├── Query.swift              // query-string construction
│   │   ├── SampleRecord.swift       // 1.10 encode/decode, varlen strings, endian, subnormals
│   │   ├── TestPattern.swift
│   │   ├── Handshake.swift          // header format/parse, status-line parse
│   │   └── LSLError.swift
│   └── LSL/                         // Network.framework + Darwin sockets + Dispatch
│       ├── StreamResolver.swift     // UDP discovery, waves, scopes, KnownPeers
│       ├── StreamInlet.swift        // actor: TCP data phase, pull, recovery
│       ├── TimeSynchroniser.swift   // UDP probe waves, min-RTT filter
│       ├── MetadataFetcher.swift    // LSL:fullinfo
│       ├── DatagramEndpoint.swift   // the one BSD-socket wrapper, see below
│       ├── NetworkInterfaces.swift  // getifaddrs + SIOCGIFFUNCTIONALTYPE enumeration
│       ├── LocalNetworkProbe.swift  // NWConnection-based authorisation oracle, see §8.2
│       └── Configuration.swift      // lsl_api.cfg-equivalent knobs, as a struct
└── Tests/
    ├── LSLCoreTests/                // pure Swift codec/parser units; no network
    ├── LSLPythonPeerTests/          // gated; Python pylsl outlet/inlet subprocesses
    └── LSLAppBundleSmokeTests/      // gated; local-network privacy in a real app bundle
```

### Framework choices, and one deliberate exception

- **StreamInfo parsing: `Foundation.XMLParser`.** Available on every Apple platform.
  `XMLDocument` is macOS-only and would break iOS. SAX is slightly more code but the
  document is small and the field set is fixed.
- **TCP legs (data phase, `LSL:fullinfo`): `Network.framework` `NWConnection`.** Clean fit —
  point-to-point, connection-oriented, TCP no-delay via
  `NWProtocolTCP.Options.noDelay = true`, and `receive(minimumIncompleteLength:maximumLength:)`
  maps naturally onto "read exactly N bytes".
- **UDP legs (discovery, time sync): BSD sockets via `Darwin`, wrapped in one small actor
  over `DispatchSourceRead`.** This is the deliberate exception, and the reason is
  structural rather than stylistic:
  - `NWConnectionGroup`/`NWMulticastGroup` **does not support UDP broadcast**, and
    `255.255.255.255` is in LSL's default link-scope target set.
  - Both UDP legs need one socket that *sends to many addresses* and *receives from
    arbitrary unknown sources* — discovery replies come from the outlet's ephemeral port,
    and the return port must be known before the first send. `NWConnection` is
    connection-scoped and `NWListener` does not give you the send side of the same socket.
  - The inlet never *joins* a multicast group; it only sends to group addresses and
    receives unicast replies. `NWConnectionGroup`'s entire value proposition — group
    membership management — is unused here.

  This does **not** avoid the multicast entitlement or the local-network gate — TN3179
  confirms both checks live "deep in the networking stack" and apply to BSD Sockets equally
  (gap #20). The choice is purely API fit. Keep it behind `DatagramEndpoint` so it can be
  swapped if Network.framework's multicast support grows a broadcast path.
- **Interface enumeration: `getifaddrs`, filtered by the `SIOCGIFFUNCTIONALTYPE` ioctl.**
  TN3179 is emphatic that BSD interface names are not API and must not be hard-coded. This
  feeds both the multi-interface discovery send and IPv6 scope-id recovery (§8.5).
- **Authorisation probe: a dedicated `NWConnection`.** Because a denied raw UDP socket gives
  no signal at all (gap #21), `LocalNetworkProbe` exists solely to obtain one. Two usable
  forms, in order of confidence:
  1. The data-phase TCP connection is already an `NWConnection`; read
     `currentPath?.unsatisfiedReason` when it enters `.waiting`. This path is documented and
     reliable, and the system auto-retries once the user grants access — but it only fires
     *after* discovery has already succeeded, which is too late to diagnose a failed resolve.
  2. A pre-flight UDP `NWConnection` to a local-network address. TN3179 notes that
     "connect[ing] a UDP socket to a local network address ... triggers the local network
     alert without generating any network traffic", so this both raises the prompt at a
     sensible moment and yields a state to observe. **Whether `unsatisfiedReason` is
     populated for a *UDP* `NWConnection` is not stated in TN3179** — the worked example is
     TCP. Verify before relying on it; see §12.
- **Concurrency: structured, not GCD.** `StreamInlet` is an `actor`. Sample delivery is an
  `AsyncStream<Sample>` fed by a detached reader `Task`. The one `DispatchSourceRead` inside
  `DatagramEndpoint` is bridged to an `AsyncStream<Datagram>` at that boundary and does not
  leak outwards. `Sendable` throughout; no locks in the public surface.

### Test methodology

The automated interop tests should use **Python `pylsl` peers**, not a Swift mock outlet.
This matters because the highest-risk failures are shared misunderstandings of the protocol:
if the test outlet is built from the same Swift packet encoder, handshake parser or
test-pattern generator as the inlet, the test suite can faithfully confirm the same wrong
model twice.

Recommended split:

- **Pure Swift unit tests for `LSLCore`**: header parsing, XML parsing, query escaping,
  sample-record decode, endian conversion, string length widths, deduced timestamps,
  subnormal flushing and test-pattern equality. These should use small, hand-written byte
  vectors and a few vectors captured from real peers, but they should not try to prove
  end-to-end protocol compatibility.
- **Python-driven integration tests**: `swift test` starts short-lived Python subprocesses
  that use `pylsl` to publish real outlets for every channel format, regular and irregular
  rates, marker streams, chunked pushes, stream metadata and source-id recovery cases. The
  Swift inlet then resolves, subscribes, validates the test-pattern gate implicitly, pulls
  samples and checks values/timestamps. A reverse-direction smoke test can also run a Swift
  fixture outlet only if an outlet is later added, but that is not needed for this inlet-only
  package.
- **Python inlet probes for discovery and metadata**, where useful: a tiny Python script can
  resolve the same stream and fetch its `StreamInfo`, giving a second opinion on whether the
  Swift resolver's query construction and XML interpretation agree with established `liblsl`
  behaviour.
- **Gating and dependencies**: keep these tests opt-in in normal CI, e.g.
  `LSL_RUN_PYTHON_INTEROP=1`, and skip with a clear message if `python3 -c "import pylsl"`
  fails. Do not vendor `pylsl`; install it in the CI environment or a test virtualenv. The
  Swift package should remain usable without Python.
- **Local-network privacy tests remain separate**: macOS terminal-run tests are
  automatically allowed (§8.3), so Python interop tests validate the LSL protocol but do not
  validate user-facing permission-denial behaviour. Keep the bundled app smoke test in the
  matrix for that.

Python is still backed by `liblsl`, so it is not an independent *specification*. But it is an
independent binding and implementation surface from the Swift code under test, which is the
important property for avoiding self-confirming tests.

---

## 7. Proposed public API sketch

Signatures only.

```swift
// MARK: - Core types

public enum ChannelFormat: Int32, Sendable {
    case undefined = 0, float32, double64, string, int32, int16, int8, int64
}

public struct StreamInfo: Sendable, Hashable {
    public let name: String
    public let type: String
    public let channelCount: Int
    public let nominalSampleRate: Double        // 0 == irregular
    public let channelFormat: ChannelFormat
    public let sourceID: String
    public let uid: String
    public let sessionID: String
    public let hostname: String
    public let createdAt: Double
    public let protocolVersion: Int             // 110, 100, …
    public var description: XMLElement?         // <desc>; nil until fetchMetadata()
}

public struct XMLElement: Sendable, Hashable {
    public let name: String
    public let value: String?
    public let children: [XMLElement]
    public subscript(childName: String) -> XMLElement? { get }
}

public enum SampleValues: Sendable {
    case float32([Float]), double64([Double])
    case int8([Int8]), int16([Int16]), int32([Int32]), int64([Int64])
    case string([String])
}

public struct Sample: Sendable {
    public let timestamp: Double                // raw, in the outlet's clock domain
    public let values: SampleValues
}

// MARK: - Resolution

public struct ResolveScope: Sendable {
    public static let machine: ResolveScope
    public static let link: ResolveScope
    public static let site: ResolveScope        // default
    public static func custom(addresses: [String], ttl: Int) -> ResolveScope
}

public struct ResolverConfiguration: Sendable {
    public var scope: ResolveScope
    public var sessionID: String                // "default"
    public var knownPeers: [String]
    public var multicastPort: UInt16            // 16571
    public var allowIPv4: Bool
    public var allowIPv6: Bool
    public init()
}

public struct StreamResolver: Sendable {
    public init(configuration: ResolverConfiguration = .init())

    public func resolve(
        query: String,
        minimum: Int? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> [StreamInfo]

    public func resolve(
        property: String, equals value: String,
        minimum: Int? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> [StreamInfo]

    /// Long-lived background resolver; yields the current set on every change.
    public func continuousResolve(
        query: String,
        forgetAfter: Duration = .seconds(5)
    ) -> AsyncStream<[StreamInfo]>
}

// MARK: - Inlet

public struct InletConfiguration: Sendable {
    public var maxBufferedSamples: Int
    public var maxChunkLength: Int              // 0 == outlet's choice
    public var recoverLostStream: Bool          // re-resolve by source_id
    public var watchdogThreshold: Duration      // 15 s
    public init()
}

public struct ClockOffset: Sendable {
    public let localTime: Double                // our clock at measurement
    public let remoteTime: Double
    public let correction: Double               // add to a remote timestamp -> local clock
    public let uncertainty: Double              // best round-trip time
}

public actor StreamInlet {
    public init(_ info: StreamInfo, configuration: InletConfiguration = .init()) throws

    public nonisolated var info: StreamInfo { get }

    public func open(timeout: Duration = .seconds(5)) async throws
    public func close() async

    /// Full metadata including <desc>; a separate TCP round trip.
    public func fetchMetadata(timeout: Duration = .seconds(5)) async throws -> StreamInfo

    public func pullSample(timeout: Duration = .seconds(1)) async throws -> Sample?
    public func pullChunk(maxSamples: Int, timeout: Duration = .seconds(1)) async throws -> [Sample]

    /// Continuous delivery. Terminates when the stream is irrecoverably lost.
    public nonisolated var samples: AsyncThrowingStream<Sample, Error> { get }

    /// Latest offset; awaits the first measurement if none has completed.
    public func clockOffset(timeout: Duration = .seconds(5)) async throws -> ClockOffset

    /// Every measurement, for recording alongside the samples. See §9.
    public nonisolated var clockOffsets: AsyncStream<ClockOffset> { get }

    /// True once since the last call if the offset series was discontinuous
    /// (stream recovery). Recorders must segment on this.
    public func consumeOffsetResetFlag() -> Bool
}

// MARK: - Local network access

/// Best-effort local-network authorisation state. There is no system API for this
/// (TN3179, FB8711182); this is inferred from NWConnection, and `.unknown` is a
/// legitimate and common answer.
public enum LocalNetworkAccess: Sendable {
    case allowed
    case denied
    case unknown
}

public enum LocalNetwork {
    /// Performs a probe that both raises the system prompt (if undetermined) and
    /// attempts to infer the current state. Call before the first resolve so the
    /// user sees the alert in context.
    public static func probe(timeout: Duration = .seconds(2)) async -> LocalNetworkAccess
}

// A resolve that yields nothing is ambiguous; the error type must distinguish.
extension LSLError {
    /// No outlets replied, and the probe reports access is denied.
    case localNetworkDenied
    /// No outlets replied, and access could not be determined.
    case noStreamsFound(accessState: LocalNetworkAccess)
}

// MARK: - Free functions

/// Monotonic local clock, seconds, matching liblsl's time base.
public func lslClock() -> Double
```

Deliberately **absent**: any `postProcessing` options mask. See §8 — the corrected view is a
consumer-side computation, not an inlet setting.

---

## 8. Apple-platform constraints

These do not exist on the desktop/embedded reference targets and are the largest
non-protocol risk in the project. This section is written against
**TN3179, revision 2026-02-17**, read in full.

Platform support for local network privacy (TN3179, *Overview*): iOS 14, iPadOS 14,
**macOS 15**, visionOS 1. tvOS and watchOS: not supported — no prompt, no restriction.

### 8.1 Multicast entitlement — iOS only

> "The multicast entitlement isn't required on macOS." — TN3179, *Essentials*

This is a material correction to the initial read of this project's risk. **macOS is not
gated by the entitlement at all**, only by the local network prompt (§8.2). Development,
CI and any Mac-based recorder are unblocked from day one.

On iOS, `com.apple.developer.networking.multicast` is a restricted entitlement requested
individually at `developer.apple.com/contact/request/networking-multicast`. TN3179's
*Multicast operations* table is precise about what it gates:

| Operation | Entitlement required (iOS) |
|---|---|
| Sending a UDP unicast | no |
| Sending a UDP multicast | **yes** |
| Sending a UDP broadcast | **yes** |
| Receiving an incoming UDP unicast | no |
| Receiving an incoming UDP multicast | yes |
| Receiving an incoming UDP broadcast | yes |

Map that onto the inlet's actual behaviour (§2.1): the inlet **sends** to multicast and
broadcast addresses, and **receives unicast replies**. It never joins a group and never
receives multicast. So the entitlement is needed for the send side only — and:

- **The `KnownPeers` unicast path requires no entitlement at all.** Unicast send and unicast
  receive are both "no". A `KnownPeers`-configured iOS recorder needs only the local network
  prompt. This is a complete, fully-supported discovery mode, not a degraded one, and it
  settles the argument for putting `KnownPeers` in v1 (§3).
- Request the entitlement at project start anyway; approval latency is outside your control.
  But it is now a *feature-completeness* schedule item on one platform, not a project-wide
  blocker.
- **The iOS Simulator "doesn't support local network privacy"** (TN3179, *iOS
  considerations*) — it silently permits everything. Testing on the simulator proves nothing
  about either the prompt or the entitlement. Test on real hardware.
- **App Clips cannot perform local network operations** at all.

### 8.2 Local network privacy

TN3179's *Local network operations* table, restricted to operations this package performs:

| Operation | Local network access required |
|---|---|
| Making an outgoing TCP connection (data phase, `LSL:fullinfo`) | **yes** |
| Sending a UDP unicast (`KnownPeers` query, time-sync probe) | **yes** |
| Sending a UDP multicast / broadcast (discovery) | **yes** |
| Connecting a UDP socket | **yes** |
| Receiving an incoming UDP unicast (discovery replies, time-sync replies) | no |

Note also that "all multicast addresses (`224.0.0.0/4`, `ff00::/8`) and the IPv4 broadcast
address (`255.255.255.255`) are local network addresses" by definition — every LSL discovery
target qualifies, regardless of routing.

- **`NSLocalNetworkUsageDescription` is required** in the app's Info.plist (and in the *app's*,
  not an extension's, if extensions are involved). Write a purpose string naming what is
  discovered and why.
- **`NSBonjourServices` is not applicable** — confirmed. TN3179 scopes it to registering,
  browsing and resolving Bonjour services. LSL is raw UDP to a fixed port; there is no
  service type to declare. The brief's expectation of a Bonjour declaration requirement does
  not hold.
- **The checks are enforced below the API layer**: "deep in the networking stack, and thus
  they apply to all networking APIs. This includes Network framework, BSD Sockets,
  URLSession". The BSD-socket choice in §6 buys nothing here and costs nothing.
- **Detection is the real problem** (gap #21). There is no API for it. TN3179's only
  documented signals are `NWConnection` `.waiting` with
  `currentPath?.unsatisfiedReason == .localNetworkDenied`, and `kDNSServiceErr_PolicyDenied`
  for Bonjour. On a raw UDP socket a denial is silent. Hence `LocalNetworkProbe` (§6) and the
  `noStreamsFound(accessState:)` error shape (§7): an empty resolve must never be reported as
  a bare empty list.
- **Prompt while in the foreground.** TN3179, *iOS considerations*: a background app
  performing a local network operation while the privilege is undetermined has the operation
  **denied with no alert shown, and the decision is not recorded**. A recorder that starts a
  resolve from a background task on first launch simply fails, invisibly. Probe in the
  foreground during onboarding.
- **VPN and cellular interfaces are not local networks** ("Such interfaces include Wi-Fi and
  Ethernet, but not cellular (WWAN) or VPN"). Traffic over a lab VPN is therefore outside
  local network privacy entirely — but such interfaces are also not broadcast-capable, so
  multicast discovery will not traverse them. `KnownPeers` is the answer for VPN-connected
  peers, as it is for `liblsl` itself.
- **`.local` hostnames in `KnownPeers` require local network access to resolve.** If a site
  configures peers as `rig-2.local`, DNS resolution itself is gated.

### 8.3 macOS-specific behaviour

Several items here materially affect the *test methodology*, and one is an outright trap.

- **Command-line tools are automatically allowed.** macOS grants local network access to any
  `launchd` daemon, any program running as root, and "command-line tools run from Terminal or
  over SSH, including any child processes they spawn". **`swift test` from a terminal
  therefore has unconditional access** — CI and integration tests are unblocked, but they
  prove nothing about how the same code behaves inside an app bundle. Keep at least one
  bundled smoke test in the matrix.
- The daemon exemption **does not extend to `launchd` agents**. An agent needs
  `AssociatedBundleIdentifiers` in its plist so macOS can attribute the access.
- **There is no way to reset the privilege on macOS** (FB14944392). Re-testing the
  undetermined state requires a VM snapshot or a fresh user account (state is per-user).
  Budget for this in the test plan; it is not a five-minute loop.
- **Short-lived processes may never show the alert** (FB16131937): "macOS fails to display the
  local network alert when a process with a very short lifespan performs a local network
  operation… update your code to not exit immediately after a local network operation fails."
  This is a direct design constraint on the resolver: **it must not fail fast**. A resolve
  that gives up and tears down on first failure can prevent the prompt from ever appearing,
  producing a permanently unusable app. Keep the resolver alive across the wave schedule.
- **Sign with an Apple-issued identity.** Local network privacy tracks program identity by
  code signature; ad-hoc signing ("Sign to Run Locally") makes it behave erratically. The
  main executable also needs a unique build UUID (TN3178).
- **Site-wide escape hatch, worth telling users about.** macOS 15.5+ supports
  `AllowedEthernetLocalNetworkAddresses` and `AllowedWiFiLocalNetworkAddresses` in the
  `com.apple.network.local-network` defaults domain — arrays of CIDR strings whose addresses
  are treated as non-local, bypassing the privilege for every program. Requires `sudo` and a
  restart. TN3179 calls this out as "particularly useful for site administrators, including
  developers who managed continuous integration (CI) systems", which describes a research lab
  exactly. Document it as a deployment option.

### 8.4 macOS App Sandbox

`com.apple.security.network.client` (outbound TCP/UDP) and
`com.apple.security.network.server` (bind and receive) are both required — the latter
because the discovery socket binds a port and receives unsolicited datagrams.

`liblsl` itself ships an `lsl.entitlements` with these two plus
`com.apple.security.network.multicast`. That third key is **not a documented Apple
entitlement** as far as this review could establish, and TN3179 confirms no multicast
entitlement of any kind is required on macOS — so it is doing nothing. Do not copy it; an
unrecognised entitlement key can fail code signing.

### 8.5 IPv6 link-local scope IDs

Real: `liblsl` explicitly handles the case where an outlet advertises a link-local
`v6address`, by re-resolving it through a name resolver to recover the scope
(`src/inlet_connection.cpp:100-113`, comment: "This more complicated procedure is required
when the address is an ipv6 link-local address").

On Apple platforms `NWEndpoint.Host.ipv6(_:)` carries an optional `interface`, which is where
the scope lives, and every interface has a link-local address. When connecting to a
link-local `fe80::…` from a discovery reply, the interface must be recovered from the
`NWPath` of the socket the reply arrived on and attached to the endpoint — an address string
alone is not routable. This is straightforward but easy to omit, and it fails only on
multi-homed machines, which is exactly where it will be found late.

Sending IPv6 multicast has the mirror problem: the outbound interface must be specified per
group (`liblsl` sets it per interface at `src/resolve_attempt_udp.cpp:169-170`). TN3179's
own sample code for triggering the privacy alert enumerates link-local IPv6 addresses via
`getifaddrs` filtered on `IFF_BROADCAST`, which is the same enumeration the multi-interface
discovery send needs — build it once (`NetworkInterfaces.swift`, §6).

### 8.6 Background execution

Not a permission but a real constraint: on iOS, a suspended app stops reading its TCP
socket, the outlet's send buffer fills, and the connection is dropped. A recorder on iOS
needs an appropriate background mode or an explicit "recording stops when backgrounded"
contract. Out of scope for the package; must be stated in its documentation. Compounding
this, an undetermined privilege plus a background local network operation yields a silent
denial that is not even recorded (§8.2) — so the first resolve must happen in the
foreground.

---

## 9. Time-synchronisation strategy

**Recommendation: record raw. Store per-sample timestamps exactly as received, plus a
separate per-stream time series of clock-offset measurements, and defer alignment to a later
pass. Expose live correction only as an opt-in derived view, never as the recorded value.**

Reasoning:

1. **This is what the reference recorder does, and for good reasons.** The paper describes
   LabRecorder as storing all "timing-related ground truth 'as it happened'", with the
   linear regression and jitter removal performed by `load_xdf` at import time.
2. **Live correction is a zero-order hold, and it is lossy.** `proc_clocksync` adds the most
   recent offset, refreshed at most every 50 samples and twice per second
   (`src/time_postprocessor.cpp:17-18`, `59-82`). Each refresh introduces a step
   discontinuity in the recorded timestamps. Offline you can fit a line — or a robust
   spline — through the whole offset series in both directions, which strictly dominates.
   And the step is unrecoverable: once baked into the file, you cannot subtract it back out
   without the offset series, which you would then have had to record anyway.
3. **Live dejittering is worse.** The RLS smoother (`src/time_postprocessor.cpp:104-131`)
   needs 30–120 s to converge (`include/lsl/common.h:114-118`), so the start of every
   recording is systematically distorted. The paper also documents a catastrophic failure
   mode: a source whose true rate changes (their example: a webcam alternating 30/60 fps)
   is "significantly (even catastrophically) distort[ed]" by uniform-rate smoothing. A
   recorder cannot know in advance whether its sources behave.
4. **The cost of recording raw is negligible.** An offset series at 0.5 Hz is 4 doubles ×
   2 samples/s per stream. Against a 24-channel 512 Hz float32 stream that is under 0.03%
   overhead. In an SWMR HDF5 file it is one extra small dataset per stream.
5. **Record `uncertainty` too.** The best-RTT figure is the only per-measurement quality
   signal available, and offline fitting wants it as a weight. `liblsl` exposes it via
   `time_correction_ex`; do not discard it.

Concretely, per stream, write:

- `timestamps` — raw `f64`, exactly as decoded (with deduced timestamps materialised, since
  deduction is unambiguous and stateless once `srate` is known).
- `clock_offsets` — `(localTime, remoteTime, correction, uncertainty)` per measurement.
- A **segment marker** whenever `consumeOffsetResetFlag()` returns true. On stream recovery
  `liblsl` resets the offset to unassigned (`src/time_receiver.cpp:212-219`) because the
  peer may be a different process with a different clock epoch. Fitting a single line across
  a reset is silently wrong. This is the one piece of the mechanism a recorder *must* handle
  live, because the information is not recoverable afterwards.

The one case for live correction is a real-time display alongside the recording. Serve that
from a derived view over the same data; it does not justify changing what is written to disk.

---

## 10. Licensing

`liblsl` is MIT, © 2012 Christian A. Kothe. The obligation is narrow: the copyright and
permission notice must accompany "all copies or substantial portions of the Software".

What was actually taken here is **protocol facts** — field names, byte layouts, magic
constants, formulas. Facts are not copyrightable, and a clean-room-style reimplementation
from them carries no MIT obligation. Two items sit closer to expression and warrant care:

- **The test-pattern generator** (`src/sample.cpp:356-405`). The *values* are protocol
  constants and must match exactly, but write the generator yourself rather than
  transliterating the C++.
- **The RLS dejitterer** (`src/time_postprocessor.cpp:104-131`). Out of scope for v1 anyway
  (§9). If ported later, port it as expression and ship liblsl's MIT notice.

Recommended regardless: a `NOTICE`/`ACKNOWLEDGEMENTS` file stating that the wire protocol was
implemented with reference to `sccn/liblsl` (MIT, © 2012 Christian A. Kothe), with the commit
hash. This costs nothing, is honest about provenance, and forecloses the argument entirely.
Cite the Kothe et al. paper as the protocol's academic reference.

**MIT vs Unlicense — your call.** One line of view: MIT is the safer default. It is equally
permissive in practice, is universally accepted by corporate and institutional legal review,
and — relevantly for a Finnish author — does not rely on a public-domain dedication whose
enforceability is doubtful in civil-law jurisdictions that do not permit waiver of moral
rights. The Unlicense's only real advantage is removing the attribution requirement, which
is not a burden anyone has complained about. If the goal is maximum downstream adoption, MIT
gets you there with less friction.

---

## 11. Effort estimate

Scale as used in the prior assessment: *weekend* / *one–two weeks* / *longer*.

| Area | Estimate | Notes |
|---|---|---|
| StreamInfo XML + query construction | **weekend** | `XMLParser` SAX + `<desc>` tree. No XPath needed. |
| Discovery (query/response, link+site scopes, KnownPeers, wave scheduling) | **weekend** | |
| Multi-interface send + `getifaddrs`/`SIOCGIFFUNCTIONALTYPE` enumeration | **2–3 days** | Promoted into v1 on TN3179's explicit guidance (§3). Shared with IPv6 scope recovery. |
| TCP data phase (handshake, 1.10 record codec, test patterns, endianness, subnormals) | **weekend** | The codec itself is a few hours; the test-pattern gate and header quirks are the rest. |
| Metadata (`LSL:fullinfo`) | **half a day** | Reuses the TCP and XML layers entirely. |
| Time synchronisation (probe waves, min-RTT filter, offset stream) | **half a day to a day** | Genuinely small. The only trap is the sign. |
| Reconnection, recovery, watchdog | **2–3 days** | Underestimated at first glance; it is state machine work and hard to test. |
| Apple platform plumbing (Info.plist, sandbox entitlements, `LocalNetworkProbe`, error shaping) | **2–3 days** | Up from 1–2: the authorisation oracle is real work, not a plist entry. **No entitlement dependency on macOS at all.** iOS multicast approval is unbounded wall-clock, but only for the multicast discovery mode — `KnownPeers` ships without it. |
| Packaging, public API polish, DocC | **2–3 days** | |
| Automated interoperability testing with Python `pylsl` peers, plus selected live-device checks | **one–two weeks** | The dominant cost. Use Python subprocesses as the primary automated oracle so the Swift inlet is tested against an established binding rather than a same-codebase mock. Cover multiple `liblsl` versions, all seven channel formats, irregular-rate streams, marker streams, multi-homed hosts, mid-session disconnects, IPv4/IPv6 mixes. |
| Local network privacy test matrix | **2–3 days** | Separate from protocol interop and easy to underestimate: the macOS privilege cannot be reset (needs VM snapshots or throwaway user accounts), the simulator doesn't implement privacy at all, and terminal-run tests are auto-allowed so they don't exercise the denial path. |

**Rolled up:**

- Prototype (resolve one stream, pull `float32` samples from a live `liblsl` outlet on a
  quiet LAN): **one weekend.**
- Feature-complete against the v1 table in §3, lightly tested: **one–two weeks** on top.
- Trustworthy in a real multi-hour, multi-device recording session: **three to five weeks
  total** of focused work.

The estimate assumes macOS-first development with a `liblsl` outlet running locally. Since
macOS requires no multicast entitlement, **nothing on the macOS path waits on Apple**. iOS
validation splits: the `KnownPeers` mode can be validated immediately, multicast discovery
only once the entitlement lands.

---

## 12. Uncertainties

1. **Does a *UDP* `NWConnection` populate `unsatisfiedReason == .localNetworkDenied`?**
   TN3179's worked example is TCP. The pre-flight authorisation probe (§6, §8.2) depends on
   this; if UDP does not surface the reason, the probe degrades to "raises the prompt but
   cannot read the answer", and denial detection falls back to the data-phase TCP connection
   — which only helps *after* a successful resolve. Test this first; it is an afternoon's
   work and it determines the diagnostics story.
2. **iOS multicast entitlement approval outcome and latency.** Unknown. LSL is a legitimate
   research protocol with a decade of published use, which should help, but no timeline can
   be promised. Scope-limited now that macOS is unaffected and iOS `KnownPeers` works
   without it.
3. **Swift's monotonic clock versus `std::chrono::steady_clock`.** Darwin's `steady_clock`
   does not advance across system sleep; Swift's `ContinuousClock` and `SuspendingClock`
   differ on precisely this point, and which maps to `steady_clock` was not verified. Low
   risk — the NTP exchange measures the offset between whatever clocks the two peers use, so
   consistency matters more than identity — but it affects timestamp interpretation across a
   sleep/wake cycle and should be checked before a long unattended recording.
4. **Real-world protocol version distribution.** The decision to drop protocol 1.00 (§4)
   assumes sub-1.10 outlets are effectively extinct in the field. This was not measured. If
   a target device ships an ancient embedded `liblsl`, the estimate grows by several days.
5. **Interaction between multi-interface sending and the privacy prompt.** Sending discovery
   queries from every broadcast-capable interface is now in v1, but whether the local network
   privilege is evaluated per-interface or per-process is not stated in TN3179. If
   per-interface, a partially-granted state may be possible and would need handling.
6. **`liblsl` master is ahead of any release.** The clone (`e651023`) contains a synchronous
   zero-copy send mode not present in shipped versions. Nothing in the *inlet-side* wire
   protocol appeared to differ, but the byte layouts here were verified against master, not
   against a tagged release. Cross-check against the version actually deployed on the
   devices you intend to record from.
7. **The `<desc>` schema is a convention, not a specification.** The paper points to the XDF
   GitHub wiki for content-type nomenclature. The package should parse `<desc>` as a generic
   tree and let the consumer interpret it; imposing a schema would be premature.

---

## Sources

Prose:
- [LSL introduction](https://labstreaminglayer.readthedocs.io/info/intro.html)
- [LSL user guide](https://labstreaminglayer.readthedocs.io/info/user_guide.html)
- [network-connectivity.rst](https://github.com/sccn/labstreaminglayer/blob/master/docs/info/network-connectivity.rst)
- [lslapicfg.rst](https://github.com/sccn/labstreaminglayer/blob/master/docs/info/lslapicfg.rst)
- Kothe et al., "The lab streaming layer for synchronized multimodal recording", *Imaging
  Neuroscience* — read via [PMC12434378](https://pmc.ncbi.nlm.nih.gov/articles/PMC12434378/)
  (the bioRxiv full-text HTML returns 403)

Reference implementation ([sccn/liblsl](https://github.com/sccn/liblsl), MIT, @ `e651023`):
`src/sample.cpp`, `src/sample.h`, `src/data_receiver.cpp`, `src/tcp_server.cpp`,
`src/udp_server.cpp`, `src/resolve_attempt_udp.cpp`, `src/resolver_impl.cpp`,
`src/stream_info_impl.cpp`, `src/info_receiver.cpp`, `src/time_receiver.cpp`,
`src/time_postprocessor.cpp`, `src/inlet_connection.cpp`, `src/api_config.cpp`,
`src/common.cpp`, `src/common.h`, `src/socket_utils.cpp`, `src/util/endian.hpp`,
`include/lsl/common.h`, `lsl.entitlements`, `LICENSE`.

Apple:
- [com.apple.developer.networking.multicast](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)
- [How to use multicast networking in your app](https://developer.apple.com/news/?id=0oi77447)
- [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — revision 2026-02-17, read in full from a
  PDF supplied by the user; the live page is JS-rendered and not machine-readable. §8 is
  written against it.
- [NWEndpoint.Host.interface](https://developer.apple.com/documentation/network/nwendpoint/host/interface)

`sccn/secureLSL` and `eeglab.org/secureLSL` were not consulted.
