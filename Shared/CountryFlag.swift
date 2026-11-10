import Foundation

/// An ISO country code to its flag emoji, from the two regional indicator letters.
nonisolated func countryFlag(_ code: String?) -> String? {
    guard let code, code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
    let upper = code.uppercased()
    guard Locale.Region.isoRegions.contains(Locale.Region(upper)) else { return nil }
    return String(String.UnicodeScalarView(upper.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
}
