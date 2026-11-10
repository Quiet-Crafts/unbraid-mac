import Foundation
import NetworkExtension

// Engine paths first: the app's commands (configuration checks among them) can arrive before any tunnel starts.
PacketTunnelProvider.setup()
// One listener per process: a mach service can be checked in only once, so it outlives every tunnel and connection.
let commands = CommandXPC()
// A system extension has no run loop of its own: hand control to NetworkExtension, then park the main thread.
autoreleasepool { NEProvider.startSystemExtensionMode() }
dispatchMain()
