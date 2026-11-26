import CoreGraphics
import Foundation
import ImageIO
import Vision

// Reads the text of a QR code in a picture pasted or dropped into a sign-in field.

nonisolated enum QR {
    static func decode(_ image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        return request.results?.first?.payloadStringValue
    }

    /// Largest picture read: 32 MB of file or paste, 64 million pixels, 20,000 pixels on a side.
    static let maxBytes = 32 * 1024 * 1024, maxPixels = 64_000_000, maxSide = 20_000, readSide = 2000

    /// Whether a picture of this size may be decoded at all; judged from its size and header before any decoding.
    static func fits(bytes: Int, width: Int, height: Int) -> Bool {
        bytes > 0 && bytes <= maxBytes && width > 0 && height > 0 && width <= maxSide && height <= maxSide && width * height <= maxPixels
    }

    /// A file may be read only when it is a regular file of known size within the limit.
    static func fileAllowed(isRegular: Bool, size: Int?) -> Bool { isRegular && size.map { $0 > 0 && $0 <= maxBytes } == true }

    /// The file's bytes, reading at most `limit` + 1 so a file that grew or lied about its size still stops; nil if over the limit.
    static func boundedData(of file: URL, limit: Int = maxBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    enum Outcome: Equatable { case found(String), none, tooLarge }

    /// Reads a QR code from picture data or a picture file, off the caller's thread. The header is checked first, then the
    /// picture is decoded at no more than `readSide` pixels a side, which is plenty for a code and keeps memory small.
    static func read(data: Data? = nil, file: URL? = nil) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            var data = data
            if let file {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard fileAllowed(isRegular: values?.isRegularFile == true, size: values?.fileSize), let loaded = boundedData(of: file) else { return .tooLarge }
                data = loaded
            }
            let bytes = data?.count ?? 0
            guard bytes <= maxBytes else { return .tooLarge }
            let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            guard let source, let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return .none }
            guard fits(bytes: max(bytes, 1), width: w, height: h) else { return .tooLarge }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), readSide)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let value = decode(image) else { return .none }
            return .found(value)
        }.value
    }
}
