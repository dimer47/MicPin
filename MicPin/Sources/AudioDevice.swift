import CoreAudio
import Foundation

/// Un périphérique d'entrée audio tel que CoreAudio le décrit.
///
/// L'identité stable d'un périphérique est son `uid`, pas son `id` : l'AudioObjectID
/// est réattribué à chaque rebranchement, l'UID survit aux redémarrages. C'est donc
/// l'UID qui est persisté pour l'épinglage.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    /// `true` si le périphérique expose un contrôle de volume d'entrée réglable.
    ///
    /// Beaucoup de micros USB et Bluetooth n'exposent pas `kAudioDevicePropertyVolumeScalar`
    /// en écriture : leur gain est géré par le matériel. L'interface doit griser le
    /// curseur dans ce cas plutôt que d'échouer silencieusement.
    let hasVolumeControl: Bool

    /// Le canal sur lequel lire et écrire le volume.
    ///
    /// Certains périphériques exposent le volume sur le canal maître (élément 0),
    /// d'autres uniquement sur les canaux individuels (1, 2, …). On mémorise celui
    /// qui répond pour ne pas re-sonder à chaque réglage.
    let volumeChannel: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Nom du symbole SF Symbols qui illustre le type de connexion.
    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "wave.3.right"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: return "square.stack.3d.up"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeThunderbolt: return "bolt"
        default: return "mic"
        }
    }

    /// Libellé lisible du type de connexion, affiché sous le nom du périphérique.
    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Intégré"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAggregate: return "Agrégé"
        case kAudioDeviceTransportTypeVirtual: return "Virtuel"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Autre"
        }
    }
}
