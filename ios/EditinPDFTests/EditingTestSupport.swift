import Foundation
import XCTest

/// Helpers shared by the editing tests.

/// The bytes of `<name>.pdf` from the test bundle's Fixtures.
func fixtureData(_ name: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleMarker.self)
    return try Data(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: "pdf"), "no fixture \(name).pdf"))
}

/// Names the test bundle for `Bundle(for:)`.
private final class FixtureBundleMarker {}
