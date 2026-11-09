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
        // Clés historiques de l'entrée, conservées telles quelles pour ne pas
        // perdre l'épinglage des utilisateurs déjà installés.
        static let pinnedInputUID = "pinnedDeviceUID"
        static let pinnedInputVolume = "pinnedDeviceVolume"
        // Clés de la sortie, introduites avec la gestion du son sortant.
        static let pinnedOutputUID = "pinnedOutputDeviceUID"
        static let pinnedOutputVolume = "pinnedOutputDeviceVolume"
        static let updatesDisabled = "automaticUpdatesDisabled"

        static func uid(for scope: AudioScope) -> String {
            scope == .output ? pinnedOutputUID : pinnedInputUID
        }

        static func volume(for scope: AudioScope) -> String {
            scope == .output ? pinnedOutputVolume : pinnedInputVolume
        }
    }

    /// `nonisolated(unsafe)` : `UserDefaults` est thread-safe d'après sa
    /// documentation, mais n'est pas annoté `Sendable` dans le SDK.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// UID du périphérique épinglé dans ce sens. L'UID, et non l'AudioObjectID, car
    /// ce dernier change à chaque rebranchement.
    func pinnedDeviceUID(for scope: AudioScope) -> String? {
        defaults.string(forKey: Key.uid(for: scope))
    }

    func setPinnedUID(_ uid: String?, for scope: AudioScope) {
        defaults.set(uid, forKey: Key.uid(for: scope))
    }

    /// Volume à restaurer avec le périphérique épinglé dans ce sens, entre 0 et 1.
    ///
    /// Distinct de « pas de valeur » : un volume nul est un réglage valide, alors
    /// qu'une absence de valeur signifie qu'aucun volume n'a encore été mémorisé et
    /// qu'il ne faut donc rien restaurer.
    func pinnedDeviceVolume(for scope: AudioScope) -> Float? {
        let key = Key.volume(for: scope)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.float(forKey: key)
    }

    func setPinnedVolume(_ volume: Float?, for scope: AudioScope) {
        let key = Key.volume(for: scope)
        if let volume {
            defaults.set(volume, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // Raccourcis sur l'entrée, pour les appelants et les tests qui ne gèrent qu'elle.
    var pinnedUID: String? {
        get { pinnedDeviceUID(for: .input) }
        set { setPinnedUID(newValue, for: .input) }
    }

    var pinnedVolume: Float? {
        get { pinnedDeviceVolume(for: .input) }
        set { setPinnedVolume(newValue, for: .input) }
    }

    /// Vérification quotidienne des mises à jour.
    ///
    /// Activée par défaut : `bool(forKey:)` renvoie `false` pour une clé absente,
    /// on inverse donc le sens du stockage pour qu'une première exécution, sans
    /// préférence enregistrée, surveille les mises à jour.
    var automaticUpdates: Bool {
        get { !defaults.bool(forKey: Key.updatesDisabled) }
        set { defaults.set(!newValue, forKey: Key.updatesDisabled) }
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
