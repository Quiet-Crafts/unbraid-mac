import CoreGraphics
import Vision

// Reads the text of a QR code in a picture pasted or dropped into a sign-in field.

nonisolated enum QR {
    static func decode(_ image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        return request.results?.first?.payloadStringValue
    }
}
