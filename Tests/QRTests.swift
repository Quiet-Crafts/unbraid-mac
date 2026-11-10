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
}
