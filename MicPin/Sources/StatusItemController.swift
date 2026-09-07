import AppKit
import SwiftUI

/// Pilote l'élément de la barre des menus.
///
/// Remplace `MenuBarExtra`, qui ne sait pas distinguer clic gauche et clic droit :
/// aucune API SwiftUI n'expose le clic secondaire sur son label. Or la convention
/// macOS veut que le clic gauche donne l'usage courant et le clic droit la
/// configuration — c'est ce que font la plupart des utilitaires de barre.
///
/// - **Clic gauche** : le panneau des micros (choix, épinglage, volume).
/// - **Clic droit** (ou Contrôle-clic) : les réglages et la sortie.
@MainActor
final class StatusItemController: NSObject {

    private let controller: MicrophoneController
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    /// Observation de l'état, pour tenir l'icône à jour.
    private var iconRefreshTimer: Timer?

    init(controller: MicrophoneController) {
        self.controller = controller
        super.init()
    }

    // MARK: - Installation

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = MenuBarIcon.image(symbolName: symbolName)
        button.target = self
        button.action = #selector(handleClick)
        // Sans ce masque, seul le clic gauche déclenche l'action : le clic droit
        // serait purement ignoré.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView().environment(controller)
        )

        // L'icône reflète l'état d'épinglage ; un rafraîchissement périodique
        // suffit, l'état changeant rarement et jamais dans l'urgence.
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.refreshIcon() }
        }
    }

    func uninstall() {
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Icône

    private var symbolName: String {
        if controller.isPinnedDeviceMissing { return "mic.slash" }
        return controller.isPinned ? "mic.badge.plus" : "mic"
    }

    private func refreshIcon() {
        statusItem?.button?.image = MenuBarIcon.image(symbolName: symbolName)
    }

    // MARK: - Clics

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        // Contrôle-clic est l'équivalent historique du clic droit sur macOS :
        // le traiter aussi évite de laisser de côté les souris à un bouton.
        let isSecondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isSecondary {
            showSettingsMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        controller.refreshDevices()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        // Sans activation, le panneau s'ouvre derrière la fenêtre active et ne
        // reçoit pas les clics.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu de réglages

    private func showSettingsMenu() {
        guard let item = statusItem, let button = item.button else { return }

        let menu = NSMenu()
        menu.addItem(settingsItem(
            title: "Lancer au démarrage",
            isOn: Preferences.shared.launchesAtLogin,
            action: #selector(toggleLaunchAtLogin)
        ))
        menu.addItem(.separator())

        menu.addItem(settingsItem(
            title: "Rechercher les mises à jour",
            isOn: Preferences.shared.automaticUpdates,
            action: #selector(toggleAutomaticUpdates)
        ))
        let check = NSMenuItem(title: "Vérifier maintenant…",
                               action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "MicPin \(UpdateChecker.installedVersion)",
                               action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quitter MicPin",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Assigner `item.menu` de façon permanente détournerait aussi le clic
        // gauche : on le pose le temps du clic, puis on le retire.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    private func settingsItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = isOn ? .on : .off
        return entry
    }

    // MARK: - Actions du menu

    @objc private func toggleLaunchAtLogin() {
        let wanted = !Preferences.shared.launchesAtLogin
        guard Preferences.shared.setLaunchesAtLogin(wanted) else {
            presentAlert(
                title: "Lancement au démarrage impossible",
                message: "Placez MicPin dans le dossier Applications : macOS refuse "
                    + "d'enregistrer une application située ailleurs."
            )
            return
        }
    }

    @objc private func toggleAutomaticUpdates() {
        let wanted = !Preferences.shared.automaticUpdates
        Preferences.shared.automaticUpdates = wanted
        if wanted {
            UpdateChecker.shared.startMonitoring()
        } else {
            UpdateChecker.shared.stopMonitoring()
        }
    }

    @objc private func checkForUpdates() {
        Task { await UpdateChecker.shared.check(silently: false) }
    }

    @objc private func quit() {
        controller.keepAlive.deactivate()
        controller.stopObserving()
        NSApp.terminate(nil)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Fermer")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
