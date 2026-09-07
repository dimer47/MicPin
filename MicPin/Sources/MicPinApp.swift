import SwiftUI

@main
struct MicPinApp: App {
    @State private var controller = MicrophoneController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(controller)
        } label: {
            // L'icône reflète l'état d'un coup d'œil : barrée quand le micro épinglé
            // est débranché, épingle quand le verrouillage est actif.
            Image(systemName: menuBarSymbol)
        }
        // Style fenêtre, et non menu : un menu natif n'accepte ni curseur ni
        // matériaux Liquid Glass.
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if controller.isPinnedDeviceMissing { return "mic.slash" }
        return controller.isPinned ? "mic.badge.plus" : "mic"
    }
}
