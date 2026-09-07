import CoreAudio
import XCTest
@testable import MicPin

/// Le type de connexion détermine l'icône et le libellé affichés pour chaque
/// micro : c'est ce qui permet de distinguer deux périphériques de même nom.
final class AudioDeviceTests: XCTestCase {

    private func device(transport: UInt32, name: String = "Micro") -> AudioDevice {
        AudioDevice(
            id: 1,
            uid: "uid",
            name: name,
            transport: transport,
            hasVolumeControl: true,
            volumeChannel: 0
        )
    }

    func testBuiltInDetection() {
        XCTAssertTrue(device(transport: kAudioDeviceTransportTypeBuiltIn).isBuiltIn)
        XCTAssertFalse(device(transport: kAudioDeviceTransportTypeUSB).isBuiltIn)
        XCTAssertFalse(device(transport: kAudioDeviceTransportTypeBluetooth).isBuiltIn)
    }

    func testTransportLabels() {
        XCTAssertEqual(device(transport: kAudioDeviceTransportTypeBuiltIn).transportLabel, "Intégré")
        XCTAssertEqual(device(transport: kAudioDeviceTransportTypeUSB).transportLabel, "USB")
        XCTAssertEqual(device(transport: kAudioDeviceTransportTypeBluetooth).transportLabel, "Bluetooth")
        XCTAssertEqual(device(transport: kAudioDeviceTransportTypeVirtual).transportLabel, "Virtuel")
    }

    /// Un transport inconnu ne doit ni planter ni laisser un libellé vide : les
    /// périphériques exotiques existent, et l'interface doit rester lisible.
    func testUnknownTransportFallsBack() {
        let unknown = device(transport: 0x7A7A7A7A)
        XCTAssertEqual(unknown.transportLabel, "Autre")
        XCTAssertEqual(unknown.symbolName, "mic")
    }

    /// Chaque type de connexion doit donner un symbole SF Symbols réel : un nom
    /// inexistant afficherait un blanc dans la liste.
    func testSymbolNamesExist() {
        let transports: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeAirPlay,
            0x7A7A7A7A,
        ]

        for transport in transports {
            let name = device(transport: transport).symbolName
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "Le symbole « \(name) » n'existe pas dans SF Symbols"
            )
        }
    }

    /// L'identité repose sur l'UID : deux périphériques d'UID différents ne sont
    /// jamais le même, même si tout le reste coïncide.
    func testEquality() {
        let a = device(transport: kAudioDeviceTransportTypeUSB)
        var b = a
        XCTAssertEqual(a, b)

        b = AudioDevice(id: 1, uid: "autre", name: "Micro",
                        transport: kAudioDeviceTransportTypeUSB,
                        hasVolumeControl: true, volumeChannel: 0)
        XCTAssertNotEqual(a, b)
    }
}

/// L'icône de la barre des menus porte la marge latérale, faute de pouvoir
/// l'obtenir par un `padding` SwiftUI que `MenuBarExtra` ignore.
final class MenuBarIconTests: XCTestCase {

    /// L'image doit être plus large que le symbole nu, sinon l'icône se colle à
    /// ses voisines dans la barre.
    func testIconCarriesHorizontalPadding() {
        let padded = MenuBarIcon.image(symbolName: "mic")
        let bare = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!

        XCTAssertGreaterThan(
            padded.size.width, bare.size.width,
            "L'icône doit être élargie pour ménager une marge"
        )
        XCTAssertEqual(padded.size.height, bare.size.height, accuracy: 0.5,
                       "La hauteur ne doit pas changer")
    }

    /// Marquée `isTemplate`, l'image est recolorée par macOS selon le thème :
    /// sans cela elle resterait noire sur une barre sombre.
    func testIconIsTemplate() {
        XCTAssertTrue(MenuBarIcon.image(symbolName: "mic").isTemplate)
    }

    /// Un symbole absent ne doit pas produire d'image vide de taille nulle, qui
    /// ferait disparaître l'élément de la barre.
    func testMissingSymbolStillReturnsAnImage() {
        let image = MenuBarIcon.image(symbolName: "symbole.qui.n.existe.pas")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// Les trois symboles affichés selon l'état doivent tous exister.
    func testStateSymbolsExist() {
        for name in ["mic", "mic.badge.plus", "mic.slash"] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "Le symbole d'état « \(name) » n'existe pas"
            )
        }
    }
}
