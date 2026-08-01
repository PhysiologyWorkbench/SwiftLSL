import Testing

@testable import LSL

@Test func lslReexportsLSLCore() {
    #expect(LSLCore.maximumProtocolVersion == 110)
}
