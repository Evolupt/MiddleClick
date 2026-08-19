import Cocoa

enum MouseIcon {

    /// Dessine une icône "vue de dessus" d'une souris tracée (contour, pas
    /// remplie), avec 2 cercles pleins en haut symbolisant les 2 doigts qui
    /// appuient ensemble (pas de trait séparateur).
    ///
    /// - `enabled == true` : dessin en noir, mode "template" — le système
    ///   l'adapte automatiquement aux thèmes clair/sombre de la barre de
    ///   menu.
    /// - `enabled == false` : dessin en gris fixe (pas de mode "template",
    ///   pour rester visuellement grisé quel que soit le thème) avec une
    ///   croix superposée.
    static func make(size: NSSize, enabled: Bool = true) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let drawColor: NSColor = enabled ? .black : .gray

        // Proportions d'une vraie Magic Mouse (ratio largeur/longueur
        // ≈ 0.55), pas une forme trop trapue.
        let bodyHeight = size.height * 0.90
        let bodyWidth = bodyHeight * 0.55
        let bodyRect = NSRect(
            x: (size.width - bodyWidth) / 2,
            y: size.height * 0.05,
            width: bodyWidth,
            height: bodyHeight
        )

        // Contour de la souris (tracé, pas rempli).
        let body = NSBezierPath(
            roundedRect: bodyRect,
            xRadius: bodyRect.width * 0.5,
            yRadius: bodyRect.width * 0.42
        )
        body.lineWidth = 1.3
        drawColor.setStroke()
        body.stroke()

        // 2 cercles pleins = les 2 doigts qui appuient ensemble.
        let dotRadius = bodyRect.width * 0.16
        let dotY = bodyRect.maxY - bodyRect.height * 0.24
        let dotOffset = bodyRect.width * 0.22
        drawColor.setFill()
        for x in [bodyRect.midX - dotOffset, bodyRect.midX + dotOffset] {
            let dotRect = NSRect(
                x: x - dotRadius,
                y: dotY - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            NSBezierPath(ovalIn: dotRect).fill()
        }

        // Croix de désactivation, superposée à l'ensemble de l'icône.
        if !enabled {
            let inset = size.width * 0.08
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: inset, y: inset))
            cross.line(to: NSPoint(x: size.width - inset, y: size.height - inset))
            cross.move(to: NSPoint(x: size.width - inset, y: inset))
            cross.line(to: NSPoint(x: inset, y: size.height - inset))
            cross.lineWidth = 1.6
            NSColor.gray.setStroke()
            cross.stroke()
        }

        image.unlockFocus()
        return image
    }
}
