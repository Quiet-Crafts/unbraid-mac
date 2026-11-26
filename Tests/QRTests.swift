import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins

final class QRTests: XCTestCase {
    func testGeneratedQR() throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("i-ABCD-EFGH-IJKL".utf8)
        let image = try XCTUnwrap(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        XCTAssertEqual(QR.decode(cg), "i-ABCD-EFGH-IJKL")
    }

    func testSizeLimitsAreJudgedBeforeDecoding() {
        XCTAssertTrue(QR.fits(bytes: 1000, width: 4000, height: 3000))
        XCTAssertFalse(QR.fits(bytes: QR.maxBytes + 1, width: 100, height: 100))
        XCTAssertFalse(QR.fits(bytes: 1000, width: QR.maxSide + 1, height: 1))
        XCTAssertFalse(QR.fits(bytes: 1000, width: 10_000, height: 10_000))
        XCTAssertFalse(QR.fits(bytes: 0, width: 10, height: 10))
    }

    func testFilesAreCheckedAndReadWithinTheByteLimit() async throws {
        XCTAssertTrue(QR.fileAllowed(isRegular: true, size: 1000))
        XCTAssertFalse(QR.fileAllowed(isRegular: false, size: 1000))
        XCTAssertFalse(QR.fileAllowed(isRegular: true, size: nil))
        XCTAssertFalse(QR.fileAllowed(isRegular: true, size: QR.maxBytes + 1))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        try Data(count: 11).write(to: file)
        XCTAssertEqual(QR.boundedData(of: file, limit: 11)?.count, 11)
        XCTAssertNil(QR.boundedData(of: file, limit: 10))
        let folder = await QR.read(file: dir)
        XCTAssertEqual(folder, .tooLarge)
        let missing = await QR.read(file: dir.appendingPathComponent("none.png"))
        XCTAssertEqual(missing, .tooLarge)
    }

    func testAHugePictureIsRefusedAndAnOrdinaryOneRead() async throws {
        func png(_ image: CGImage) throws -> Data {
            let out = NSMutableData()
            let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            return out as Data
        }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: QR.maxSide + 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let refused = await QR.read(data: try png(try XCTUnwrap(ctx.makeImage())))
        XCTAssertEqual(refused, .tooLarge)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("i-ABCD-EFGH-IJKL".utf8)
        let image = try XCTUnwrap(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let found = await QR.read(data: try png(cg))
        XCTAssertEqual(found, .found("i-ABCD-EFGH-IJKL"))
        let none = await QR.read(data: Data("not a picture".utf8))
        XCTAssertEqual(none, .none)
    }
}
