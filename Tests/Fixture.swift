import Foundation

/// Test fixtures copied from the Android project (Tests/Fixtures).
final class Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle(for: Fixture.self).resourceURL!.appending(path: "Fixtures/\(name)")
        return (try? Data(contentsOf: url)) ?? Data()
    }
    static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
}
