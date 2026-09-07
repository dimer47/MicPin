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


/// L'analyse de la réponse GitHub décide de remplacer l'application sur la machine
/// de l'utilisateur : elle doit résister à toutes les formes de réponse inattendue.
final class ReleaseParsingTests: XCTestCase {

    private func json(_ raw: String) -> Data {
        Data(raw.utf8)
    }

    /// Réponse conforme, calquée sur une vraie sortie de l'API GitHub.
    private let validResponse = """
    {
      "tag_name": "v2.1.0",
      "published_at": "2026-08-17T09:12:07Z",
      "body": "Notes de version",
      "assets": [
        {
          "name": "MicPin.dmg",
          "size": 666698,
          "browser_download_url": "https://github.com/dimer47/MicPin/releases/download/v2.1.0/MicPin.dmg"
        }
      ]
    }
    """

    func testParsesValidResponse() throws {
        let update = try UpdateChecker.parseRelease(json(validResponse))

        XCTAssertEqual(update.version, "2.1.0", "Le « v » du tag doit être retiré")
        XCTAssertEqual(update.notes, "Notes de version")
        XCTAssertEqual(update.size, 666698)
        XCTAssertEqual(update.downloadURL.lastPathComponent, "MicPin.dmg")
        XCTAssertEqual(
            ISO8601DateFormatter().string(from: update.publishedAt),
            "2026-08-17T09:12:07Z"
        )
    }

    /// Un tag sans préfixe reste valide : rien n'impose le « v ».
    func testTagWithoutVPrefix() throws {
        let raw = validResponse.replacingOccurrences(of: "\"v2.1.0\"", with: "\"2.1.0\"")
        XCTAssertEqual(try UpdateChecker.parseRelease(json(raw)).version, "2.1.0")
    }

    /// Une release sans disque d'installation ne doit pas être proposée : il n'y
    /// aurait rien à installer. Le cas se produit sur une release publiée à la main.
    func testReleaseWithoutDiskImage() {
        let raw = validResponse.replacingOccurrences(of: "MicPin.dmg", with: "MicPin.zip")

        XCTAssertThrowsError(try UpdateChecker.parseRelease(json(raw))) { error in
            XCTAssertEqual(error as? UpdateError, .noDiskImage)
        }
    }

    /// Une liste d'actifs vide ne doit pas planter.
    func testEmptyAssets() {
        let raw = """
        {"tag_name": "v2.0.0", "assets": []}
        """
        XCTAssertThrowsError(try UpdateChecker.parseRelease(json(raw))) { error in
            XCTAssertEqual(error as? UpdateError, .noDiskImage)
        }
    }

    /// Le disque est retrouvé même quand d'autres actifs le précèdent.
    func testPicksDiskImageAmongSeveralAssets() throws {
        let raw = """
        {
          "tag_name": "v3.0.0",
          "assets": [
            {"name": "notes.txt", "size": 12, "browser_download_url": "https://x/notes.txt"},
            {"name": "MicPin.zip", "size": 99, "browser_download_url": "https://x/MicPin.zip"},
            {"name": "MicPin.dmg", "size": 500, "browser_download_url": "https://x/MicPin.dmg"}
          ]
        }
        """
        let update = try UpdateChecker.parseRelease(json(raw))
        XCTAssertEqual(update.size, 500)
        XCTAssertEqual(update.downloadURL.lastPathComponent, "MicPin.dmg")
    }

    /// Un JSON illisible ou tronqué ne doit pas faire planter l'app.
    func testMalformedJSON() {
        for raw in ["", "pas du json", "{", "[]", "{\"autre\": 1}"] {
            XCTAssertThrowsError(try UpdateChecker.parseRelease(json(raw)),
                                 "« \(raw) » aurait dû être rejeté")
        }
    }

    /// Les champs facultatifs manquants prennent une valeur par défaut plutôt que
    /// de faire échouer l'analyse : seuls le tag et le disque sont indispensables.
    func testOptionalFieldsMissing() throws {
        let raw = """
        {
          "tag_name": "v1.5.0",
          "assets": [{"name": "MicPin.dmg", "browser_download_url": "https://x/MicPin.dmg"}]
        }
        """
        let update = try UpdateChecker.parseRelease(json(raw))

        XCTAssertEqual(update.version, "1.5.0")
        XCTAssertEqual(update.notes, "", "Des notes absentes donnent une chaîne vide")
        XCTAssertEqual(update.size, 0, "Une taille absente vaut zéro")
    }

    /// Une date mal formée retombe sur la date du jour plutôt que d'échouer.
    func testInvalidDateFallsBackToNow() throws {
        let raw = validResponse.replacingOccurrences(
            of: "2026-08-17T09:12:07Z", with: "pas une date")
        let update = try UpdateChecker.parseRelease(json(raw))

        XCTAssertLessThan(abs(update.publishedAt.timeIntervalSinceNow), 5)
    }

    /// Une URL de téléchargement vide est refusée : elle ne mène nulle part.
    func testEmptyDownloadURL() {
        let raw = validResponse.replacingOccurrences(
            of: "https://github.com/dimer47/MicPin/releases/download/v2.1.0/MicPin.dmg",
            with: "")
        XCTAssertThrowsError(try UpdateChecker.parseRelease(json(raw)))
    }
}

/// La décision de proposer une mise à jour combine analyse et comparaison : c'est
/// elle qui détermine ce que voit l'utilisateur.
final class UpdateDecisionTests: XCTestCase {

    private func shouldOffer(published: String, installed: String) throws -> Bool {
        let raw = """
        {
          "tag_name": "\(published)",
          "assets": [{"name": "MicPin.dmg", "size": 1, "browser_download_url": "https://x/MicPin.dmg"}]
        }
        """
        let update = try UpdateChecker.parseRelease(Data(raw.utf8))
        return UpdateChecker.isNewer(update.version, than: installed)
    }

    func testOffersNewerVersion() throws {
        XCTAssertTrue(try shouldOffer(published: "v1.1.0", installed: "1.0.0"))
        XCTAssertTrue(try shouldOffer(published: "v2.0.0", installed: "1.9.9"))
    }

    func testDoesNotOfferSameVersion() throws {
        XCTAssertFalse(try shouldOffer(published: "v1.0.0", installed: "1.0.0"))
    }

    /// Cas d'une version de développement en avance sur la dernière release :
    /// rien ne doit être proposé, surtout pas une rétrogradation.
    func testDoesNotOfferOlderVersion() throws {
        XCTAssertFalse(try shouldOffer(published: "v1.0.0", installed: "1.1.0"))
    }
}
