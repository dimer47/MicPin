import CoreAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "com.dimer47.MicPin", category: "CoreAudio")

/// Accès bas niveau à CoreAudio : énumération des périphériques, lecture et
/// écriture du périphérique par défaut et de son volume, en entrée comme en sortie.
///
/// Toutes les méthodes sont statiques et sans état, et paramétrées par `AudioScope` :
/// la même logique sert l'entrée (micro) et la sortie (haut-parleurs). Les erreurs
/// CoreAudio sont journalisées et converties en valeurs optionnelles ou en `Bool` :
/// aucune ne remonte sous forme d'exception, car il n'y a rien d'utile à faire d'un
/// échec de lecture de propriété au niveau appelant, sinon ignorer le périphérique.
enum CoreAudioBridge {

    // MARK: - Adresses de propriétés

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: - Lecture générique

    /// Lit une propriété de taille fixe sur un objet audio.
    private static func value<T>(
        of object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        default fallback: T
    ) -> T? {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return result
    }

    /// Lit une propriété de type CFString (nom, UID) et la convertit en `String`.
    ///
    /// CoreAudio écrit ici une référence dont l'appelant devient propriétaire ; le
    /// pont Swift-CoreFoundation s'en charge et libère la chaîne avec la valeur
    /// retournée.
    private static func stringValue(
        of object: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> String? {
        var addr = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var raw: CFString? = nil
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else { return nil }
        return raw as String
    }

    // MARK: - Énumération des périphériques

    /// Retourne tous les périphériques possédant au moins un canal dans le sens demandé.
    ///
    /// Les périphériques du sens opposé sont écartés en inspectant la configuration
    /// de flux sur le scope correspondant : un `AudioBufferList` vide, ou dont tous
    /// les buffers ont zéro canal, signale une absence de canal dans ce sens. Un
    /// micro pur n'apparaît donc pas en sortie, et inversement.
    static func devices(scope: AudioScope) -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            log.error("Impossible de lire la taille de la liste des périphériques")
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            log.error("Impossible de lire la liste des périphériques")
            return []
        }

        return ids.compactMap { describe(device: $0, scope: scope) }
    }

    /// Les périphériques d'entrée. Raccourci de lecture pour `devices(scope: .input)`.
    static func inputDevices() -> [AudioDevice] { devices(scope: .input) }

    /// Les périphériques de sortie. Raccourci de lecture pour `devices(scope: .output)`.
    static func outputDevices() -> [AudioDevice] { devices(scope: .output) }

    /// Périphériques agrégés créés par CoreAudio pour son usage interne.
    ///
    /// Ouvrir un flux d'entrée fait apparaître un « CADefaultDeviceAggregate »
    /// dans la liste — CoreAudio s'en sert pour router l'audio, et il persiste un
    /// moment après la fermeture. Ce n'est pas un micro : le proposer au choix de
    /// l'utilisateur n'aurait aucun sens, et l'épingler le laisserait pointer vers
    /// un périphérique que le système supprimera.
    private static func isSystemAggregate(uid: String, name: String) -> Bool {
        uid.hasPrefix("~:AMS2_Aggregate") || uid.contains("CADefaultDeviceAggregate")
            || name.hasPrefix("CADefaultDeviceAggregate")
    }

    /// Construit la description d'un périphérique, ou `nil` s'il n'a pas de canal
    /// dans le sens demandé.
    private static func describe(device id: AudioObjectID, scope: AudioScope) -> AudioDevice? {
        guard channelCount(of: id, scope: scope) > 0 else { return nil }

        guard let uid = stringValue(of: id, address: address(kAudioDevicePropertyDeviceUID)) else {
            log.error("Périphérique \(id) sans UID, ignoré")
            return nil
        }

        let name = stringValue(of: id, address: address(kAudioObjectPropertyName)) ?? "Périphérique sans nom"

        guard !isSystemAggregate(uid: uid, name: name) else { return nil }

        let transport = value(of: id, address: address(kAudioDevicePropertyTransportType), default: UInt32(0)) ?? 0
        let channel = writableVolumeChannel(of: id, scope: scope)

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            transport: transport,
            scope: scope,
            hasVolumeControl: channel != nil,
            volumeChannel: channel ?? 0
        )
    }

    /// Nombre total de canaux du périphérique dans le sens demandé.
    private static func channelCount(of id: AudioObjectID, scope: AudioScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope.coreAudio)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        // AudioBufferList est de taille variable : on alloue la taille annoncée par
        // CoreAudio plutôt que le MemoryLayout du type, qui ne couvre qu'un buffer.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Volume

    /// Trouve le canal sur lequel le volume est réglable dans ce sens, s'il y en a un.
    ///
    /// L'ordre de sondage n'est pas arbitraire : le canal maître (0) est testé en
    /// premier car l'écrire règle tous les canaux d'un coup. On ne se rabat sur les
    /// canaux individuels que s'il ne répond pas, ce qui est le cas de certaines
    /// interfaces multi-canaux.
    private static func writableVolumeChannel(of id: AudioObjectID, scope: AudioScope) -> UInt32? {
        for channel in UInt32(0)...UInt32(2) {
            var addr = address(
                kAudioDevicePropertyVolumeScalar,
                scope: scope.coreAudio,
                element: channel
            )
            guard AudioObjectHasProperty(id, &addr) else { continue }

            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { continue }

            return channel
        }
        return nil
    }

    /// Lit le volume du périphérique dans son sens, entre 0 et 1.
    static func volume(of device: AudioDevice) -> Float? {
        guard device.hasVolumeControl else { return nil }
        return value(
            of: device.id,
            address: address(
                kAudioDevicePropertyVolumeScalar,
                scope: device.scope.coreAudio,
                element: device.volumeChannel
            ),
            default: Float(0)
        )
    }

    /// Écrit le volume du périphérique dans son sens. La valeur est bornée à [0, 1].
    @discardableResult
    static func setVolume(_ volume: Float, on device: AudioDevice) -> Bool {
        guard device.hasVolumeControl else { return false }

        var addr = address(
            kAudioDevicePropertyVolumeScalar,
            scope: device.scope.coreAudio,
            element: device.volumeChannel
        )
        var clamped = min(max(volume, 0), 1)
        let size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectSetPropertyData(device.id, &addr, 0, nil, size, &clamped)

        if status != noErr {
            log.error("Échec du réglage du volume sur « \(device.name) » : \(status)")
            return false
        }
        return true
    }

    // Noms historiques conservés pour l'entrée, où ils se lisent mieux à l'appel.
    static func inputVolume(of device: AudioDevice) -> Float? { volume(of: device) }

    @discardableResult
    static func setInputVolume(_ volume: Float, on device: AudioDevice) -> Bool {
        setVolume(volume, on: device)
    }

    // MARK: - Périphérique par défaut

    /// L'AudioObjectID du périphérique par défaut du système dans ce sens.
    static func defaultDeviceID(scope: AudioScope) -> AudioObjectID? {
        let id = value(
            of: AudioObjectID(kAudioObjectSystemObject),
            address: address(scope.defaultDeviceSelector),
            default: AudioObjectID(kAudioObjectUnknown)
        )
        guard let id, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    static func defaultInputDeviceID() -> AudioObjectID? { defaultDeviceID(scope: .input) }
    static func defaultOutputDeviceID() -> AudioObjectID? { defaultDeviceID(scope: .output) }

    /// Définit le périphérique par défaut du système dans le sens du périphérique.
    ///
    /// Le succès est vérifié par relecture, et non d'après le code de retour :
    /// CoreAudio répond `noErr` à l'écriture d'un AudioObjectID inexistant tout
    /// en laissant le réglage inchangé. S'y fier ferait croire à une sélection
    /// réussie sur un périphérique débranché entre-temps.
    @discardableResult
    static func setDefaultDevice(_ device: AudioDevice) -> Bool {
        var addr = address(device.scope.defaultDeviceSelector)
        var id = device.id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id
        )

        guard status == noErr else {
            log.error("Échec de la sélection de « \(device.name) » : \(status)")
            return false
        }

        guard defaultDeviceID(scope: device.scope) == device.id else {
            log.error("« \(device.name) » n'a pas été retenu comme périphérique par défaut")
            return false
        }

        log.info("Périphérique par défaut : « \(device.name) »")
        return true
    }

    @discardableResult
    static func setDefaultInputDevice(_ device: AudioDevice) -> Bool { setDefaultDevice(device) }

    // MARK: - Observation

    /// Jeton d'abonnement à une propriété CoreAudio.
    ///
    /// Le désabonnement se fait explicitement via `cancel()` plutôt que dans un
    /// `deinit` : `AudioObjectRemovePropertyListenerBlock` doit recevoir exactement
    /// le même bloc que celui passé à l'inscription, on le conserve donc ici.
    final class Observation {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        private let queue: DispatchQueue
        private var isActive = true

        init(
            object: AudioObjectID,
            address: AudioObjectPropertyAddress,
            queue: DispatchQueue,
            block: @escaping AudioObjectPropertyListenerBlock
        ) {
            self.object = object
            self.address = address
            self.queue = queue
            self.block = block
        }

        func cancel() {
            guard isActive else { return }
            isActive = false
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    /// Observe un changement de propriété et appelle `handler` sur la file principale.
    private static func observe(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        handler: @escaping @Sendable () -> Void
    ) -> Observation? {
        var addr = address(selector)
        // Pas de `DispatchQueue.main.async` ici : la file passée à
        // `AudioObjectAddPropertyListenerBlock` livre déjà le bloc sur la file
        // principale, un second saut ne ferait qu'ajouter de la latence.
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }

        let status = AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block)
        guard status == noErr else {
            log.error("Échec de l'observation de la propriété : \(status)")
            return nil
        }

        return Observation(object: object, address: addr, queue: DispatchQueue.main, block: block)
    }

    /// Observe l'apparition et la disparition de périphériques.
    static func observeDeviceList(handler: @escaping @Sendable () -> Void) -> Observation? {
        observe(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            handler: handler
        )
    }

    /// Observe les changements de périphérique par défaut dans ce sens — c'est ce
    /// signal qui déclenche la reprise en main quand macOS bascule vers un autre
    /// périphérique.
    static func observeDefaultDevice(scope: AudioScope, handler: @escaping @Sendable () -> Void) -> Observation? {
        observe(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: scope.defaultDeviceSelector,
            handler: handler
        )
    }

    static func observeDefaultInputDevice(handler: @escaping @Sendable () -> Void) -> Observation? {
        observeDefaultDevice(scope: .input, handler: handler)
    }
}
