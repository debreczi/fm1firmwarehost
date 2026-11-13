import Foundation
import Observation

/// The settings, in UserDefaults: nothing leaves the phone.
@MainActor
@Observable
final class AppSettings {
    private let d = UserDefaults.standard

    var showBetas: Bool { didSet { d.set(showBetas, forKey: "showBetas") } }
    var showDevOnly: Bool { didSet { d.set(showDevOnly, forKey: "showDevOnly") } }
    var probeAllPorts: Bool { didSet { d.set(probeAllPorts, forKey: "probeAllPorts") } }
    var autoSnapshotBeforeInstall: Bool { didSet { d.set(autoSnapshotBeforeInstall, forKey: "autoSnapshot") } }
    var chosenPorts: [String] { didSet { d.set(chosenPorts, forKey: "chosenPorts") } }
    var sort: SortOrder { didSet { d.set(sort.rawValue, forKey: "sort") } }
    var gridView: Bool { didSet { d.set(gridView, forKey: "gridView") } }
    var selectedKinds: [String] { didSet { d.set(selectedKinds, forKey: "kinds") } }
    var disclaimerAccepted: Bool { didSet { if !Demo.isOn { d.set(disclaimerAccepted, forKey: "disclaimerAccepted") } } }
    /// Settings › Allow installing on unsafe FM-1s. Off: a firmware the FM-1's reported flash chip can't take is refused;
    /// on: the user is asked, as a dangerous install, every time. It matters only when the FM-1 reports its chip.
    var allowUnsafeInstalls: Bool { didSet { d.set(allowUnsafeInstalls, forKey: "allowUnsafeInstalls") } }
    /// The firmware list shows only those that work on newer FM-1s too (the hub's "Saves on newer FM-1s").
    var newerChipOnly: Bool { didSet { d.set(newerChipOnly, forKey: "newerChipOnly") } }
    /// The tab on show; not kept.
    var tab: Int

    init() {
        showBetas = d.object(forKey: "showBetas") as? Bool ?? true
        showDevOnly = d.object(forKey: "showDevOnly") as? Bool ?? true
        probeAllPorts = d.bool(forKey: "probeAllPorts")
        autoSnapshotBeforeInstall = d.object(forKey: "autoSnapshot") as? Bool ?? true
        chosenPorts = d.stringArray(forKey: "chosenPorts") ?? []
        sort = SortOrder(rawValue: d.string(forKey: "sort") ?? "") ?? .installs
        gridView = d.object(forKey: "gridView") as? Bool ?? false
        selectedKinds = d.stringArray(forKey: "kinds") ?? []
        disclaimerAccepted = Demo.isOn || d.bool(forKey: "disclaimerAccepted")   // no warning in the screenshots
        allowUnsafeInstalls = d.bool(forKey: "allowUnsafeInstalls")
        newerChipOnly = d.bool(forKey: "newerChipOnly")
        tab = Demo.isOn ? Demo.tab : 0
    }
}
