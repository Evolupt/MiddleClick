import Cocoa

/// Une seule vue plate pour tout l'item de menu : dessine à la fois le
/// libellé "MiddleClick" et le commutateur façon iOS. Pas de conteneur, pas
/// de sous-vues imbriquées — assignée directement à `NSMenuItem.view`.
///
/// `NSSwitch` a un rendu de son "track" (le fond) qui ne suit pas
/// correctement la couleur d'accentuation une fois hébergé dans la vue
/// personnalisée d'un item de `NSStatusItem` — même avec `contentTintColor`
/// forcé, il reste gris. C'est un contrôle scellé (pas de dessin
/// personnalisable de l'intérieur), donc on dessine nous-mêmes un
/// commutateur équivalent, pour un rendu fiable garanti.
final class ToggleSwitchView: NSView {

    var isOn: Bool = false {
        didSet { needsDisplay = true }
    }

    weak var target: AnyObject?
    var action: Selector?

    private let trackSize = NSSize(width: 54, height: 24)
    private let horizontalInset: CGFloat = 14
    private let label: String

    init(frame frameRect: NSRect, label: String) {
        self.label = label
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        self.label = ""
        super.init(coder: coder)
    }

    private var trackRect: NSRect {
        NSRect(
            x: bounds.width - horizontalInset - trackSize.width,
            y: (bounds.height - trackSize.height) / 2,
            width: trackSize.width,
            height: trackSize.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        // Libellé, aligné comme un item de menu standard. Poids semi-bold,
        // à la façon des titres des panneaux type Bluetooth/Wi-Fi de macOS.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = label.size(withAttributes: attributes)
        let textRect = NSRect(
            x: horizontalInset,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        label.draw(in: textRect, withAttributes: attributes)

        // Commutateur.
        let track = trackRect
        let trackPath = NSBezierPath(
            roundedRect: track,
            xRadius: track.height / 2,
            yRadius: track.height / 2
        )
        let trackColor: NSColor = isOn
            ? NSColor.controlAccentColor
            : NSColor.black.withAlphaComponent(0.18)
        trackColor.setFill()
        trackPath.fill()

        // Le curseur ("thumb") n'est pas un rond mais une pilule (rectangle
        // très arrondi), plus large que haute, avec une fine marge visible
        // tout autour — mesuré sur une vraie capture d'écran macOS (menu
        // Bluetooth) plutôt qu'estimé à l'œil.
        let inset: CGFloat = 2
        let thumbHeight = track.height - inset * 2
        let thumbWidth = thumbHeight * 1.6
        let thumbX = isOn ? track.maxX - thumbWidth - inset : track.minX + inset
        let thumbRect = NSRect(x: thumbX, y: track.minY + inset, width: thumbWidth, height: thumbHeight)
        let thumbPath = NSBezierPath(
            roundedRect: thumbRect,
            xRadius: thumbHeight / 2,
            yRadius: thumbHeight / 2
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        thumbPath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        // Toute la ligne est cliquable, pas seulement le commutateur —
        // comme un item de menu à coche standard.
        isOn.toggle()
        if let target = target, let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}
