# Apple platform checklist

Everything about local network privacy that cannot be tested automatically, plus the
Info.plist and entitlement templates a consumer needs. Authority: SCOPE.md §8, written
against TN3179 (revision 2026-02-17).

Why manual: a command-line tool run from Terminal is granted local network access
unconditionally, including every process it spawns (SCOPE.md §8.3), so `swift test` and
`pytest` prove nothing about the prompt. macOS also has no way to reset the privilege
(FB14944392) — re-testing the undetermined state needs a fresh user account or a VM
snapshot. Neither constraint has a workaround; the checklist is the test artefact.

## Consumer templates

### Info.plist — required on iOS 14+, macOS 15+, visionOS 1+

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Finds Lab Streaming Layer devices on your local network so their data can be
recorded.</string>
```

The string must be in the **app's** Info.plist, not an extension's. `NSBonjourServices`
is **not** applicable: it scopes to registering, browsing and resolving Bonjour services,
and LSL is raw UDP to a fixed port with no service type to declare (SCOPE.md §8.2).

### macOS App Sandbox entitlements

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

`network.server` is needed because the inlet binds a UDP socket to receive discovery and
time-sync replies. Do **not** copy `com.apple.security.network.multicast` from
`liblsl`'s `lsl.entitlements`: it is undocumented, and TN3179 is explicit that the
multicast entitlement is not required on macOS (SCOPE.md §8.1).

### iOS multicast entitlement

```xml
<key>com.apple.developer.networking.multicast</key>
<true/>
```

Restricted; requested per team at
<https://developer.apple.com/contact/request/networking-multicast>. It gates **sending**
UDP multicast and broadcast, which is the default discovery mode. It is **not** needed
for the `KnownPeers` unicast path — configure `ResolverConfiguration.knownPeers` and set
`useMulticast = false` and an unentitled iOS app is fully functional (SCOPE.md §8.1).

Status: **requested / not yet requested** — record the date and outcome here.

## Manual test script

Run on real hardware. The iOS Simulator "doesn't support local network privacy" and
silently permits everything, so it proves nothing (SCOPE.md §8.1).

Prepare a bundled macOS app that links `LSL`, signed with an Apple-issued identity — not
"Sign to Run Locally"; ad-hoc signing makes the privilege behave erratically (SCOPE.md
§8.3). It should call `LocalNetwork.probe()` on a button, then `StreamResolver.resolve`,
and display both results.

| # | Case | Steps | Expected | Result |
|---|---|---|---|---|
| 1 | Prompt appears | Fresh user account; launch the app in the foreground; tap Probe | System alert quoting `NSLocalNetworkUsageDescription`; `probe()` does not return before the user answers | |
| 2 | Granted | Allow at the prompt; resolve with an outlet running | `probe() == .allowed`; the outlet is found | |
| 3 | Denied | Deny at the prompt; resolve | `probe() == .denied`; `resolveFirst` throws `noStreamsFound(accessState: .denied)` — **this is the SCOPE §12 item 1 verification, see below** | |
| 4 | Re-grant | System Settings ▸ Privacy & Security ▸ Local Network ▸ enable the app; resolve again without relaunching | The outlet is found; no relaunch needed (the system retries a waiting connection itself) | |
| 5 | No fail-fast | Deny, then resolve for the full timeout | The process stays alive across the wave schedule; the alert is not suppressed by an early exit (FB16131937, SCOPE.md §8.3) | |
| 6 | Background start | iOS: start a resolve from a background task with the privilege undetermined | Operation denied, **no alert**, decision not recorded — the reason onboarding must probe in the foreground (SCOPE.md §8.2) | |
| 7 | iOS `KnownPeers`, no entitlement | Unentitled iOS build, `knownPeers = ["<outlet host>"]`, `useMulticast = false` | The outlet is found; only the local network prompt is involved | |
| 8 | iOS multicast, no entitlement | Same build, default multicast discovery | Nothing is found; the failure carries an access state rather than an empty list | |
| 9 | Multi-homed reachability | Mac with Wi-Fi *and* Ethernet on **different subnets**, one outlet on each; resolve at `link` scope | Both outlets are found. Automated coverage stops at "discovery still works when several interfaces are pinned" (`test_multi_homed_discovery_still_resolves`) because one host cannot place outlets on two networks | |
| 10 | AWDL is not used | `lsltool netinfo` while AirDrop is open | `awdl0` is listed with `functional_type: wifiAWDL` and `discovery: false` | |

### SCOPE §12 item 1 — does a UDP `NWConnection` surface `.localNetworkDenied`?

**Partly answered; the denial branch is case 3 above and remains open.**

Measured on macOS 26, terminal process, access granted: a UDP `NWConnection` to
`224.0.0.1:16571` reaches `.ready`, so `LocalNetwork.probe()` returns `.allowed` and the
oracle exists in the allowed direction. Whether the same connection enters `.waiting`
with `currentPath?.unsatisfiedReason == .localNetworkDenied` when the privilege is denied
could not be established from a terminal, for the two reasons at the top of this file.

Consequence for the diagnostics story, and it is deliberate: `.allowed` from the probe
means "not observed to be denied", and the authoritative denial signal remains the
data-phase TCP connection, where TN3179's worked example applies directly and which
`TCPConnection` already reads. If case 3 shows UDP never reports the reason, nothing in
the package changes shape — `probe()` returns `.unknown` instead of `.denied`, which the
`noStreamsFound(accessState:)` error already models.

## Notes for consumers

- **Background execution.** A suspended iOS app stops reading its TCP socket, the
  outlet's send buffer fills, and the outlet drops the connection. A recorder needs an
  appropriate background mode or an explicit "recording stops when backgrounded"
  contract (SCOPE.md §8.6).
- **App Clips cannot perform local network operations at all** (SCOPE.md §8.1).
- **Site-wide escape hatch.** macOS 15.5+ honours `AllowedEthernetLocalNetworkAddresses`
  and `AllowedWiFiLocalNetworkAddresses` in the `com.apple.network.local-network`
  defaults domain: arrays of CIDR strings treated as non-local, bypassing the privilege
  for every program. Needs `sudo` and a restart; useful for a lab subnet (SCOPE.md §8.3).
- **VPN interfaces are not local networks** and are not broadcast-capable, so multicast
  discovery does not traverse them. `KnownPeers` is the answer for VPN-connected peers.
