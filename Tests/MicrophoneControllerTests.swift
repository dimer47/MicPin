import CoreAudio
import XCTest
@testable import MicPin

/// La logique d'épinglage est la raison d'être de l'app, et c'est là que les
/// défauts coûtent le plus cher : un épinglage perdu, c'est le réglage de
/// l'utilisateur effacé sans qu'il l'ait demandé.
///
/// Ces tests s'exécutent contre le vrai CoreAudio — la machine possède toujours
/// au moins un micro — mais n'écrivent que dans un domaine de préférences isolé.
@MainActor
final class MicrophoneControllerTests: XCTestCase {

    private var suiteName: String!
    private var preferences: Preferences!
    private var controller: MicrophoneController!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.dimer47.MicPin.tests.\(UUID().uuidString)"
        preferences = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        controller = MicrophoneController(preferences: preferences)
    }

    override func tearDown() async throws {
        controller.stopObserving()
        controller = nil
        UserDefaults().removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - État initial

    func testStartsUnpinned() {
        XCTAssertFalse(controller.isPinned)
        XCTAssertNil(controller.pinnedUID)
        XCTAssertNil(preferences.pinnedUID)
    }

    /// Le micro intégré doit remonter en tête : c'est celui vers lequel on
    /// revient le plus souvent, il doit être atteignable sans parcourir la liste.
    func testBuiltInDeviceSortsFirst() throws {
        let devices = controller.devices
        try XCTSkipIf(devices.isEmpty, "Aucun micro sur cette machine")

        guard let builtInIndex = devices.firstIndex(where: \.isBuiltIn) else {
            throw XCTSkip("Aucun micro intégré sur cette machine")
        }
        XCTAssertEqual(builtInIndex, 0, "Le micro intégré doit être en tête")
    }

    // MARK: - Épinglage

    func testPinPersistsUID() throws {
        let device = try firstDevice()

        controller.pin(device)

        XCTAssertTrue(controller.isPinned)
        XCTAssertEqual(controller.pinnedUID, device.uid)
        XCTAssertEqual(preferences.pinnedUID, device.uid,
                       "L'épinglage doit survivre au redémarrage de l'app")
    }

    func testUnpinClearsPreference() throws {
        let device = try firstDevice()
        controller.pin(device)

        controller.unpin()

        XCTAssertFalse(controller.isPinned)
        XCTAssertNil(preferences.pinnedUID)
    }

    func testTogglePin() throws {
        _ = try firstDevice()
        let wasPinned = controller.isPinned

        controller.togglePin()
        XCTAssertNotEqual(controller.isPinned, wasPinned)

        controller.togglePin()
        XCTAssertEqual(controller.isPinned, wasPinned)
    }

    /// L'épinglage se restaure au lancement suivant : c'est ce qui permet de
    /// retrouver son micro après un redémarrage de session.
    func testPinIsRestoredOnNextLaunch() throws {
        let device = try firstDevice()
        controller.pin(device)
        controller.stopObserving()

        let reborn = MicrophoneController(preferences: preferences)
        defer { reborn.stopObserving() }

        XCTAssertTrue(reborn.isPinned)
        XCTAssertEqual(reborn.pinnedUID, device.uid)
    }

    /// Un micro épinglé mais absent — débranché — ne doit pas faire perdre
    /// l'épinglage : il reprendra effet au rebranchement.
    func testMissingPinnedDeviceKeepsThePin() {
        preferences.pinnedUID = "périphérique-qui-n-existe-pas"
        let controller = MicrophoneController(preferences: preferences)
        defer { controller.stopObserving() }

        XCTAssertTrue(controller.isPinned, "L'épinglage est conservé")
        XCTAssertNil(controller.pinnedDevice, "Mais le périphérique reste introuvable")
        XCTAssertTrue(controller.isPinnedDeviceMissing)
        XCTAssertEqual(preferences.pinnedUID, "périphérique-qui-n-existe-pas",
                       "La préférence ne doit surtout pas être effacée")
    }

    // MARK: - Régression : le garde-fou ne doit pas détruire l'épinglage

    /// Une rafale de bascules ne doit jamais effacer la préférence.
    ///
    /// Le garde-fou anti-boucle appelait `unpin()`, qui efface l'UID sur disque.
    /// Un réveil de veille, ou un dock qui réénumère ses périphériques, produit
    /// facilement plus de cinq notifications en dix secondes : l'utilisateur
    /// perdait alors son épinglage sans le savoir. Seule la reprise en main doit
    /// être suspendue.
    func testBurstOfSwitchesDoesNotDestroyThePin() throws {
        let pinned = try firstDevice()
        guard let other = controller.devices.first(where: { $0.id != pinned.id }) else {
            throw XCTSkip("Un seul micro : la bascule ne peut pas être simulée")
        }

        controller.select(pinned)
        controller.pin(pinned)

        // Bien plus que le quota de cinq restaurations par fenêtre de dix secondes.
        for _ in 0..<10 {
            CoreAudioBridge.setDefaultInputDevice(other)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(controller.isPinned,
                      "L'épinglage doit survivre à une rafale de bascules")
        XCTAssertEqual(preferences.pinnedUID, pinned.uid,
                       "La préférence sur disque doit rester intacte")

        // Remettre la machine dans son état d'origine.
        CoreAudioBridge.setDefaultInputDevice(pinned)
    }

    // MARK: - Sélection

    /// `select` doit annoncer son échec : la vue s'en sert pour ne pas épingler
    /// un périphérique qui n'a pas pu être sélectionné.
    func testSelectReturnsSuccess() throws {
        let device = try firstDevice()
        XCTAssertTrue(controller.select(device))
    }

    /// Sélectionner un périphérique inexistant doit échouer sans rien casser.
    func testSelectingAGhostDeviceFails() {
        let ghost = AudioDevice(
            id: AudioObjectID(999_999),
            uid: "fantôme",
            name: "Périphérique inexistant",
            transport: kAudioDeviceTransportTypeUSB,
            hasVolumeControl: false,
            volumeChannel: 0
        )

        XCTAssertFalse(controller.select(ghost))
        XCTAssertNotEqual(controller.pinnedUID, "fantôme",
                          "Un échec de sélection ne doit pas épingler")
    }

    /// `selectAndPin` ne doit pas épingler quand la sélection échoue : sinon la
    /// préférence de volume enregistre celui d'un tout autre micro.
    func testSelectAndPinDoesNotPinOnFailure() {
        let ghost = AudioDevice(
            id: AudioObjectID(999_999),
            uid: "fantôme",
            name: "Périphérique inexistant",
            transport: kAudioDeviceTransportTypeUSB,
            hasVolumeControl: false,
            volumeChannel: 0
        )

        controller.selectAndPin(ghost)

        XCTAssertFalse(controller.isPinned)
        XCTAssertNil(preferences.pinnedUID)
    }

    // MARK: - Volume

    /// Le volume lu doit rester dans les bornes, quel que soit le périphérique.
    func testVolumeStaysWithinBounds() throws {
        _ = try firstDevice()
        XCTAssertGreaterThanOrEqual(controller.volume, 0)
        XCTAssertLessThanOrEqual(controller.volume, 1)
    }

    // MARK: - Outils

    private func firstDevice() throws -> AudioDevice {
        guard let device = controller.devices.first else {
            throw XCTSkip("Aucun micro sur cette machine")
        }
        return device
    }
}
