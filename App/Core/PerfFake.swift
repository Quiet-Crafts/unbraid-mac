import Foundation

#if DEBUG
/// Debug builds only: made-up data for the test copy (tools/perf.sh). Declared here, with the network check, because
/// the core's requests call it and the unit tests compile the core without the app; the made-up apps are in
/// App/PerfHarness.swift.
nonisolated enum PerfFake {
    /// The test copy never reaches a provider: its accounts are made up.
    static func offline() throws {
        if getenv("UNBRAID_PERF") != nil { throw Fail("No network in the test copy") }
    }
}
#endif
