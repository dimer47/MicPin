import SwiftUI

/// Le panneau déroulant de la barre des menus.
///
/// Présenté dans un `NSPopover` en vue SwiftUI, et non un menu natif : un menu ne
/// peut pas héberger de curseur de volume ni les matériaux Liquid Glass.
///
/// Deux sections symétriques : l'entrée (micro) et la sortie (haut-parleurs). Chacune
/// est pilotée par son propre `AudioDeviceController`, la logique étant identique.
struct MenuContentView: View {
    let input: AudioDeviceController
    let output: AudioDeviceController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceSection(controller: input, title: "Entrée")

            Divider().opacity(0.4)

            DeviceSection(controller: output, title: "Sortie")

            Divider().opacity(0.4)
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Pied

    /// Rappelle où trouver les réglages.
    ///
    /// Les réglages sont au clic droit, suivant la convention macOS : clic gauche
    /// pour l'usage courant, clic droit pour la configuration. Sans cette mention,
    /// rien ne l'indiquerait — un menu contextuel est invisible tant qu'on ne l'a
    /// pas ouvert.
    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 9))
            Text("Clic droit sur l'icône : démarrage, mises à jour, quitter")
                .font(.system(size: 10))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Section d'un sens (entrée ou sortie)

/// Une section complète : en-tête, liste des périphériques, volume, et — pour
/// l'entrée seule — le maintien du micro éveillé.
private struct DeviceSection: View {
    @Bindable var controller: AudioDeviceController
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel
            header
            deviceList

            if let device = controller.currentDevice {
                VolumeSlider(device: device, volume: $controller.volume)
            }

            if let keepAlive = controller.keepAlive {
                KeepAliveToggle(keepAlive: keepAlive)
            }
        }
    }

    /// Étiquette discrète qui nomme le sens de la section.
    private var sectionLabel: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.5)
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(controller.isPinned ? Color.accentColor : .primary)
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.currentDevice?.name ?? emptyName)
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
                .help(controller.isPinned ? "Lever l'épinglage" : "Épingler ce périphérique")
            }
        }
    }

    /// Symbole de l'en-tête : l'épingle quand un périphérique est épinglé, sinon
    /// l'icône du sens (micro ou haut-parleur).
    private var headerSymbol: String {
        if controller.isPinned { return "pin.fill" }
        return controller.scope == .output ? "speaker.wave.2.fill" : "mic.fill"
    }

    private var emptyName: String {
        controller.scope == .output ? "Aucune sortie" : "Aucune entrée"
    }

    /// Ligne d'état sous le nom : elle explique ce que fait l'app à l'instant.
    private var statusLine: String {
        if controller.isPinnedDeviceMissing {
            return controller.scope == .output ? "Sortie épinglée débranchée" : "Micro épinglé débranché"
        }
        if controller.isPinned {
            return "Épinglé — restauration auto"
        }
        return "Suit les changements de macOS"
    }

    // MARK: - Liste des périphériques

    private var deviceList: some View {
        VStack(spacing: 2) {
            if controller.devices.isEmpty {
                Text(emptyListLabel)
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

    private var emptyListLabel: String {
        controller.scope == .output ? "Aucune sortie détectée" : "Aucun micro détecté"
    }
}

// MARK: - Maintien du micro éveillé

/// Interrupteur du maintien, placé dans le panneau et non dans les réglages :
/// c'est une action ponctuelle qu'on active avant un appel et qu'on coupe après,
/// pas une préférence qu'on pose une fois pour toutes.
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
                // Le voyant orange va rester allumé : le dire évite l'inquiétude
                // légitime de voir le micro « écouter » en continu.
                Text("Le voyant orange reste allumé. Aucun son n'est enregistré.")
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
                .help(isPinned ? "Lever l'épinglage" : "Épingler ce périphérique")
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
                Text(label)
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
                    Image(systemName: lowSymbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Slider(value: $volume, in: 0...1)
                        .controlSize(.small)

                    Image(systemName: highSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            } else {
                // Cas fréquent sur les périphériques USB et Bluetooth, dont le gain
                // est géré par le matériel : on l'explique plutôt que de griser sans mot.
                Text(unavailableLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isOutput: Bool { device.scope == .output }

    private var label: String { isOutput ? "Niveau de sortie" : "Niveau d'entrée" }
    private var lowSymbol: String { isOutput ? "speaker" : "mic" }
    private var highSymbol: String { isOutput ? "speaker.wave.2.fill" : "mic.fill" }

    private var unavailableLabel: String {
        isOutput
            ? "Cette sortie ne permet pas de régler son niveau depuis macOS."
            : "Ce micro ne permet pas de régler son niveau depuis macOS."
    }
}
