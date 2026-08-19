import Foundation

/// Traces de mise au point pour tout le projet. Silencieuses par défaut —
/// passe `verbose` à `true` (et lance via `swift run` pour voir la sortie
/// dans le Terminal) si tu dois un jour déboguer un souci, notamment après
/// une mise à jour de macOS qui casserait le binding MultitouchSupport.
enum Debug {
    static var verbose = false
}

func debugLog(_ message: @autoclosure () -> String) {
    guard Debug.verbose else { return }
    print("MiddleClick: \(message())")
}
