import CoreAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "fr.iachi.MicPin", category: "CoreAudio")

/// Accès bas niveau à CoreAudio : énumération des entrées, lecture et écriture
/// du périphérique d'entrée par défaut et de son volume.
///
/// Toutes les méthodes sont statiques et sans état. Les erreurs CoreAudio sont
/// journalisées et converties en valeurs optionnelles ou en `Bool` : aucune ne
/// remonte sous forme d'exception, car il n'y a rien d'utile à faire d'un échec
/// de lecture de propriété au niveau appelant, sinon ignorer le périphérique.
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
    /// CoreAudio renvoie ici une référence détenue par l'appelant, d'où le
    /// `takeRetainedValue` : la chaîne est libérée avec la valeur Swift retournée.
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

    // MARK: - Énumération des entrées

    /// Retourne tous les périphériques possédant au moins un canal d'entrée.
    ///
    /// Les périphériques de sortie pure sont écartés en inspectant leur
    /// configuration de flux sur le scope input : un `AudioBufferList` vide, ou
    /// dont tous les buffers ont zéro canal, signale une absence d'entrée.
    static func inputDevices() -> [AudioDevice] {
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

        return ids.compactMap(describe(device:))
    }

    /// Construit la description d'un périphérique, ou `nil` s'il n'a pas d'entrée.
    private static func describe(device id: AudioObjectID) -> AudioDevice? {
        guard inputChannelCount(of: id) > 0 else { return nil }

        guard let uid = stringValue(of: id, address: address(kAudioDevicePropertyDeviceUID)) else {
            log.error("Périphérique \(id) sans UID, ignoré")
            return nil
        }

        let name = stringValue(of: id, address: address(kAudioObjectPropertyName)) ?? "Périphérique sans nom"
        let transport = value(of: id, address: address(kAudioDevicePropertyTransportType), default: UInt32(0)) ?? 0
        let channel = writableVolumeChannel(of: id)

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            transport: transport,
            hasVolumeControl: channel != nil,
            volumeChannel: channel ?? 0
        )
    }

    /// Nombre total de canaux d'entrée du périphérique.
    private static func inputChannelCount(of id: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
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

    // MARK: - Volume d'entrée

    /// Trouve le canal sur lequel le volume d'entrée est réglable, s'il y en a un.
    ///
    /// L'ordre de sondage n'est pas arbitraire : le canal maître (0) est testé en
    /// premier car l'écrire règle tous les canaux d'un coup. On ne se rabat sur les
    /// canaux individuels que s'il ne répond pas, ce qui est le cas de certaines
    /// interfaces multi-entrées.
    private static func writableVolumeChannel(of id: AudioObjectID) -> UInt32? {
        for channel in UInt32(0)...UInt32(2) {
            var addr = address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeInput,
                element: channel
            )
            guard AudioObjectHasProperty(id, &addr) else { continue }

            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { continue }

            return channel
        }
        return nil
    }

    /// Lit le volume d'entrée du périphérique, entre 0 et 1.
    static func inputVolume(of device: AudioDevice) -> Float? {
        guard device.hasVolumeControl else { return nil }
        return value(
            of: device.id,
            address: address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeInput,
                element: device.volumeChannel
            ),
            default: Float(0)
        )
    }

    /// Écrit le volume d'entrée du périphérique. La valeur est bornée à [0, 1].
    @discardableResult
    static func setInputVolume(_ volume: Float, on device: AudioDevice) -> Bool {
        guard device.hasVolumeControl else { return false }

        var addr = address(
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeInput,
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

    // MARK: - Périphérique d'entrée par défaut

    /// L'AudioObjectID de l'entrée par défaut du système.
    static func defaultInputDeviceID() -> AudioObjectID? {
        let id = value(
            of: AudioObjectID(kAudioObjectSystemObject),
            address: address(kAudioHardwarePropertyDefaultInputDevice),
            default: AudioObjectID(kAudioObjectUnknown)
        )
        guard let id, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// Définit le périphérique d'entrée par défaut du système.
    @discardableResult
    static func setDefaultInputDevice(_ device: AudioDevice) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = device.id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id
        )

        if status != noErr {
            log.error("Échec de la sélection de « \(device.name) » comme entrée par défaut : \(status)")
            return false
        }
        log.info("Entrée par défaut : « \(device.name) »")
        return true
    }

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
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async(execute: handler)
        }

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

    /// Observe les changements d'entrée par défaut — c'est ce signal qui déclenche
    /// la reprise en main quand macOS bascule vers un autre micro.
    static func observeDefaultInputDevice(handler: @escaping @Sendable () -> Void) -> Observation? {
        observe(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            handler: handler
        )
    }
}
