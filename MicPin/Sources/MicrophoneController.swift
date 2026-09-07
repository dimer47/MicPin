import CoreAudio
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "fr.iachi.MicPin", category: "Controller")

/// État de l'application : liste des entrées, entrée courante, volume, épinglage.
///
/// Le mode épinglé est la raison d'être de l'app : macOS promeut spontanément tout
/// nouveau périphérique en entrée par défaut (branchement d'écouteurs, appairage
/// Bluetooth, réveil de veille), et chaque périphérique conserve son propre volume
/// d'entrée. Quand un micro est épinglé, ce contrôleur observe les bascules et
/// restaure aussitôt le périphérique voulu *et* son volume.
@MainActor
@Observable
final class MicrophoneController {

    // MARK: - État publié

    private(set) var devices: [AudioDevice] = []
    private(set) var currentDeviceID: AudioObjectID?

    /// Volume d'entrée du périphérique courant, entre 0 et 1.
    ///
    /// L'écriture est propagée à CoreAudio, et mémorisée pour le périphérique
    /// épinglé afin d'être restaurée lors d'une reprise en main.
    var volume: Float = 0 {
        didSet {
            guard !isSyncingVolume, let device = currentDevice else { return }
            CoreAudioBridge.setInputVolume(volume, on: device)
            if device.uid == pinnedUID {
                preferences.pinnedVolume = volume
            }
        }
    }

    /// UID du périphérique épinglé, ou `nil` si l'épinglage est désactivé.
    private(set) var pinnedUID: String?

    /// Dernière reprise en main effectuée, pour l'afficher dans l'interface.
    private(set) var lastRestoration: Date?

    // MARK: - Interne

    private let preferences: Preferences
    private var deviceListObservation: CoreAudioBridge.Observation?
    private var defaultInputObservation: CoreAudioBridge.Observation?

    /// Empêche l'écriture CoreAudio quand `volume` est mis à jour depuis le matériel.
    private var isSyncingVolume = false

    /// Garde-fou contre une boucle de restauration.
    ///
    /// Si un périphérique refuse de rester sélectionné, réécrire indéfiniment
    /// l'entrée par défaut ferait tourner l'app en boucle avec CoreAudio. On limite
    /// donc les tentatives rapprochées, et on abandonne l'épinglage au-delà.
    private var recentRestorations: [Date] = []
    private let restorationWindow: TimeInterval = 10
    private let maxRestorationsPerWindow = 5

    var currentDevice: AudioDevice? {
        guard let currentDeviceID else { return nil }
        return devices.first { $0.id == currentDeviceID }
    }

    var pinnedDevice: AudioDevice? {
        guard let pinnedUID else { return nil }
        return devices.first { $0.uid == pinnedUID }
    }

    var isPinned: Bool { pinnedUID != nil }

    /// `true` quand un micro est épinglé mais absent — débranché, par exemple.
    /// L'épinglage reste mémorisé : il reprendra effet au rebranchement.
    var isPinnedDeviceMissing: Bool { isPinned && pinnedDevice == nil }

    // MARK: - Cycle de vie

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
        self.pinnedUID = preferences.pinnedUID

        refreshDevices()
        startObserving()

        // Au lancement, macOS a pu basculer d'entrée pendant que l'app ne tournait
        // pas : on réapplique immédiatement l'épinglage.
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
        defaultInputObservation?.cancel()
        defaultInputObservation = nil
    }

    private func startObserving() {
        deviceListObservation = CoreAudioBridge.observeDeviceList { [weak self] in
            Task { @MainActor in
                self?.handleDeviceListChange()
            }
        }

        defaultInputObservation = CoreAudioBridge.observeDefaultInputDevice { [weak self] in
            Task { @MainActor in
                self?.handleDefaultInputChange()
            }
        }
    }

    // MARK: - Réactions aux évènements CoreAudio

    private func handleDeviceListChange() {
        refreshDevices()
        // Un périphérique vient d'apparaître ou de disparaître : c'est exactement
        // le moment où macOS rebascule l'entrée par défaut.
        enforcePinIfNeeded()
    }

    private func handleDefaultInputChange() {
        syncCurrentDevice()
        enforcePinIfNeeded()
    }

    // MARK: - Rafraîchissement

    func refreshDevices() {
        devices = CoreAudioBridge.inputDevices().sorted { lhs, rhs in
            // Le micro intégré remonte en tête : c'est celui qu'on veut réépingler
            // le plus souvent, il doit être atteignable sans parcourir la liste.
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        syncCurrentDevice()
    }

    /// Recharge l'entrée courante et son volume depuis CoreAudio.
    private func syncCurrentDevice() {
        currentDeviceID = CoreAudioBridge.defaultInputDeviceID()

        guard let device = currentDevice else { return }
        isSyncingVolume = true
        volume = CoreAudioBridge.inputVolume(of: device) ?? 0
        isSyncingVolume = false
    }

    // MARK: - Actions

    /// Sélectionne un périphérique comme entrée par défaut.
    ///
    /// Si un épinglage est actif, choisir un autre micro déplace l'épinglage :
    /// sans cela, la sélection serait annulée dans la seconde par la reprise en main.
    func select(_ device: AudioDevice) {
        guard CoreAudioBridge.setDefaultInputDevice(device) else { return }

        if isPinned {
            pin(device)
        }
        syncCurrentDevice()
    }

    /// Épingle un périphérique : il sera restauré à chaque bascule de macOS.
    func pin(_ device: AudioDevice) {
        pinnedUID = device.uid
        preferences.pinnedUID = device.uid
        preferences.pinnedVolume = CoreAudioBridge.inputVolume(of: device) ?? volume
        recentRestorations.removeAll()
        log.info("Micro épinglé : « \(device.name) »")
    }

    /// Lève l'épinglage. Le périphérique courant reste sélectionné.
    func unpin() {
        pinnedUID = nil
        preferences.pinnedUID = nil
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

    /// Restaure le micro épinglé s'il n'est plus l'entrée par défaut.
    ///
    /// Restaure aussi son volume : c'est l'autre moitié du problème, macOS mémorisant
    /// un volume distinct par périphérique et pouvant revenir sur une valeur basse.
    private func enforcePinIfNeeded() {
        guard let pinnedUID else { return }

        guard let target = devices.first(where: { $0.uid == pinnedUID }) else {
            // Le micro épinglé est absent : on ne force rien, on garde l'épinglage
            // en mémoire pour le rebranchement.
            return
        }

        let currentID = CoreAudioBridge.defaultInputDeviceID()
        let deviceIsCorrect = currentID == target.id
        let restoredVolume = preferences.pinnedVolume
        let volumeIsCorrect = restoredVolume.map { expected in
            guard let actual = CoreAudioBridge.inputVolume(of: target) else { return true }
            return abs(actual - expected) < 0.01
        } ?? true

        guard !deviceIsCorrect || !volumeIsCorrect else { return }

        guard allowRestoration() else {
            log.error("Trop de reprises en main rapprochées, épinglage suspendu")
            unpin()
            return
        }

        if !deviceIsCorrect {
            log.info("Reprise en main : retour vers « \(target.name) »")
            CoreAudioBridge.setDefaultInputDevice(target)
        }

        if let restoredVolume, !volumeIsCorrect {
            CoreAudioBridge.setInputVolume(restoredVolume, on: target)
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
