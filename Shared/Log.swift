import Foundation
import os

/// One logger for every target. What the code itself writes is public, so Release logs still say what happened; text
/// from the engine, a library or the network is private (it can name a self-hosted server, a Headscale host or an
/// address): a sysdiagnose shows it as <private>. Never log secrets.
nonisolated enum Log {
    private static let log = Logger(subsystem: "app.unbraid", category: "unbraid")

    /// A message written in the code: public.
    static func info(_ s: StaticString) { log.info("\(s.description, privacy: .public)") }
    static func error(_ s: StaticString) { log.error("\(s.description, privacy: .public)") }

    /// What happened, public, and a detail from outside the code (an engine or library error, a server's answer):
    /// private.
    static func info(_ s: StaticString, detail: String) { log.info("\(s.description, privacy: .public): \(detail, privacy: .private)") }
    static func error(_ s: StaticString, detail: String) { log.error("\(s.description, privacy: .public): \(detail, privacy: .private)") }

    /// What happened and figures the code makes itself (a count, a status code, an error's type and code): all public.
    /// Never text from outside the code.
    static func info(_ s: StaticString, facts: String) { log.info("\(s.description, privacy: .public): \(facts, privacy: .public)") }
    static func error(_ s: StaticString, facts: String) { log.error("\(s.description, privacy: .public): \(facts, privacy: .public)") }

    /// What happened, public, and an error: its code, and its domain when it is one of the system's own, public; its
    /// description private.
    static func error(_ s: StaticString, error: Error) {
        let e = error as NSError
        let domain = systemDomains.contains(e.domain) ? e.domain : "other"
        log.error("\(s.description, privacy: .public): \(domain, privacy: .public) \(e.code, privacy: .public), \(Redact.clean(e.localizedDescription), privacy: .private)")
    }
    private static let systemDomains: Set<String> = [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSCocoaErrorDomain]

    /// A message built at run time from anything else: private as a whole. A plain literal picks the public overload
    /// above; this one only takes interpolated strings.
    @_disfavoredOverload static func info(_ s: String) { log.info("\(s, privacy: .private)") }
    @_disfavoredOverload static func error(_ s: String) { log.error("\(s, privacy: .private)") }
}
