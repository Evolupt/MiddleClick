import Foundation

// MARK: - Structures brutes (reverse-engineering communautaire, non documenté par Apple)
//
// ⚠️ Zone la plus fragile du projet : ces structures ne sont pas garanties par
// Apple et peuvent changer d'une version de macOS à l'autre. Convention
// largement utilisée par la communauté depuis des années (Amethyst,
// BetterTouchTool-like projects, etc.), mais non testable dans cet
// environnement — à vérifier/ajuster via les traces de debug si besoin.

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// Un contact (doigt) détecté par le capteur tactile.
/// On n'utilise en pratique QUE `state` (et `identifier` pour le debug) :
/// même si les champs de position/vitesse ci-dessous sont mal alignés sur ta
/// version de macOS, la détection du nombre de doigts reste fiable.
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerId: Int32
    var handId: Int32
    var normalizedVector: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mmVector: MTVector
    var zero2a: Int32
    var zero2b: Int32
    var unknown2: Float
}

/// États observés du champ `state`. Le seul qui nous intéresse vraiment est
/// `.touching` (doigt réellement posé). Si le comptage de doigts semble faux
/// à l'usage, regarde les valeurs brutes affichées en debug et ajuste
/// `TouchGate.activeStates` en conséquence.
enum MTTouchState: Int32 {
    case notTracking = 0
    case startInRange = 1
    case hoverInRange = 2
    case makingContact = 3
    case touching = 4
    case breakingContact = 5
    case lingeringInRange = 6
    case outOfRange = 7
}

typealias MTDeviceRef = UnsafeMutableRawPointer

// Remarque : on ne déclare volontairement PAS de typealias `@convention(c)`
// pour la signature complète du callback (5 paramètres). Le vérificateur du
// compilateur Swift a un bug connu qui rejette à tort ce genre de type avec
// le message "is not representable in Objective-C", même en dehors de tout
// contexte Objective-C. La fonction de callback est déclarée avec `@_cdecl`
// dans TouchGate.swift, qui contourne cette vérification, et on la passe
// ensuite comme simple pointeur brut (`UnsafeRawPointer`) — suffisant au
// niveau ABI puisqu'un pointeur de fonction et un pointeur générique ont la
// même taille/représentation.

typealias MTDeviceCreateListFunc = @convention(c) () -> Unmanaged<CFMutableArray>?
typealias MTRegisterContactFrameCallbackFunc = @convention(c) (MTDeviceRef, UnsafeRawPointer) -> Void
typealias MTUnregisterContactFrameCallbackFunc = @convention(c) (MTDeviceRef, UnsafeRawPointer) -> Void
typealias MTDeviceStartFunc = @convention(c) (MTDeviceRef, Int32) -> Void
typealias MTDeviceStopFunc = @convention(c) (MTDeviceRef) -> Void

/// Chargement dynamique de MultitouchSupport.framework (framework privé,
/// pas de header public donc pas de link direct au moment de la compilation).
enum MultitouchPrivateAPI {

    private static let handle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_NOW) else {
            debugLog("⚠️ impossible de charger MultitouchSupport.framework (\(String(cString: dlerror()))).")
            return nil
        }
        return h
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = handle, let sym = dlsym(handle, name) else {
            debugLog("⚠️ symbole introuvable dans MultitouchSupport: \(name)")
            return nil
        }
        return unsafeBitCast(sym, to: type)
    }

    static let deviceCreateList = symbol("MTDeviceCreateList", as: MTDeviceCreateListFunc.self)
    static let registerContactFrameCallback = symbol("MTRegisterContactFrameCallback", as: MTRegisterContactFrameCallbackFunc.self)
    static let unregisterContactFrameCallback = symbol("MTUnregisterContactFrameCallback", as: MTUnregisterContactFrameCallbackFunc.self)
    static let deviceStart = symbol("MTDeviceStart", as: MTDeviceStartFunc.self)
    static let deviceStop = symbol("MTDeviceStop", as: MTDeviceStopFunc.self)

    static var isAvailable: Bool {
        deviceCreateList != nil && registerContactFrameCallback != nil && deviceStart != nil
    }
}
