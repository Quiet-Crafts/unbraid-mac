import XCTest

final class ExitAddressTests: XCTestCase {
    func testTraceParsing() {
        XCTAssertEqual(ExitAddress.parse("h=www.cloudflare.com\nip=203.0.113.42\nloc=NL\n"), "203.0.113.42")
        XCTAssertEqual(ExitAddress.parse("ip=2001:db8::1\n"), "2001:db8::1")
        for input in ["ip=999.1.1.1", "ip=<b>hi</b>", "<html>blocked</html>", " ip=1.2.3.4"] { XCTAssertNil(ExitAddress.parse(input)) }
    }
    func testIPv4LeadingZeros() {
        for valid in ["0.0.0.0", "10.0.0.1", "203.0.113.42", "255.255.255.255"] { XCTAssertTrue(ExitAddress.ipv4(valid), valid) }
        for invalid in ["01.2.3.4", "1.2.3.04", "00.0.0.0", "001.2.3.4", "1.2.3.010"] { XCTAssertFalse(ExitAddress.ipv4(invalid), invalid) }
        XCTAssertNil(ExitAddress.parse("ip=01.2.3.4\n"))
    }
    func testIPv6() {
        for valid in ["2001:db8::1", "::1", "fe80::", "2001:0db8:0000:0000:0000:ff00:0042:8329"] { XCTAssertTrue(ExitAddress.ipv6(valid), valid) }
        for invalid in ["::::", "1:2", "1:2:3:4:5:6:7:8:9", "2001:db8::1::2", "2001:db8:::1", "12345::1", "g::1", "١::1"] { XCTAssertFalse(ExitAddress.ipv6(invalid), invalid) }
    }
}
