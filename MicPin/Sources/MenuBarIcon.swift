import AppKit

/// Fabrique l'image affichée dans la barre des menus.
///
/// L'espace latéral est dessiné *dans* le bitmap plutôt qu'appliqué en `padding`
/// SwiftUI : le label d'un `MenuBarExtra` ignore les modificateurs de disposition,
/// l'item conservant la largeur nue du symbole (17 pt mesurés, quel que soit le
/// padding demandé). Élargir l'image elle-même est le seul levier qui agit — la
/// même image avec 5 pt de marge de chaque côté produit un item de 28 pt.
enum MenuBarIcon {

    /// Marge horizontale de part et d'autre du symbole, en points.
    ///
    /// 5 pt place l'icône dans la fourchette des items système voisins, qui
    /// occupent 21 à 28 pt sur la barre.
    private static let horizontalPadding: CGFloat = 5

    /// Corps du symbole. 15 pt correspond au gabarit des icônes de barre macOS.
    private static let pointSize: CGFloat = 15

    /// Retourne le symbole nommé, entouré de sa marge, prêt pour la barre.
    ///
    /// L'image est marquée `isTemplate` : macOS la recolore alors lui-même selon
    /// le fond de la barre et le thème clair ou sombre.
    static func image(symbolName: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)

        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Micro")?
            .withSymbolConfiguration(configuration) else {
            // Symbole absent du système : on rend une image vide de la bonne
            // taille plutôt que de laisser un trou dans la barre.
            return NSImage(size: NSSize(width: pointSize + horizontalPadding * 2, height: pointSize))
        }

        let size = NSSize(
            width: symbol.size.width + horizontalPadding * 2,
            height: symbol.size.height
        )

        let padded = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(
                x: horizontalPadding,
                y: 0,
                width: symbol.size.width,
                height: symbol.size.height
            ))
            return true
        }
        padded.isTemplate = true
        return padded
    }
}
