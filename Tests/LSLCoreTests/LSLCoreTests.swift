import Testing

@testable import LSLCore

@Test func maximumProtocolVersionIs110() {
    #expect(LSLCore.maximumProtocolVersion == 110)
}
