import XCTest

final class CatalogTests: XCTestCase {
    func testCountryCodes() {
        let codes = [
            "Netherlands": "NL", "United States": "US", "USA": "US", "Hong Kong": "HK", "Macau": "MO", "Turkey": "TR",
            "Myanmar": "MM", "Czech Republic": "CZ", "United Kingdom": "GB", "UK": "GB", "South Korea": "KR",
            "Bosnia and Herzegovina": "BA", "United Arab Emirates": "AE", "Italy": "IT", "Switzerland": "CH",
            "Democratic Republic of the Congo": "CD", "Cote d'Ivoire": "CI", "Brunei Darussalam": "BN", "Palestine, State of": "PS",
            "Atlantis": "··",
        ]
        for (name, code) in codes { XCTAssertEqual(Catalog.code(name), code, name) }
    }

    func testEveryCatalogueCountryGetsARealIsoCode() throws {
        for p in ["protonvpn", "surfshark", "airvpn", "expressvpn"] {
            let entries = try ProviderFixtures.catalog(p)
            XCTAssertFalse(entries.isEmpty)
            let bad = Catalog.countries(entries).filter { !ProviderFixtures.iso.contains($0.code) }
            XCTAssertEqual(bad, [], p)
        }
    }
}
