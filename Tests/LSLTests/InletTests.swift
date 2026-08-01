import Foundation
import Testing

@testable import LSL

@Suite("Inlet construction and endpoints")
struct InletTests {
    static func info(
        v4: String = "192.0.2.10", v4Data: UInt16 = 16574, v4Service: UInt16 = 16572,
        v6: String = "", v6Data: UInt16 = 0, v6Service: UInt16 = 0,
        version: Int = 110
    ) -> StreamInfo {
        StreamInfo(
            name: "S", type: "T", channelCount: 1, nominalSampleRate: 0,
            channelFormat: .float32, sourceID: "src", uid: "u", protocolVersion: version,
            v4Address: v4, v4DataPort: v4Data, v4ServicePort: v4Service,
            v6Address: v6, v6DataPort: v6Data, v6ServicePort: v6Service)
    }

    @Test("A sub-1.10 stream is refused at construction")
    func refusesOldProtocol() {
        #expect(throws: LSLError.unsupportedProtocolVersion(100)) {
            _ = try StreamInlet(Self.info(version: 100))
        }
    }

    @Test("A stream with no address is refused at construction")
    func refusesAddresslessStream() {
        #expect(throws: (any Error).self) {
            _ = try StreamInlet(Self.info(v4: ""))
        }
    }

    @Test("IPv4 is preferred when both are advertised")
    func prefersIPv4() throws {
        let both = Self.info(v6: "2001:db8::1", v6Data: 16584, v6Service: 16582)
        let data = try StreamInlet.dataEndpoint(for: both)
        #expect(data.host == "192.0.2.10")
        #expect(data.port == 16574)
        let service = try StreamInlet.serviceEndpoint(for: both)
        #expect(service.port == 16572)
    }

    @Test("IPv6 is used when there is no IPv4 address")
    func fallsBackToIPv6() throws {
        let only6 = Self.info(v4: "", v4Data: 0, v4Service: 0, v6: "2001:db8::1",
            v6Data: 16584, v6Service: 16582)
        #expect(try StreamInlet.dataEndpoint(for: only6).host == "2001:db8::1")
        #expect(try StreamInlet.serviceEndpoint(for: only6).port == 16582)
    }

    @Test("An address without a port is not a usable endpoint")
    func rejectsPortlessAddress() {
        let noPort = Self.info(v4Data: 0, v4Service: 0)
        #expect(throws: (any Error).self) { _ = try StreamInlet.dataEndpoint(for: noPort) }
        #expect(throws: (any Error).self) { _ = try StreamInlet.serviceEndpoint(for: noPort) }
    }

    @Test("The buffer request follows liblsl's seconds-to-samples conversion")
    func bufferLength() {
        var settings = InletConfiguration()
        settings.maxBuffered = .seconds(360)
        // 512 Hz x 360 s, and 100 samples/s x 360 s for an irregular stream.
        let regular = StreamInfo(
            name: "S", channelCount: 1, nominalSampleRate: 512, channelFormat: .float32,
            uid: "u")
        #expect(settings.maxBufferLength(for: regular) == 184_320)
        #expect(settings.maxBufferLength(for: Self.info()) == 36_000)

        settings.maxBuffered = .zero
        #expect(settings.maxBufferLength(for: regular) == 1, "never request a zero buffer")
    }
}

@Suite("Waiter set")
struct WaiterSetTests {
    @Test("A parked waiter is resumed en masse")
    func resumeAll() async {
        let box = WaiterBox()
        async let first: Void = box.wait()
        async let second: Void = box.wait()
        await box.releaseWhenReady(count: 2)
        _ = await (first, second)
        #expect(await box.released)
    }

    @Test("A cancelled wait is resumed rather than left parked")
    func cancellationResumes() async {
        // The whole point: a CheckedContinuation is not resumed by cancellation, so a
        // parked waiter inside a cancelled task group would hang it forever.
        let box = WaiterBox()
        let task = Task { await box.wait() }
        await box.waitUntilParked()
        task.cancel()
        await task.value
    }

    @Test("Cancellation arriving before parking is not lost")
    func cancellationBeforeParking() async {
        var waiters = WaiterSet()
        let id = waiters.allocate()
        waiters.cancel(id)
        await withCheckedContinuation { continuation in
            waiters.park(id, continuation)
        }
    }
}

/// A minimal actor exercising `WaiterSet` the way the resolver and the inlet do.
private actor WaiterBox {
    private var waiters = WaiterSet()
    private var parked = 0
    private(set) var released = false

    func wait() async {
        let id = waiters.allocate()
        parked += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.park(id, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitUntilParked() async {
        while parked == 0 {
            await Task.yield()
        }
    }

    func releaseWhenReady(count: Int) async {
        while parked < count {
            await Task.yield()
        }
        released = true
        waiters.resumeAll()
    }

    private func cancel(_ id: Int) {
        waiters.cancel(id)
    }
}
