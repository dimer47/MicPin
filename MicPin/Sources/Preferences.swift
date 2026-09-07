import Foundation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "com.dimer47.MicPin", category: "Preferences")

/// Réglages persistés entre les lancements.
///
/// `Sendable` sans verrou interne : le seul état est `UserDefaults`, dont l'accès
/// est déjà thread-safe, et `SMAppService`, sans état propre. La classe ne détient
/// aucune variable mutable.
final class Preferences: Sendable {
    static let shared = Preferences()

    private enum Key {
        static let pinnedUID = "pinnedDeviceUID"
        static let pinnedVolume = "pinnedDeviceVolume"
    }

    /// `nonisolated(unsafe)` : `UserDefaults` est thread-safe d'après sa
    /// documentation, mais n'est pas annoté `Sendable` dans le SDK.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// UID du micro épinglé. L'UID, et non l'AudioObjectID, car ce dernier change
    /// à chaque rebranchement.
    var pinnedUID: String? {
        get { defaults.string(forKey: Key.pinnedUID) }
        set { defaults.set(newValue, forKey: Key.pinnedUID) }
    }

    /// Volume à restaurer avec le micro épinglé, entre 0 et 1.
    ///
    /// Distinct de « pas de valeur » : un volume nul est un réglage valide, alors
    /// qu'une absence de valeur signifie qu'aucun volume n'a encore été mémorisé et
    /// qu'il ne faut donc rien restaurer.
    var pinnedVolume: Float? {
        get {
            guard defaults.object(forKey: Key.pinnedVolume) != nil else { return nil }
            return defaults.float(forKey: Key.pinnedVolume)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.pinnedVolume)
            } else {
                defaults.removeObject(forKey: Key.pinnedVolume)
            }
        }
    }

    // MARK: - Lancement au démarrage de session

    /// Indique si l'app est enregistrée pour démarrer à l'ouverture de session.
    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Active ou désactive le lancement au démarrage.
    ///
    /// Retourne `false` si l'opération a échoué — typiquement quand l'app n'est pas
    /// dans /Applications, `SMAppService` refusant d'enregistrer une app lancée
    /// depuis un dossier de build.
    @discardableResult
    func setLaunchesAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error("Échec du réglage du lancement au démarrage : \(error.localizedDescription)")
            return false
        }
    }
}
