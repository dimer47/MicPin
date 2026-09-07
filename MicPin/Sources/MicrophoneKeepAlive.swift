import AVFoundation
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.dimer47.MicPin", category: "KeepAlive")

/// Maintient un flux d'entrée ouvert pour empêcher le micro de se mettre en veille.
///
/// macOS ferme le flux audio dès que plus aucune application ne l'utilise. Le
/// périphérique s'endort, et la reprise coûte une latence — nettement perceptible
/// en Bluetooth, où le casque doit renégocier son profil : le début d'une phrase
/// est parfois avalé.
///
/// Garder un flux ouvert supprime ce délai, mais a un coût qui interdit de
/// l'activer par défaut :
///
/// - **L'indicateur orange de micro reste allumé** tant que le maintien est actif.
///   macOS l'affiche dès qu'un flux d'entrée existe ; c'est un indicateur de
///   confidentialité qu'aucune application ne peut désactiver, et c'est très bien
///   ainsi.
/// - **La radio Bluetooth ne dort plus**, ce qui consomme des deux côtés.
/// - **L'autorisation micro devient nécessaire**, alors que lister et changer les
///   périphériques s'en passe.
///
/// L'interrupteur est donc manuel et coupé par défaut : on l'allume avant une
/// visioconférence, on l'éteint après.
///
/// Aucun son n'est enregistré. Le flux est lu puis jeté : le `tap` reçoit des
/// tampons et n'en fait rien, ce qui suffit à garder le périphérique éveillé.
@MainActor
@Observable
final class MicrophoneKeepAlive {

    /// `true` quand un flux est effectivement ouvert.
    private(set) var isActive = false

    /// Message d'erreur à afficher, quand l'activation a échoué.
    private(set) var failureMessage: String?

    private var engine: AVAudioEngine?

    /// État de l'autorisation micro, sans la demander.
    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Activation

    /// Ouvre un flux d'entrée, en demandant l'autorisation si nécessaire.
    func activate() async {
        failureMessage = nil

        guard await ensureAuthorization() else {
            failureMessage = "MicPin a besoin de l'accès au micro. Autorisez-le dans "
                + "Réglages Système → Confidentialité et sécurité → Microphone."
            log.error("Autorisation micro refusée")
            return
        }

        start()
    }

    private func ensureAuthorization() async -> Bool {
        switch authorizationStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func start() {
        stop()

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Le format doit être celui du périphérique : en imposer un autre fait
        // échouer l'installation du tap sur certaines interfaces.
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            failureMessage = "Le micro courant n'expose pas de format d'entrée exploitable."
            log.error("Format d'entrée invalide, maintien impossible")
            return
        }

        // Les tampons reçus ne sont pas conservés : seul le fait de lire le flux
        // compte, il maintient le périphérique éveillé.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }

        do {
            try engine.start()
            self.engine = engine
            isActive = true
            log.info("Maintien actif (\(format.sampleRate, format: .fixed(precision: 0)) Hz)")
        } catch {
            input.removeTap(onBus: 0)
            failureMessage = error.localizedDescription
            log.error("Démarrage impossible : \(error.localizedDescription)")
        }
    }

    /// Ferme le flux et laisse le micro se rendormir.
    func deactivate() {
        stop()
        failureMessage = nil
        log.info("Maintien désactivé")
    }

    private func stop() {
        guard let engine else {
            isActive = false
            return
        }

        // Retirer le tap avant d'arrêter : l'ordre inverse laisse parfois le
        // moteur dans un état d'où il refuse de redémarrer.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isActive = false
    }

    /// Rouvre le flux sur le périphérique courant.
    ///
    /// `AVAudioEngine` reste attaché au périphérique qu'il avait au démarrage :
    /// après un changement de micro, il faut le relancer pour que le maintien
    /// porte sur le nouveau.
    func restartIfActive() {
        guard isActive else { return }
        log.info("Reprise du maintien sur le nouveau périphérique")
        start()
    }
}
