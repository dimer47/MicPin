import AppKit
import SwiftUI

/// Point d'entrée.
///
/// L'élément de barre est piloté par `StatusItemController` en AppKit, et non par
/// `MenuBarExtra` : ce dernier ne distingue pas le clic gauche du clic droit, or la
/// convention macOS place l'usage courant à gauche et la configuration à droite.
///
/// La scène SwiftUI reste vide : elle n'existe que pour satisfaire le protocole
/// `App`, toute l'interface passant par le contrôleur.
@main
struct MicPinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MicrophoneController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MicrophoneController()
        let statusItem = StatusItemController(controller: controller)
        statusItem.install()

        self.controller = controller
        self.statusItem = statusItem

        UpdateChecker.shared.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Libérer le flux d'entrée avant de partir : sans cela, le voyant orange
        // de micro peut rester allumé jusqu'à ce que macOS fasse le ménage.
        controller?.keepAlive.deactivate()
        controller?.stopObserving()
        statusItem?.uninstall()
    }
}
