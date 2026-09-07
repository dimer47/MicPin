import XCTest
@testable import MicPin

/// Les préférences portent l'épinglage : une erreur ici fait perdre le réglage
/// de l'utilisateur entre deux lancements.
final class PreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: Preferences!

    override func setUp() {
        super.setUp()
        // Un domaine distinct par test : les préférences réelles de l'utilisateur
        // ne doivent jamais être touchées par la suite de tests.
        suiteName = "com.dimer47.MicPin.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        preferences = Preferences(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPinnedUIDRoundTrip() {
        XCTAssertNil(preferences.pinnedUID)

        preferences.pinnedUID = "BuiltInMicrophoneDevice"
        XCTAssertEqual(preferences.pinnedUID, "BuiltInMicrophoneDevice")

        preferences.pinnedUID = nil
        XCTAssertNil(preferences.pinnedUID)
    }

    /// Le piège classique de `UserDefaults.float(forKey:)` : il renvoie 0 pour
    /// une clé absente, ce qui rend un volume nul indiscernable d'une absence de
    /// réglage. Or les deux commandent des comportements opposés — restaurer le
    /// silence, ou ne rien restaurer du tout.
    func testZeroVolumeIsDistinctFromNoVolume() {
        XCTAssertNil(preferences.pinnedVolume, "Aucun volume n'a encore été enregistré")

        preferences.pinnedVolume = 0
        XCTAssertEqual(preferences.pinnedVolume, 0, "Un volume nul est un réglage valide")

        preferences.pinnedVolume = nil
        XCTAssertNil(preferences.pinnedVolume, "Le réglage a été effacé")
    }

    func testVolumeRoundTrip() {
        preferences.pinnedVolume = 0.42
        XCTAssertEqual(preferences.pinnedVolume ?? -1, 0.42, accuracy: 0.0001)

        preferences.pinnedVolume = 1
        XCTAssertEqual(preferences.pinnedVolume ?? -1, 1, accuracy: 0.0001)
    }

    /// La surveillance des mises à jour doit être active dès la première
    /// exécution, quand aucune préférence n'est encore enregistrée.
    func testAutomaticUpdatesEnabledByDefault() {
        XCTAssertTrue(preferences.automaticUpdates)

        preferences.automaticUpdates = false
        XCTAssertFalse(preferences.automaticUpdates)

        preferences.automaticUpdates = true
        XCTAssertTrue(preferences.automaticUpdates)
    }
}
