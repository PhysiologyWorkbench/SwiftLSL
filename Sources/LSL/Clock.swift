import Darwin

/// The protocol clock: monotonic seconds, matching `liblsl`'s time base.
///
/// `liblsl` reads `std::chrono::steady_clock` in nanoseconds and divides down with
/// integer arithmetic, because a `double` cannot hold a large nanosecond count without
/// losing precision (`src/common.cpp:19-21`, `44-51`). On Darwin that clock is
/// `CLOCK_MONOTONIC_RAW` — verified by comparing `lsl_local_clock()` against each
/// candidate on macOS 26; plain `CLOCK_MONOTONIC` is adjusted and drifts seconds away
/// (SCOPE.md §12 item 3). `CLOCK_MONOTONIC_RAW` keeps running across system sleep, which
/// is what makes timestamps meaningful either side of a sleep/wake cycle.
public func lslClock() -> Double {
    let nanoseconds = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    let nanosecondsPerSecond: UInt64 = 1_000_000_000
    return Double(nanoseconds / nanosecondsPerSecond)
        + Double(nanoseconds % nanosecondsPerSecond) / Double(nanosecondsPerSecond)
}
