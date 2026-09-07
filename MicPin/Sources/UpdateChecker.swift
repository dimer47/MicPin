import AppKit
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.dimer47.MicPin", category: "Update")

/// Une version publiée, disponible au téléchargement.
struct AvailableUpdate: Equatable {
    let version: String
    let notes: String
    let downloadURL: URL
    let size: Int
    let publishedAt: Date
}

/// Recherche et installe les mises à jour publiées sur GitHub.
///
/// Les versions sont lues depuis l'API publique de GitHub. Le dépôt étant public,
/// aucune authentification n'est nécessaire — et il ne faut surtout pas en
/// embarquer : un jeton inclus dans une app distribuée est lisible par quiconque
/// ouvre le binaire.
///
/// Rien n'est jamais installé sans accord de l'utilisateur.
@MainActor
@Observable
final class UpdateChecker {

    static let shared = UpdateChecker()

    /// Dépôt public consulté. Il n'expose que des releases.
    private static let repository = "dimer47/MicPin"

    private static let apiURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!

    /// Identifiant d'équipe attendu dans la signature du disque téléchargé.
    ///
    /// La notarisation prouve qu'Apple n'a pas trouvé de logiciel malveillant,
    /// pas que le disque vient de nous : sans cette vérification, un disque
    /// notarisé par quelqu'un d'autre serait accepté.
    private static let expectedTeamID = "5D6QHL72QC"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var availableUpdate: AvailableUpdate?

    private var timer: Timer?

    private init() {}

    // MARK: - Version installée

    /// Version de l'app en cours d'exécution.
    nonisolated static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Surveillance périodique

    /// Vérifie maintenant, puis une fois par jour.
    ///
    /// L'app vit dans la barre des menus et reste lancée des semaines : une
    /// vérification au seul démarrage laisserait passer les versions.
    func startMonitoring() {
        guard Preferences.shared.automaticUpdates else { return }

        Task { await check(silently: true) }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in
                await UpdateChecker.shared.check(silently: true)
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Vérification

    /// Interroge GitHub et compare à la version installée.
    ///
    /// - Parameter silently: en mode silencieux, rien ne s'affiche si l'app est à
    ///   jour ou si le réseau est indisponible. Une vérification demandée par
    ///   l'utilisateur, elle, répond toujours.
    func check(silently: Bool) async {
        state = .checking

        do {
            let update = try await fetchLatestRelease()

            guard Self.isNewer(update.version, than: Self.installedVersion) else {
                state = .upToDate
                log.info("À jour : \(Self.installedVersion)")
                if !silently { showUpToDate() }
                return
            }

            availableUpdate = update
            state = .available(update.version)
            log.info("Version \(update.version) disponible")

            if !silently || Preferences.shared.automaticUpdates {
                promptForInstall(update)
            }

        } catch {
            state = .failed(error.localizedDescription)
            log.error("Vérification impossible : \(error.localizedDescription)")
            if !silently { showFailure(error) }
        }
    }

    private func fetchLatestRelease() async throws -> AvailableUpdate {
        var request = URLRequest(url: Self.apiURL)
        request.timeoutInterval = 15
        // En-tête recommandé par GitHub : sans lui, l'API peut renvoyer une
        // représentation différente au gré de ses évolutions.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MicPin/\(Self.installedVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.unexpectedResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try Self.parseRelease(data)
    }

    /// Extrait la version publiée d'une réponse de l'API GitHub.
    ///
    /// Séparée de l'appel réseau pour être vérifiable sans réseau : c'est ce code
    /// qui décide de remplacer l'application sur la machine de l'utilisateur, il
    /// doit être couvert par des tests.
    nonisolated static func parseRelease(_ data: Data) throws -> AvailableUpdate {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let assets = object["assets"] as? [[String: Any]] else {
            throw UpdateError.unreadableResponse
        }

        guard let disk = assets.first(where: {
                  ($0["name"] as? String)?.hasSuffix(".dmg") == true
              }),
              let address = disk["browser_download_url"] as? String,
              let url = URL(string: address) else {
            throw UpdateError.noDiskImage
        }

        let formatter = ISO8601DateFormatter()
        let date = (object["published_at"] as? String).flatMap(formatter.date(from:)) ?? Date()

        return AvailableUpdate(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: (object["body"] as? String) ?? "",
            downloadURL: url,
            size: (disk["size"] as? Int) ?? 0,
            publishedAt: date
        )
    }

    // MARK: - Comparaison de versions

    /// Compare deux versions sémantiques, segment par segment.
    ///
    /// Une comparaison de chaînes placerait « 1.10.0 » avant « 1.9.0 », d'où ce
    /// découpage numérique.
    nonisolated static func isNewer(_ candidate: String, than reference: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = reference.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }

        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Installation

    /// Télécharge le disque, vérifie sa signature, puis remplace l'application.
    func install(_ update: AvailableUpdate) async {
        do {
            state = .downloading(0)
            let disk = try await download(update)

            state = .installing
            try verifySignature(of: disk)
            try replaceApplication(from: disk)

            // La permutation est programmée : quitter laisse le script agir.
            NSApp.terminate(nil)

        } catch {
            state = .failed(error.localizedDescription)
            log.error("Installation échouée : \(error.localizedDescription)")
            showFailure(error)
        }
    }

    private func download(_ update: AvailableUpdate) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: update.downloadURL)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        // Le fichier temporaire d'URLSession disparaît au retour de cette
        // fonction : il faut le déplacer dans notre propre dossier.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicPin-\(update.version).dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)

        log.info("Disque téléchargé : \(destination.lastPathComponent)")
        return destination
    }

    /// Refuse tout disque qui ne serait pas signé par notre identité.
    ///
    /// Sans cette vérification, une réponse détournée ferait installer n'importe
    /// quel binaire à la place de la mise à jour.
    private func verifySignature(of disk: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        // -vvv est indispensable : sans lui, spctl se contente d'un code de
        // retour, alors que nous voulons connaître l'origine exacte.
        process.arguments = [
            "-a", "-vvv", "-t", "open",
            "--context", "context:primary-signature",
            disk.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = String(data: data, encoding: .utf8) ?? ""

        // Le code de retour donne le verdict ; les mentions attendues confirment
        // que l'acceptation vient de notre identité et non d'une règle locale
        // plus permissive.
        guard process.terminationStatus == 0,
              message.contains("accepted"),
              message.contains("Notarized Developer ID"),
              message.contains(Self.expectedTeamID) else {
            log.error("Signature refusée (code \(process.terminationStatus))")
            throw UpdateError.invalidSignature
        }

        log.info("Signature et notarisation vérifiées")
    }

    private func replaceApplication(from disk: URL) throws {
        let mountPoint = try mount(disk)
        defer { unmount(mountPoint) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint.path)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.applicationNotFound
        }

        let source = mountPoint.appendingPathComponent(appName)
        let destination = Bundle.main.bundleURL

        // Une app ne peut pas se remplacer elle-même pendant qu'elle s'exécute :
        // la copie passe par un emplacement voisin, et un script détaché permute
        // les dossiers après notre sortie.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".MicPin-new.app")

        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)

        try scheduleSwap(new: staging, old: destination)
    }

    private func mount(_ disk: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", disk.path, "-nobrowse", "-readonly", "-plist"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let point = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed
        }

        return URL(fileURLWithPath: point)
    }

    private func unmount(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Prépare un script qui remplacera l'app après notre sortie, puis la relance.
    private func scheduleSwap(new: URL, old: URL) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("micpin-swap-\(UUID().uuidString).sh")

        let contents = """
        #!/bin/bash
        # Remplace l'application après la sortie du processus qui l'a lancé.
        set -e

        PID=$1
        NEW="$2"
        OLD="$3"

        # Attendre la fin effective de l'application, sans boucler indéfiniment.
        for _ in $(seq 1 100); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
        done

        rm -rf "$OLD"
        mv "$NEW" "$OLD"

        # Réenregistrer le bundle auprès de LaunchServices.
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$OLD" 2>/dev/null || true

        open "$OLD"
        rm -f "$0"
        """

        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            new.path,
            old.path
        ]
        try process.run()

        log.info("Permutation programmée")
    }

    // MARK: - Messages

    private func promptForInstall(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "MicPin \(update.version) est disponible"
        alert.informativeText = update.notes.isEmpty
            ? "Vous utilisez la version \(Self.installedVersion)."
            : update.notes
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Mettre à jour")
        alert.addButton(withTitle: "Plus tard")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await install(update) }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "MicPin est à jour"
        alert.informativeText = "Vous utilisez la version \(Self.installedVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Fermer")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Mise à jour impossible"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Fermer")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Erreurs

enum UpdateError: LocalizedError, Equatable {
    case unexpectedResponse(Int)
    case unreadableResponse
    case noDiskImage
    case downloadFailed
    case invalidSignature
    case mountFailed
    case applicationNotFound

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let code):
            return "GitHub a répondu avec le code \(code)."
        case .unreadableResponse:
            return "La réponse de GitHub n'a pas pu être interprétée."
        case .noDiskImage:
            return "Cette version ne contient pas de disque d'installation."
        case .downloadFailed:
            return "Le téléchargement a échoué."
        case .invalidSignature:
            return "Le disque téléchargé n'est pas signé par l'auteur de MicPin. L'installation est annulée."
        case .mountFailed:
            return "Le disque d'installation n'a pas pu être monté."
        case .applicationNotFound:
            return "Le disque ne contient pas l'application."
        }
    }
}
