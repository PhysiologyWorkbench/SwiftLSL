import Foundation
import Testing

/// Golden byte traces captured from a live `liblsl` outlet, replayed through the decoders
/// on every `swift test` run so reference bytes are exercised without Python or a network
/// (TESTING.md, *Golden traces*).
///
/// One fixture per liblsl release, captured by `Tests/python/capture_fixture.py`. Tests
/// run against every one of them, which is what makes the release interop matrix
/// (ROADMAP step 9) permanent rather than a run that happened once.
struct TestPatternFixtures: Decodable, Sendable, CustomTestStringConvertible {
    let libraryVersion: String
    let channelCount: Int
    let responseHeader: String
    let testPatterns: [String: String]

    var testDescription: String { "liblsl \(libraryVersion)" }

    static let all: [TestPatternFixtures] = {
        let urls = Bundle.module.urls(
            forResourcesWithExtension: "json", subdirectory: "Fixtures")!
        let decoded = urls.map {
            try! JSONDecoder().decode(TestPatternFixtures.self, from: Data(contentsOf: $0))
        }
        precondition(decoded.count >= 2, "the interop matrix needs at least two versions")
        return decoded.sorted { $0.libraryVersion < $1.libraryVersion }
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
