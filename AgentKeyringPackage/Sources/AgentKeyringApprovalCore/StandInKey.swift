// Written by AI on 2026.11.19 by model claude opus 5.5.
//
// For rehearsing on a Mac without Touch ID, in Debug builds only: launched
// with -StandInKey YES, the Mac app keeps software keys in its container in
// place of the Secure Enclave, and macOS's Touch ID or Apple Watch dialog
// answers at once. Every approval still needs its click and runs the same
// code; only the finger is replaced. Release builds hold none of this.

#if DEBUG
import Foundation

public enum StandInKey {
    public static var isOn: Bool { UserDefaults.standard.bool(forKey: "StandInKey") }
}
#endif
