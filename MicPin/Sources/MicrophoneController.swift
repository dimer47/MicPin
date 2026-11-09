import CoreAudio
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.dimer47.MicPin", category: "Controller")

/// État d'un sens audio : liste des périphériques, périphérique courant, volume,
/// épinglage. Une instance gère l'entrée (micro), une autre la sortie (haut-parleurs).
///
/// Le mode épinglé est la raison d'être de l'app : macOS promeut spontanément tout
/// nouveau périphérique en défaut (branchement d'écouteurs, appairage Bluetooth,
/// réveil de veille), et chaque périphérique conserve son propre volume. Quand un
/// périphérique est épinglé, ce contrôleur observe les bascules et restaure aussitôt
/// le périphérique voulu *et* son volume.
///
/// La logique est identique en entrée et en sortie : seuls changent le scope
/// CoreAudio interrogé, les clés de préférences et — pour l'entrée seule — le
/// maintien du micro éveillé, qui n'a pas de sens pour la sortie.
@MainActor
@Observable
final class AudioDeviceController {

    /// Le sens géré par ce contrôleur.
    let scope: AudioScope

    // MARK: - État publié

    private(set) var devices: [AudioDevice] = []
    private(set) var currentDeviceID: AudioObjectID?

    /// Volume du périphérique courant, entre 0 et 1.
    ///
    /// L'écriture est propagée à CoreAudio, et mémorisée pour le périphérique
    /// épinglé afin d'être restaurée lors d'une reprise en main.
    var volume: Float = 0 {
        didSet {
            // `Slider` réémet la même valeur à chaque évènement souris ; sans ce
            // garde, chaque frame de glissement provoque une écriture CoreAudio.
            guard volume != oldValue else { return }
            guard !isSyncingVolume, let device = currentDevice else { return }
            CoreAudioBridge.setVolume(volume, on: device)
            if device.uid == pinnedUID {
                preferences.setPinnedVolume(volume, for: scope)
            }
        }
    }

    /// UID du périphérique épinglé, ou `nil` si l'épinglage est désactivé.
    private(set) var pinnedUID: String?

    /// Dernière reprise en main effectuée, pour l'afficher dans l'interface.
    private(set) var lastRestoration: Date?

    /// Maintien du micro éveillé, piloté depuis le panneau. Présent pour l'entrée
    /// seule : la notion n'a pas d'équivalent en sortie.
    let keepAlive: MicrophoneKeepAlive?

    // MARK: - Interne

    private let preferences: Preferences
    private var deviceListObservation: CoreAudioBridge.Observation?
    private var defaultDeviceObservation: CoreAudioBridge.Observation?

    /// Empêche l'écriture CoreAudio quand `volume` est mis à jour depuis le matériel.
    private var isSyncingVolume = false

    /// Garde-fou contre une boucle de restauration.
    ///
    /// Si un périphérique refuse de rester sélectionné, réécrire indéfiniment
    /// le périphérique par défaut ferait tourner l'app en boucle avec CoreAudio. On
    /// limite donc les tentatives rapprochées, et on suspend la reprise au-delà.
    private var recentRestorations: [Date] = []
    private let restorationWindow: TimeInterval = 10
    private let maxRestorationsPerWindow = 5

    /// Suspend la reprise en main sans lever l'épinglage.
    ///
    /// Distinct de `unpin()`, qui efface la préférence sur disque : un réveil de
    /// veille ou un dock Thunderbolt qui réénumère ses périphériques produit une
    /// rafale de notifications capable d'épuiser le quota. Effacer le choix de
    /// l'utilisateur dans ce cas lui ferait perdre son réglage sans qu'il l'ait
    /// demandé. La suspension se lève d'elle-même à la fenêtre suivante.
    private var suspendedUntil: Date?

    var currentDevice: AudioDevice? {
        guard let currentDeviceID else { return nil }
        return devices.first { $0.id == currentDeviceID }
    }

    var pinnedDevice: AudioDevice? {
        guard let pinnedUID else { return nil }
        return devices.first { $0.uid == pinnedUID }
    }

    var isPinned: Bool { pinnedUID != nil }

    /// `true` quand un périphérique est épinglé mais absent — débranché, par exemple.
    /// L'épinglage reste mémorisé : il reprendra effet au rebranchement.
    var isPinnedDeviceMissing: Bool { isPinned && pinnedDevice == nil }

    // MARK: - Cycle de vie

    init(scope: AudioScope, preferences: Preferences = .shared) {
        self.scope = scope
        self.preferences = preferences
        self.pinnedUID = preferences.pinnedDeviceUID(for: scope)
        self.keepAlive = scope == .input ? MicrophoneKeepAlive() : nil

        refreshDevices()
        startObserving()

        // Au lancement, macOS a pu basculer de périphérique pendant que l'app ne
        // tournait pas : on réapplique immédiatement l'épinglage.
        enforcePinIfNeeded()
    }

    /// Coupe les observations CoreAudio.
    ///
    /// Appelé explicitement avant de quitter, et non depuis `deinit` : celui-ci est
    /// `nonisolated` sur une classe `@MainActor` et ne peut pas toucher à l'état
    /// isolé. Le contrôleur vit de toute façon aussi longtemps que l'app.
    func stopObserving() {
        deviceListObservation?.cancel()
        deviceListObservation = nil
        defaultDeviceObservation?.cancel()
        defaultDeviceObservation = nil
    }

    private func startObserving() {
        // `MainActor.assumeIsolated` plutôt que `Task { @MainActor in }` : le bloc
        // arrive déjà sur la file principale, et un saut supplémentaire retarderait
        // la reprise en main d'un tour de boucle d'évènements.
        deviceListObservation = CoreAudioBridge.observeDeviceList { [weak self] in
            MainActor.assumeIsolated { self?.handleDeviceListChange() }
        }

        defaultDeviceObservation = CoreAudioBridge.observeDefaultDevice(scope: scope) { [weak self] in
            MainActor.assumeIsolated { self?.handleDefaultDeviceChange() }
        }
    }

    // MARK: - Réactions aux évènements CoreAudio

    private func handleDeviceListChange() {
        refreshDevices()
        // Un périphérique vient d'apparaître ou de disparaître : c'est exactement
        // le moment où macOS rebascule le périphérique par défaut.
        enforcePinIfNeeded()
    }

    private func handleDefaultDeviceChange() {
        // Rafraîchir la liste avant d'agir : CoreAudio ne garantit pas l'ordre
        // entre la notification de bascule et celle de la liste des périphériques.
        // Sans cela, un débranchement-rebranchement rapide laisse dans `devices`
        // un AudioObjectID périmé, et la restauration écrit un ID inexistant.
        refreshDevices()
        enforcePinIfNeeded()
    }

    // MARK: - Rafraîchissement

    func refreshDevices() {
        devices = CoreAudioBridge.devices(scope: scope).sorted { lhs, rhs in
            // Le périphérique intégré remonte en tête : c'est celui vers lequel on
            // revient le plus souvent, il doit être atteignable sans parcourir la liste.
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        syncCurrentDevice()
    }

    /// Recharge le périphérique courant et son volume depuis CoreAudio.
    private func syncCurrentDevice() {
        currentDeviceID = CoreAudioBridge.defaultDeviceID(scope: scope)

        isSyncingVolume = true
        defer { isSyncingVolume = false }

        // Sans périphérique courant, `volume` est remis à zéro plutôt que de
        // conserver le niveau du précédent, qui ne veut plus rien dire.
        guard let device = currentDevice else {
            volume = 0
            return
        }
        volume = CoreAudioBridge.volume(of: device) ?? 0
    }

    // MARK: - Actions

    /// Sélectionne un périphérique comme défaut du système dans ce sens.
    ///
    /// Si un épinglage est actif, choisir un autre périphérique déplace l'épinglage :
    /// sans cela, la sélection serait annulée dans la seconde par la reprise en main.
    ///
    /// Retourne `false` si CoreAudio a refusé la sélection — le périphérique a pu
    /// être débranché entre l'affichage du menu et le clic. L'appelant ne doit
    /// alors pas épingler ce périphérique.
    @discardableResult
    func select(_ device: AudioDevice) -> Bool {
        guard CoreAudioBridge.setDefaultDevice(device) else {
            // La liste est périmée puisqu'elle contient un périphérique injoignable.
            refreshDevices()
            return false
        }

        if isPinned {
            pin(device)
        }
        syncCurrentDevice()

        // AVAudioEngine reste attaché au périphérique qu'il avait au démarrage :
        // sans relance, le maintien porterait toujours sur l'ancien micro.
        keepAlive?.restartIfActive()
        return true
    }

    /// Sélectionne un périphérique et l'épingle, en une seule action.
    ///
    /// L'épinglage n'a lieu que si la sélection a réussi : épingler un
    /// périphérique injoignable enregistrerait le volume d'un autre.
    func selectAndPin(_ device: AudioDevice) {
        guard select(device) else { return }
        pin(device)
    }

    /// Épingle un périphérique : il sera restauré à chaque bascule de macOS.
    func pin(_ device: AudioDevice) {
        pinnedUID = device.uid
        preferences.setPinnedUID(device.uid, for: scope)
        preferences.setPinnedVolume(CoreAudioBridge.volume(of: device) ?? volume, for: scope)
        recentRestorations.removeAll()
        log.info("Périphérique épinglé : « \(device.name) »")
    }

    /// Lève l'épinglage. Le périphérique courant reste sélectionné.
    func unpin() {
        pinnedUID = nil
        preferences.setPinnedUID(nil, for: scope)
        recentRestorations.removeAll()
        log.info("Épinglage levé")
    }

    /// Bascule l'épinglage sur le périphérique courant.
    func togglePin() {
        if isPinned {
            unpin()
        } else if let device = currentDevice {
            pin(device)
        }
    }

    // MARK: - Reprise en main

    /// Restaure le périphérique épinglé s'il n'est plus le défaut du système.
    ///
    /// Restaure aussi son volume : c'est l'autre moitié du problème, macOS mémorisant
    /// un volume distinct par périphérique et pouvant revenir sur une valeur basse.
    private func enforcePinIfNeeded() {
        guard let pinnedUID else { return }

        if let suspendedUntil {
            guard Date() >= suspendedUntil else { return }
            self.suspendedUntil = nil
            recentRestorations.removeAll()
        }

        guard let target = devices.first(where: { $0.uid == pinnedUID }) else {
            // Le périphérique épinglé est absent : on ne force rien, on garde
            // l'épinglage en mémoire pour le rebranchement.
            return
        }

        let currentID = CoreAudioBridge.defaultDeviceID(scope: scope)
        let deviceIsCorrect = currentID == target.id
        let restoredVolume = preferences.pinnedDeviceVolume(for: scope)
        let volumeIsCorrect = restoredVolume.map { expected in
            guard let actual = CoreAudioBridge.volume(of: target) else { return true }
            return abs(actual - expected) < 0.01
        } ?? true

        guard !deviceIsCorrect || !volumeIsCorrect else { return }

        // Le quota ne s'applique qu'aux bascules de périphérique : réécrire un
        // volume est sans risque de boucle une fois la valeur appliquée mémorisée.
        guard deviceIsCorrect || allowRestoration() else {
            // L'épinglage est conservé : seule la reprise en main est mise en pause.
            suspendedUntil = Date().addingTimeInterval(restorationWindow)
            log.error("Trop de reprises en main rapprochées, reprise suspendue \(self.restorationWindow, format: .fixed(precision: 0)) s")
            return
        }

        if !deviceIsCorrect {
            log.info("Reprise en main : retour vers « \(target.name) »")
            CoreAudioBridge.setDefaultDevice(target)
        }

        if let restoredVolume, !volumeIsCorrect {
            CoreAudioBridge.setVolume(restoredVolume, on: target)

            // Mémoriser la valeur réellement appliquée, et non celle demandée :
            // certains périphériques quantifient leur gain (0,42 demandé, 0,375
            // obtenu). Sans cela la comparaison ne converge jamais, chaque
            // notification réécrit le volume et finit par épuiser le quota.
            if let applied = CoreAudioBridge.volume(of: target) {
                preferences.setPinnedVolume(applied, for: scope)
            }
        }

        lastRestoration = Date()
        syncCurrentDevice()
    }

    /// Autorise une reprise en main si le quota de la fenêtre glissante le permet.
    private func allowRestoration() -> Bool {
        let now = Date()
        recentRestorations.removeAll { now.timeIntervalSince($0) > restorationWindow }

        guard recentRestorations.count < maxRestorationsPerWindow else { return false }
        recentRestorations.append(now)
        return true
    }
}

extension AudioDeviceController {
    /// Un contrôleur d'entrée micro. Raccourci lisible, le scope étant implicite.
    static func microphone(preferences: Preferences = .shared) -> AudioDeviceController {
        AudioDeviceController(scope: .input, preferences: preferences)
    }
}
