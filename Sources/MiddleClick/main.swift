import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Pas d'icône dans le Dock ni de barre de menu classique : uniquement l'icône
// dans la barre de menu (status bar).
app.setActivationPolicy(.accessory)

app.run()
