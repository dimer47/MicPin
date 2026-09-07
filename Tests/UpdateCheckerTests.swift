import XCTest
@testable import MicPin

/// La comparaison de versions décide si une mise à jour est proposée : une
/// erreur ici ferait soit manquer une version, soit en proposer une plus ancienne.
final class VersionComparisonTests: XCTestCase {

    private func isNewer(_ a: String, _ b: String) -> Bool {
        UpdateChecker.isNewer(a, than: b)
    }

    func testHigherVersion() {
        XCTAssertTrue(isNewer("1.1.0", "1.0.0"))
        XCTAssertTrue(isNewer("2.0.0", "1.9.9"))
        XCTAssertTrue(isNewer("1.0.1", "1.0.0"))
    }

    func testLowerVersion() {
        XCTAssertFalse(isNewer("1.0.0", "1.1.0"))
        XCTAssertFalse(isNewer("1.9.9", "2.0.0"))
    }

    func testIdenticalVersion() {
        XCTAssertFalse(isNewer("1.0.0", "1.0.0"))
        XCTAssertFalse(isNewer("2.5.3", "2.5.3"))
    }

    /// Le piège d'une comparaison de chaînes : « 1.10.0 » y serait inférieur à
    /// « 1.9.0 », puisque le caractère « 1 » précède « 9 ».
    func testTwoDigitSegments() {
        XCTAssertTrue(isNewer("1.10.0", "1.9.0"))
        XCTAssertTrue(isNewer("1.0.10", "1.0.9"))
        XCTAssertTrue(isNewer("10.0.0", "9.0.0"))
        XCTAssertFalse(isNewer("1.9.0", "1.10.0"))
    }

    /// Les segments absents comptent pour zéro : « 1.1 » vaut « 1.1.0 ».
    func testDifferentSegmentCounts() {
        XCTAssertTrue(isNewer("1.1", "1.0.9"))
        XCTAssertFalse(isNewer("1.0", "1.0.0"))
        XCTAssertTrue(isNewer("1.0.1", "1.0"))
    }

    /// Un suffixe de pré-version ne doit pas faire échouer l'analyse.
    func testSuffixedSegments() {
        XCTAssertTrue(isNewer("1.2.0-beta", "1.1.0"))
        XCTAssertFalse(isNewer("1.0.0-beta", "1.0.0"))
    }

    /// Une chaîne vide ou illisible ne doit pas déclencher de mise à jour.
    func testMalformedVersions() {
        XCTAssertFalse(isNewer("", "1.0.0"))
        XCTAssertFalse(isNewer("abc", "1.0.0"))
        XCTAssertTrue(isNewer("1.0.0", ""))
    }
}
