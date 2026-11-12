import Foundation

/// Where this copy of unbraid runs from, and whether another copy has the better claim to run. macOS installs a system
/// extension only for an app in /Applications, and two copies would overwrite each other's saved setup and count every
/// statistic twice.
nonisolated enum InstallPlace {
    /// A running copy of unbraid.
    struct Copy: Equatable {
        var path: String
        var launched: Date?
        var pid: Int32
    }

    /// In /Applications, or a folder inside it. Not a disk image (/Volumes), not a quarantined copy that macOS runs from
    /// a temporary place (AppTranslocation), not Downloads or the home folder's own Applications.
    static func isInApplications(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix("/Applications/")
    }

    /// Whether `other` should keep running and `me` hand over to it. A copy in /Applications beats one that isn't (that one
    /// can't set up the VPN anyway); otherwise the one started first stays, and the process number breaks a tie, so of
    /// two copies started together exactly one quits.
    static func outranks(_ other: Copy, _ me: Copy) -> Bool {
        guard other.pid != me.pid else { return false }
        let there = isInApplications(other.path), here = isInApplications(me.path)
        if there != here { return there }
        // Without a start date on either side there is nothing to compare: the process number decides, so exactly one of
        // two copies yields whatever is known about them.
        if let a = other.launched, let b = me.launched, a != b { return a < b }
        return other.pid < me.pid
    }
}
