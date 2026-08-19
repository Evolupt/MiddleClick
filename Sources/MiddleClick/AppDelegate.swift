import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var toggleSwitch: ToggleSwitchView?
    private var engine: MiddleClickEngine?

    /// État affiché/désiré par l'utilisateur. Distinct de `engine.isEnabled`
    /// pour pouvoir refléter le toggle dans le menu même avant que le
    /// moteur n'existe (permissions pas encore accordées).
    private var isEnabled = true {
        didSet { applyEnabledState() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        checkAccessibilityAndStart()
        observeSystemWake()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        let menu = NSMenu()
        menu.addItem(makeToggleMenuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu

        applyEnabledState()
    }

    /// Item de menu avec une vue personnalisée unique (sans conteneur ni
    /// sous-vues, voir ToggleSwitchView.swift) : libellé "MiddleClick" +
    /// commutateur façon iOS.
    private func makeToggleMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()

        let toggle = ToggleSwitchView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 26),
            label: "MiddleClick"
        )
        toggle.target = self
        toggle.action = #selector(switchToggled(_:))
        toggleSwitch = toggle

        menuItem.view = toggle
        return menuItem
    }

    /// Met à jour l'icône (grisée + croix si désactivé), le commutateur du
    /// menu et le moteur, à partir de `isEnabled`.
    private func applyEnabledState() {
        guard let button = statusItem?.button else { return }
        let icon = MouseIcon.make(size: NSSize(width: 18, height: 18), enabled: isEnabled)
        // Mode "template" uniquement quand actif : on veut que le gris de
        // l'état désactivé reste bien gris, pas réinterprété par le thème.
        icon.isTemplate = isEnabled
        button.image = icon

        toggleSwitch?.isOn = isEnabled

        engine?.isEnabled = isEnabled
    }

    @objc private func switchToggled(_ sender: ToggleSwitchView) {
        isEnabled = sender.isOn
    }

    /// Demande la permission Accessibilité si besoin, puis démarre le moteur
    /// dès qu'elle est accordée (on réessaie régulièrement).
    private func checkAccessibilityAndStart() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [promptKey: true]
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            debugLog("Accessibilité = accordée")
            startEngine()
        } else {
            debugLog("Accessibilité pas encore accordée, nouvelle tentative dans 1.5s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.checkAccessibilityAndStart()
            }
        }
    }

    private func startEngine() {
        guard engine == nil else { return }
        let engine = MiddleClickEngine()
        engine.isEnabled = isEnabled
        engine.start()
        self.engine = engine
    }

    /// À la mise en veille, la Magic Mouse (Bluetooth) se déconnecte ; au
    /// réveil elle se reconnecte avec une nouvelle référence système, ce qui
    /// invalide silencieusement l'ancienne inscription tactile — le moteur
    /// reste "actif" en apparence mais ne reçoit plus rien. On redémarre
    /// donc entièrement le moteur à chaque réveil, avec un court délai pour
    /// laisser le temps au Bluetooth de se reconnecter.
    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        debugLog("💤➡️🟢 réveil système détecté, redémarrage programmé")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, let engine = self.engine else { return }
            engine.restart()
            engine.isEnabled = self.isEnabled
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
