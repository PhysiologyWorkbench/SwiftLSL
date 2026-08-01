import Foundation

/// Golden byte traces captured from a live `liblsl` outlet, replayed through the decoders
/// on every `swift test` run so reference bytes are exercised without Python or a network
/// (TESTING.md, *Golden traces*).
struct TestPatternFixtures: Decodable {
    let libraryVersion: String
    let channelCount: Int
    let responseHeader: String
    let testPatterns: [String: String]

    static let shared: TestPatternFixtures = {
        let url = Bundle.module.url(
            forResource: "test-patterns-liblsl-1.17.7", withExtension: "json",
            subdirectory: "Fixtures"
        )!
        return try! JSONDecoder().decode(
            TestPatternFixtures.self, from: Data(contentsOf: url)
        )
    }()

    func bytes(_ format: String) -> Data {
        Data(hex: testPatterns[format]!)
    }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
