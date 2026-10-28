import Foundation

/// The screenshot mode of the App Store workflow: launched with `-FM1Screenshots YES` (a launch argument, so never on a
/// normal launch), the app shows sample data held in memory only. Nothing is written to disk and the FM-1 is not asked.
enum Demo {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "FM1Screenshots") }
    /// The tab to open: 0 Firmwares, 1 FM-1, 2 Backups, 3 History, 4 Settings.
    static var tab: Int { UserDefaults.standard.integer(forKey: "FM1Tab") }
    /// A firmware id to open on the Firmwares tab.
    static var open: String? { UserDefaults.standard.string(forKey: "FM1Open") }
    /// Show an install in progress.
    static var job: Bool { UserDefaults.standard.bool(forKey: "FM1Job") }
}
