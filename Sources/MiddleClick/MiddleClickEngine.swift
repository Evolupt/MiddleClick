import Cocoa
import ApplicationServices
import IOKit.hid

/// Fusionne un clic (et un glissé maintenu) gauche/droite en clic du bouton
/// du milieu, en s'appuyant sur `TouchGate` comme simple lecture d'état AU
/// MOMENT DU CLIC — pas comme déclencheur réagissant en cours de geste.
///
/// Principe (verrouillage à l'appui) :
/// - Au moment précis d'un `mouseDown` (gauche ou droit), on regarde combien
///   de doigts sont posés à cet instant précis. Si le portillon tactile est
///   ouvert (≥ 2 doigts), toute la pression (down / dragged / up) est
///   convertie en clic du bouton du milieu, du début à la fin. Sinon, tout
///   est transmis normalement.
/// - Cette décision est prise UNE SEULE FOIS et reste VERROUILLÉE pour toute
///   la durée de l'appui : les doigts peuvent ensuite se poser ou se lever
///   sans rien changer, jusqu'au relâchement réel du bouton.
///
/// Ça évite deux problèmes symétriques rencontrés avec une version plus
/// réactive : un doigt qui se pose par inadvertance en cours de glissement
/// simple (annulait une sélection à tort), et un doigt qui se lève en cours
/// de glissé milieu (coupait le drag milieu à tort — alors qu'on veut au
/// contraire qu'il continue tant que le bouton physique reste enfoncé).
final class MiddleClickEngine {

    private static let syntheticMarker: Int64 = 0x4D43 // "MC"

    let touchGate = TouchGate()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var lastLocation: CGPoint = .zero

    /// `true` entre un mouseDown et son mouseUp correspondant.
    private var pressLocked = false
    /// Décidé une seule fois à l'appui, ignoré ensuite jusqu'au relâchement.
    private var pressIsMiddle = false

    /// Coupe/rétablit l'interception à chaud, sans démonter le tap ni
    /// perdre les autorisations déjà accordées. Si on désactive en pleine
    /// session milieu verrouillée, on la referme proprement plutôt que de
    /// laisser le bouton "coincé" enfoncé.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            debugLog(isEnabled ? "🟢 activé" : "⚪️ désactivé")
            if !isEnabled && pressLocked && pressIsMiddle {
                endMiddle(at: lastLocation)
            }
            pressLocked = false
        }
    }

    func start() {
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
        pressLocked = false
        pressIsMiddle = false
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
        case .leftMouseDown, .rightMouseDown:
            return handleDown(event: event)
        case .leftMouseUp, .rightMouseUp:
            return handleUp(event: event)
        case .leftMouseDragged, .rightMouseDragged:
            return handleDragged(event: event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Décision prise UNE SEULE FOIS, à l'instant précis de l'appui, puis
        // verrouillée jusqu'au relâchement (voir handleUp).
        pressLocked = true
        pressIsMiddle = touchGate.isOpen

        if pressIsMiddle {
            debugLog("🟢 \(touchGate.currentCount) doigts posés à l'appui -> session verrouillée en clic milieu")
            beginMiddle(at: event.location)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func handleDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard pressLocked, pressIsMiddle else {
            return Unmanaged.passRetained(event)
        }
        sendMiddle(type: .otherMouseDragged, at: event.location)
        return nil
    }

    private func handleUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        defer { pressLocked = false }

        guard pressIsMiddle else {
            return Unmanaged.passRetained(event)
        }

        debugLog("🔴 relâchement réel -> fin de la session milieu verrouillée")
        endMiddle(at: event.location)
        return nil
    }

    // MARK: - Émission des événements synthétiques

    private func beginMiddle(at point: CGPoint) {
        sendMiddle(type: .otherMouseDown, at: point)
    }

    private func endMiddle(at point: CGPoint) {
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

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
    }
}
