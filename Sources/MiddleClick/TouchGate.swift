import Foundation

/// Surveille en continu le nombre de doigts posés sur la surface tactile
/// (Magic Mouse / trackpad) et expose un simple état `isOpen` — pas de
/// callback : `MiddleClickEngine` lit cet état de façon synchrone, une
/// seule fois, au moment précis d'un clic (voir MiddleClickEngine.swift
/// pour le pourquoi de ce choix plutôt qu'une réaction en temps réel).
final class TouchGate {

    /// Nombre de doigts nécessaires pour considérer le portillon "ouvert".
    /// 2 = le geste gauche+droite simultané d'origine. Passe à 3 si tu
    /// préfères un geste moins susceptible de se déclencher par erreur.
    var threshold = 2

    /// États du champ `state` considérés comme un doigt "actif". On ne
    /// garde QUE `.touching` (contact franc) : les états de transition
    /// (`.makingContact` / `.breakingContact`) sont plus sujets au bruit.
    var activeStates: Set<Int32> = [
        MTTouchState.touching.rawValue
    ]

    /// Surface de contact minimale (champ `size` de `MTTouch`) pour qu'un
    /// doigt compte comme "vraiment posé". La détection brute par état
    /// seul peut être très sensible (un effleurement léger compte comme un
    /// contact) ; ce seuil permet de filtrer ça. Unité brute du capteur
    /// (pas documentée par Apple) — 0 = pas de filtrage. Pour calibrer,
    /// passe `Debug.verbose = true` : chaque changement de nombre de
    /// doigts affiche aussi la taille brute de chaque contact, ce qui
    /// permet de repérer où mettre le seuil (une vraie pression du doigt
    /// donne une taille nettement plus grande qu'un effleurement).
    var minimumContactSize: Float = 0

    /// Le nombre de doigts doit rester ≥ `threshold` pendant cette durée
    /// avant que le portillon ne s'ouvre réellement — filtre les blips
    /// d'une seule frame (bruit du capteur, doigt qui glisse) sans ajouter
    /// de latence perceptible sur un vrai geste à 2 doigts maintenu.
    var openConfirmDelay: TimeInterval = 0.05

    private(set) var isOpen = false
    /// Dernier nombre de doigts actifs mesuré (après filtrage état + taille).
    private(set) var currentCount = 0

    private var devices: [MTDeviceRef] = []
    private var lastLoggedCount = -1
    private var pendingOpenWorkItem: DispatchWorkItem?

    /// Une seule instance à la fois : l'API C n'a pas de paramètre de
    /// contexte, on route donc le callback statique vers cette instance.
    private static weak var current: TouchGate?

    /// Pointeur C brut vers `touchGateContactCallback`. On passe d'abord par
    /// une variable typée `@convention(c)` (uniquement des types primitifs,
    /// donc sans le bug de représentabilité rencontré plus haut) pour
    /// obtenir la forme "fine" (un seul mot machine) attendue par
    /// `unsafeBitCast` — la référencer directement ne suffit pas, elle
    /// garde une représentation Swift plus large.
    private static let rawCallback: UnsafeRawPointer = {
        let typed: @convention(c) (MTDeviceRef, UnsafeMutableRawPointer, Int32, Double, Int32) -> Int32 = touchGateContactCallback
        return unsafeBitCast(typed, to: UnsafeRawPointer.self)
    }()

    func start() {
        guard MultitouchPrivateAPI.isAvailable else {
            debugLog("⚠️ MultitouchSupport indisponible, le portillon tactile ne peut pas démarrer.")
            return
        }
        guard let createList = MultitouchPrivateAPI.deviceCreateList,
              let register = MultitouchPrivateAPI.registerContactFrameCallback,
              let deviceStart = MultitouchPrivateAPI.deviceStart else {
            return
        }

        Self.current = self

        guard let cfList = createList()?.takeRetainedValue() else {
            debugLog("⚠️ aucun périphérique multitouch détecté.")
            return
        }

        let count = CFArrayGetCount(cfList)
        debugLog("\(count) périphérique(s) multitouch détecté(s) (trackpad et/ou Magic Mouse).")

        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cfList, i) else { continue }
            let device = MTDeviceRef(mutating: raw)
            devices.append(device)
            register(device, Self.rawCallback)
            deviceStart(device, 0)
        }
    }

    func stop() {
        guard let unregister = MultitouchPrivateAPI.unregisterContactFrameCallback,
              let deviceStop = MultitouchPrivateAPI.deviceStop else { return }
        for device in devices {
            unregister(device, Self.rawCallback)
            deviceStop(device)
        }
        devices.removeAll()
        pendingOpenWorkItem?.cancel()
        pendingOpenWorkItem = nil
        isOpen = false
        currentCount = 0
    }

    /// Appelé depuis le callback C, déjà sur le thread principal.
    fileprivate func handleFrame(touches: [MTTouch]) {
        let active = touches.filter {
            activeStates.contains($0.state) && $0.size >= minimumContactSize
        }
        let count = active.count
        currentCount = count

        if count != lastLoggedCount {
            let sizes = touches.map { String(format: "%.2f", $0.size) }
            debugLog("doigts actifs = \(count) (états bruts: \(touches.map { $0.state }), tailles brutes: \(sizes))")
            lastLoggedCount = count
        }

        let shouldBeOpen = count >= threshold

        if shouldBeOpen {
            guard !isOpen, pendingOpenWorkItem == nil else { return }
            // On ne confirme l'ouverture qu'après `openConfirmDelay` : si le
            // nombre de doigts retombe avant, `else` ci-dessous annule ce
            // work item et rien ne se déclenche.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingOpenWorkItem = nil
                self.isOpen = true
            }
            pendingOpenWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + openConfirmDelay, execute: work)
        } else {
            pendingOpenWorkItem?.cancel()
            pendingOpenWorkItem = nil
            isOpen = false
        }
    }

    fileprivate static func dispatch(touches: [MTTouch]) {
        guard let instance = current else { return }
        if Thread.isMainThread {
            instance.handleFrame(touches: touches)
        } else {
            DispatchQueue.main.async {
                instance.handleFrame(touches: touches)
            }
        }
    }
}

/// Trampoline C : l'API MultitouchSupport n'a pas de paramètre de contexte,
/// on repasse donc par l'instance courante de TouchGate.
///
/// `@_cdecl` expose cette fonction comme un symbole C pur — c'est ce qui
/// permet d'éviter le bug du compilateur évoqué dans MultitouchPrivate.swift
/// (on ne forme jamais explicitement le type `@convention(c)` à 5 paramètres
/// ailleurs que sur cette déclaration, que le compilateur valide via un
/// chemin différent, non buggé).
@_cdecl("middleClickTouchCallback")
private func touchGateContactCallback(
    _ device: MTDeviceRef,
    _ data: UnsafeMutableRawPointer,
    _ nFingers: Int32,
    _ timestamp: Double,
    _ frame: Int32
) -> Int32 {
    guard nFingers > 0 else {
        TouchGate.dispatch(touches: [])
        return 0
    }
    // Réinterprétation du pointeur brut en [MTTouch] : opération purement
    // Swift, qui n'a pas besoin de passer par la vérification C/ObjC de la
    // signature de la fonction (contrairement à un paramètre typé).
    let typed = data.assumingMemoryBound(to: MTTouch.self)
    let buffer = UnsafeBufferPointer(start: typed, count: Int(nFingers))
    TouchGate.dispatch(touches: Array(buffer))
    return 0
}
