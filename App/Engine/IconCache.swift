import AppKit
import Synchronization

/// App icons, drawn small off the main thread: a row never waits for the disk, and never scales down a 1024-pixel icon
/// as it draws. Kept across rescans, which happen each time unbraid comes to the front, and redrawn only for a bundle
/// that changed on disk.
nonisolated final class IconCache: Sendable {
    /// 32 points at twice that in pixels: the largest size the lists use.
    private static let points: CGFloat = 32
    private let images = Mutex<[String: NSImageBox]>([:])
    private let stamps = Mutex<[String: Double]>([:])

    private struct NSImageBox: @unchecked Sendable { let image: NSImage }

    private static let generic = NSImageBox(image: NSWorkspace.shared.icon(for: .applicationBundle))
    static var genericIcon: NSImage { generic.image }

    /// The icon, now: the one drawn earlier, or drawn here if the background pass hasn't reached it.
    func image(_ path: String) -> NSImage {
        if let done = images.withLock({ $0[path] }) { return done.image }
        let drawn = Self.draw(path)
        images.withLock { $0[path] = NSImageBox(image: drawn) }
        return drawn
    }

    /// Draws what is new or changed, off the main thread. True when a row on screen may need the new picture.
    /// One at a time (AppCatalog chains them): two at once could leave an older picture under a newer stamp.
    func refresh(_ paths: [String]) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            var changed = false
            for path in paths {
                let stamp = Self.stamp(path)
                guard stamps.withLock({ $0[path] }) != stamp else { continue }
                let known = stamps.withLock { all in defer { all[path] = stamp }; return all[path] != nil }
                let drawn = NSImageBox(image: Self.draw(path))
                images.withLock { $0[path] = drawn }
                changed = changed || known
            }
            let keep = Set(paths)
            images.withLock { $0 = $0.filter { keep.contains($0.key) } }
            stamps.withLock { $0 = $0.filter { keep.contains($0.key) } }
            return changed
        }.value
    }

    /// When the bundle last changed, as far as it shows: an update in place rewrites its Info.plist or its resources.
    private static func stamp(_ path: String) -> Double {
        [path, path + "/Contents/Info.plist", path + "/Contents/Resources"].reduce(0) { latest, place in
            var st = stat()
            return stat(place, &st) == 0 ? max(latest, Double(st.st_mtimespec.tv_sec)) : latest
        }
    }

    private static func draw(_ path: String) -> NSImage {
        let full = NSWorkspace.shared.icon(forFile: path)
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return full }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: points, height: points)
        let small = NSImage(size: rep.size)
        small.addRepresentation(rep)
        return small
    }
}
