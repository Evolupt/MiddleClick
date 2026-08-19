import Cocoa
import ApplicationServices
import IOKit.hid

/// Fusionne un clic (et un glissé maintenu) gauche/droite en clic du bouton
/// du milieu, en s'appuyant sur `TouchGate` comme signal déclencheur plutôt
/// que sur une fenêtre de temps entre deux clics.
///
/// Principe :
/// - Le portillon tactile (2 doigts posés) ouvre/ferme une porte.
/// - Tant qu'un bouton gauche/droit réel est en train d'être pressé PENDANT
///   que le portillon est ouvert, on intercepte tout (down / dragged / up)
///   et on le retransforme en événements du bouton du milieu.
/// - Si le portillon s'ouvre alors qu'un clic simple est déjà en cours
///   (le firmware a déjà classé le clic avant que le 2e doigt soit détecté),
///   on "corrige à chaud" : faux relâchement du bouton simple, puis vrai
///   appui du bouton du milieu.
/// - Aucun délai artificiel : tout est transmis immédiatement, sauf pendant
///   une session fusionnée.
final class MiddleClickEngine {

    private static let syntheticMarker: Int64 = 0x4D43 // "MC"

    private let touchGate = TouchGate()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var realButtonDown: CGMouseButton?
    private var lastLocation: CGPoint = .zero
    private var middleActive = false

    /// Coupe/rétablit l'interception à chaud, sans démonter le tap ni
    /// perdre les autorisations déjà accordées. Si on désactive en pleine
    /// fusion (bouton du milieu déjà simulé en cours), on la referme
    /// proprement plutôt que de laisser le bouton "coincé" enfoncé.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            debugLog(isEnabled ? "🟢 activé" : "⚪️ désactivé")
            if !isEnabled && middleActive {
                endMiddle(at: lastLocation)
            }
        }
    }

    func start() {
        touchGate.onGateOpen = { [weak self] in self?.gateDidOpen() }
        touchGate.onGateClose = { [weak self] in self?.gateDidClose() }
        touchGate.start()
        startEventTap()
    }

    func stop() {
        touchGate.stop()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        realButtonDown = nil
        middleActive = false
    }

    /// Démonte puis recrée entièrement le tap et le portillon tactile.
    /// Nécessaire après un réveil système : la Magic Mouse (Bluetooth) se
    /// déconnecte/reconnecte à la mise en veille, ce qui invalide la
    /// référence au périphérique tactile enregistrée dans `TouchGate` —
    /// impossible de la "réparer" en place, il faut tout recréer.
    func restart() {
        debugLog("🔁 redémarrage du moteur (tap + portillon tactile)")
        stop()
        start()
    }

    // MARK: - CGEventTap

    private func startEventTap() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            debugLog("Surveillance des saisies (Input Monitoring) = accordée")
        case kIOHIDAccessTypeDenied:
            debugLog("⚠️ Surveillance des saisies REFUSÉE. Réglages Système > Confidentialité et sécurité > Surveillance des saisies.")
        default:
            debugLog("Surveillance des saisies = statut inconnu (\(access.rawValue))")
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
                let engine = Unmanaged<MiddleClickEngine>.fromOpaque(userInfo).takeUnretainedValue()
                return engine.handle(type: type, event: event)
            },
            userInfo: selfPointer
        ) else {
            debugLog("⚠️ impossible de créer l'event tap (Accessibilité manquante ?).")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugLog("event tap créé et activé.")
    }

    // MARK: - Traitement des événements réels

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passRetained(event)
        }

        guard isEnabled else {
            return Unmanaged.passRetained(event)
        }

        lastLocation = event.location

        switch type {
        case .leftMouseDown:  return handleDown(button: .left, event: event)
        case .rightMouseDown: return handleDown(button: .right, event: event)
        case .leftMouseUp:    return handleUp(button: .left, event: event)
        case .rightMouseUp:   return handleUp(button: .right, event: event)
        case .leftMouseDragged, .rightMouseDragged:
            return handleDragged(event: event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleDown(button: CGMouseButton, event: CGEvent) -> Unmanaged<CGEvent>? {
        realButtonDown = button

        if touchGate.isOpen && !middleActive {
            debugLog("🟢 portillon déjà ouvert au moment du clic -> fusion immédiate")
            beginMiddle(at: event.location)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func handleDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard middleActive else {
            return Unmanaged.passRetained(event)
        }
        sendMiddle(type: .otherMouseDragged, at: event.location)
        return nil
    }

    private func handleUp(button: CGMouseButton, event: CGEvent) -> Unmanaged<CGEvent>? {
        defer { realButtonDown = nil }

        if middleActive {
            debugLog("🔴 relâchement bouton réel pendant fusion -> fin du clic milieu")
            endMiddle(at: event.location)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Réactions au portillon tactile

    private func gateDidOpen() {
        guard isEnabled, !middleActive else { return }

        if let button = realButtonDown {
            // Un clic simple était déjà en cours : on le referme proprement
            // avant de démarrer le clic milieu, au même endroit.
            debugLog("🟠 portillon ouvert pendant un clic \(button == .left ? "gauche" : "droit") en cours -> hot-swap vers milieu")
            let closeType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp
            sendReal(type: closeType, button: button, at: lastLocation)
            beginMiddle(at: lastLocation)
        }
        // Sinon : 2 doigts posés sans clic en cours, on ne fait rien tant
        // qu'aucun mouseDown ne survient (voir handleDown).
    }

    private func gateDidClose() {
        guard isEnabled, middleActive else { return }
        debugLog("🔴 portillon refermé -> fin du clic milieu")
        endMiddle(at: lastLocation)
    }

    // MARK: - Émission des événements synthétiques

    private func beginMiddle(at point: CGPoint) {
        middleActive = true
        sendMiddle(type: .otherMouseDown, at: point)
    }

    private func endMiddle(at point: CGPoint) {
        middleActive = false
        sendMiddle(type: .otherMouseUp, at: point)
    }

    private func sendMiddle(type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .center
        ) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    /// Ré-émet un vrai mouseUp gauche/droit synthétique (pour le hot-swap),
    /// distinct du clic milieu.
    private func sendReal(type: CGEventType, button: CGMouseButton, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
    }
}
