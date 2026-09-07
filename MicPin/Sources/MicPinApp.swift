import SwiftUI

@main
struct MicPinApp: App {
    @State private var controller = MicrophoneController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(controller)
            .onAppear { UpdateChecker.shared.startMonitoring() }
        } label: {
            // L'icône reflète l'état d'un coup d'œil : barrée quand le micro épinglé
            // est débranché, épingle quand le verrouillage est actif.
            //
            // Passe par `MenuBarIcon` plutôt que par `Image(systemName:)` : la marge
            // latérale doit être dessinée dans le bitmap, le label d'un
            // `MenuBarExtra` ignorant les modificateurs de disposition.
            Image(nsImage: MenuBarIcon.image(symbolName: menuBarSymbol))
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
