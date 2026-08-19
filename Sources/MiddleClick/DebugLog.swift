import Foundation

/// Traces de mise au point pour tout le projet. Silencieuses par défaut —
/// active-les sans toucher au code avec :
///
///   MIDDLECLICK_VERBOSE=1 swift run
///
/// (et lance via `swift run` pour voir la sortie dans le Terminal). Utile
/// si tu dois un jour déboguer un souci, notamment après une mise à jour de
/// macOS qui casserait le binding MultitouchSupport.
enum Debug {
    static var verbose = ProcessInfo.processInfo.environment["MIDDLECLICK_VERBOSE"] == "1"
}

func debugLog(_ message: @autoclosure () -> String) {
    guard Debug.verbose else { return }
    print("MiddleClick: \(message())")
}
