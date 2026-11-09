import CoreAudio
import Foundation

/// Le sens d'un périphérique : entrée (micro) ou sortie (haut-parleurs, casque).
///
/// CoreAudio distingue les deux par un *scope* et par deux propriétés système de
/// périphérique par défaut distinctes. Tout le code bas niveau est paramétré par
/// cette valeur, ce qui permet de gérer entrée et sortie avec une seule logique.
enum AudioScope {
    case input
    case output

    /// Le scope CoreAudio correspondant, pour lire canaux et volume.
    var coreAudio: AudioObjectPropertyScope {
        switch self {
        case .input: return kAudioObjectPropertyScopeInput
        case .output: return kAudioObjectPropertyScopeOutput
        }
    }

    /// La propriété système qui désigne le périphérique par défaut de ce sens.
    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        }
    }
}

/// Un périphérique audio tel que CoreAudio le décrit, en entrée ou en sortie.
///
/// L'identité stable d'un périphérique est son `uid`, pas son `id` : l'AudioObjectID
/// est réattribué à chaque rebranchement, l'UID survit aux redémarrages. C'est donc
/// l'UID qui est persisté pour l'épinglage.
///
/// Un même périphérique physique (un casque USB, par exemple) peut apparaître à la
/// fois en entrée et en sortie : ce sont alors deux `AudioDevice` distincts, de même
/// `uid` mais de `scope` différent.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    /// Le sens de ce périphérique : entrée ou sortie.
    let scope: AudioScope

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
    ///
    /// Le symbole du périphérique intégré et le symbole par défaut dépendent du
    /// sens : pour l'entrée, le micro intégré est le micro du Mac ; pour la sortie,
    /// ce sont ses haut-parleurs. Les transports à symbole propre (USB, Bluetooth,
    /// HDMI…) sont identiques dans les deux sens.
    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return scope == .output ? "speaker.wave.2.fill" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "wave.3.right"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: return "square.stack.3d.up"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeThunderbolt: return "bolt"
        default:
            return scope == .output ? "speaker.wave.2" : "mic"
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
