/// Continuations parked on an actor's state, resumable en masse and cancellation-aware.
///
/// A `CheckedContinuation` is not resumed by task cancellation. Anything that parks on one
/// inside a task group therefore holds the whole group open forever once the group is
/// cancelled, which is a hang, not a leak. Every wait in this package goes through here.
struct WaiterSet {
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var cancelledBeforeParking: Set<Int> = []
    private var counter = 0

    mutating func allocate() -> Int {
        counter += 1
        return counter
    }

    /// Parks `continuation` under `id` — unless the wait is already satisfied, or was
    /// cancelled in the window between allocating the id and installing the continuation.
    mutating func park(
        _ id: Int, _ continuation: CheckedContinuation<Void, Never>, satisfied: Bool = false
    ) {
        if satisfied || cancelledBeforeParking.remove(id) != nil {
            continuation.resume()
        } else {
            pending[id] = continuation
        }
    }

    mutating func cancel(_ id: Int) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledBeforeParking.insert(id)
        }
    }

    mutating func resumeAll() {
        let waiting = Array(pending.values)
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
