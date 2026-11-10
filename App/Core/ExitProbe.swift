import Foundation

/// Runs one check per tunnel, with a shared deadline for both hosts.
nonisolated enum ExitProbe {
    static let hosts = ["www.cloudflare.com", "one.one.one.one"]

    static func ask(_ tags: Set<String>, timeout: Duration = .seconds(20),
                    fetch: @escaping @Sendable (String, String) async -> String?) async -> [String: String] {
        let tags = Array(tags).sorted()
        return await withTaskGroup(of: (String, String?).self, returning: [String: String].self) { group in
            var next = 0
            func add() {
                guard next < tags.count else { return }
                let tag = tags[next]; next += 1
                group.addTask { (tag, await trace(tag, timeout: timeout, fetch: fetch)) }
            }
            for _ in 0..<min(4, tags.count) { add() }
            var answers: [String: String] = [:]
            while let (tag, answer) = await group.next() {
                if let answer { answers[tag] = answer }
                if !Task.isCancelled { add() }
            }
            return answers
        }
    }

    private static func trace(_ tag: String, timeout: Duration,
                              fetch: @escaping @Sendable (String, String) async -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for host in hosts {
                    guard !Task.isCancelled else { return nil }
                    if let answer = await fetch(tag, host) { return answer }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
