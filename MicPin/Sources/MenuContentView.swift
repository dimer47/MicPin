import SwiftUI

/// Le panneau déroulant de la barre des menus.
///
/// Présenté dans un `MenuBarExtra` en style `.window`, et non `.menu` : un menu
/// natif ne peut pas héberger de curseur de volume ni les matériaux Liquid Glass.
struct MenuContentView: View {
    @Environment(MicrophoneController.self) private var controller
    @State private var launchesAtLogin = Preferences.shared.launchesAtLogin
    @State private var launchAtLoginFailed = false
    @State private var automaticUpdates = Preferences.shared.automaticUpdates

    var body: some View {
        @Bindable var controller = controller

        VStack(alignment: .leading, spacing: 14) {
            header
            deviceList

            if let device = controller.currentDevice {
                Divider().opacity(0.4)
                VolumeSlider(device: device, volume: $controller.volume)
            }

            Divider().opacity(0.4)
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.isPinned ? "pin.fill" : "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(controller.isPinned ? Color.accentColor : .primary)
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.currentDevice?.name ?? "Aucune entrée")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if controller.currentDevice != nil {
                Button(action: controller.togglePin) {
                    Image(systemName: controller.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .help(controller.isPinned ? "Lever l'épinglage" : "Épingler ce micro")
            }
        }
    }

    private var keepAliveToggle: some View {
        KeepAliveToggle(keepAlive: controller.keepAlive)
    }

    /// Ligne d'état sous le nom du micro : elle explique ce que fait l'app à l'instant.
    private var statusLine: String {
        if controller.isPinnedDeviceMissing {
            return "Micro épinglé débranché"
        }
        if controller.isPinned {
            return "Épinglé — restauration auto"
        }
        return "Suit les changements de macOS"
    }

    // MARK: - Liste des micros

    private var deviceList: some View {
        VStack(spacing: 2) {
            if controller.devices.isEmpty {
                Text("Aucun micro détecté")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(controller.devices) { device in
                    DeviceRow(
                        device: device,
                        isSelected: device.id == controller.currentDeviceID,
                        isPinned: device.uid == controller.pinnedUID,
                        onSelect: { controller.select(device) },
                        onTogglePin: {
                            if device.uid == controller.pinnedUID {
                                controller.unpin()
                            } else {
                                controller.selectAndPin(device)
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Pied

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Lancer au démarrage", isOn: $launchesAtLogin)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: launchesAtLogin) { _, newValue in
                    let succeeded = Preferences.shared.setLaunchesAtLogin(newValue)
                    if !succeeded {
                        launchAtLoginFailed = true
                        launchesAtLogin = Preferences.shared.launchesAtLogin
                    }
                }

            if launchAtLoginFailed {
                Text("Impossible d'activer le lancement au démarrage. Placez MicPin dans le dossier Applications.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keepAliveToggle

            Toggle("Rechercher les mises à jour", isOn: $automaticUpdates)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: automaticUpdates) { _, newValue in
                    Preferences.shared.automaticUpdates = newValue
                    if newValue {
                        UpdateChecker.shared.startMonitoring()
                    } else {
                        UpdateChecker.shared.stopMonitoring()
                    }
                }

            HStack {
                Button("Vérifier maintenant") {
                    Task { await UpdateChecker.shared.check(silently: false) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Spacer()
                Button("Quitter") {
                    controller.stopObserving()
                    NSApplication.shared.terminate(nil)
                }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Maintien du micro éveillé

private struct KeepAliveToggle: View {
    let keepAlive: MicrophoneKeepAlive
    @State private var isOn = false
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Garder le micro éveillé", isOn: $isOn)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isWorking)
                .onChange(of: isOn) { _, newValue in
                    Task {
                        isWorking = true
                        if newValue {
                            await keepAlive.activate()
                            // L'activation peut échouer : refléter l'état réel.
                            isOn = keepAlive.isActive
                        } else {
                            keepAlive.deactivate()
                        }
                        isWorking = false
                    }
                }

            if let message = keepAlive.failureMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if keepAlive.isActive {
                // L'indicateur orange de macOS va rester allumé : le dire évite
                // l'inquiétude légitime de voir le micro « écouter » en continu.
                Text("Le voyant orange reste allumé tant que c'est actif. Aucun son n'est enregistré.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { isOn = keepAlive.isActive }
    }
}

// MARK: - Ligne de périphérique

private struct DeviceRow: View {
    let device: AudioDevice
    let isSelected: Bool
    let isPinned: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: device.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(device.name)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)

                Text(device.transportLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            // L'épingle reste visible quand elle est active, et n'apparaît au survol
            // que sur les autres lignes : la liste ne se couvre pas d'icônes.
            if isPinned || isHovered {
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Lever l'épinglage" : "Épingler ce micro")
            }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .glassEffect(
            isSelected ? .regular.tint(.accentColor.opacity(0.22)) : (isHovered ? .regular : .identity),
            in: .rect(cornerRadius: 9)
        )
        .contentShape(.rect(cornerRadius: 9))
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }
}

// MARK: - Curseur de volume

private struct VolumeSlider: View {
    let device: AudioDevice
    @Binding var volume: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Niveau d'entrée")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if device.hasVolumeControl {
                    Text("\(Int(volume * 100)) %")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if device.hasVolumeControl {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Slider(value: $volume, in: 0...1)
                        .controlSize(.small)

                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            } else {
                // Cas fréquent sur les micros USB et Bluetooth, dont le gain est
                // géré par le matériel : on l'explique plutôt que de griser sans mot.
                Text("Ce micro ne permet pas de régler son niveau depuis macOS.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
