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
    var disclaimerAccepted: Bool { didSet { d.set(disclaimerAccepted, forKey: "disclaimerAccepted") } }

    init() {
        showBetas = d.object(forKey: "showBetas") as? Bool ?? true
        showDevOnly = d.object(forKey: "showDevOnly") as? Bool ?? true
        probeAllPorts = d.bool(forKey: "probeAllPorts")
        autoSnapshotBeforeInstall = d.object(forKey: "autoSnapshot") as? Bool ?? true
        chosenPorts = d.stringArray(forKey: "chosenPorts") ?? []
        sort = SortOrder(rawValue: d.string(forKey: "sort") ?? "") ?? .installs
        gridView = d.object(forKey: "gridView") as? Bool ?? false
        selectedKinds = d.stringArray(forKey: "kinds") ?? []
        disclaimerAccepted = d.bool(forKey: "disclaimerAccepted")
    }
}
