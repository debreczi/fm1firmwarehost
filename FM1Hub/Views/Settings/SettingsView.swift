import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(CatalogStore.self) private var catalog
    @State private var cacheSize: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $settings.autoSnapshotBeforeInstall) {
                        Text("Back up before every install")
                        Text("When the running firmware answers Felucca's or SLOOP's backup protocol, its music, settings, projects and samples are saved before the new firmware goes on.").font(.footnote)
                    }
                } header: { Text("Installing") } footer: { Text("Every package that goes on the FM-1 is kept on this phone (about 0.6 MB each), so any firmware you installed can be put back without the network.") }

                Section {
                    Toggle(isOn: $settings.probeAllPorts) {
                        Text("Ask every MIDI port")
                        Text("Normally only ports named like an FM-1 are asked who they are. Turn this on if your firmware names its USB port after itself and the FM-1 is not found.").font(.footnote)
                    }
                    if !settings.chosenPorts.isEmpty {
                        ForEach(settings.chosenPorts, id: \.self) { p in
                            HStack { Text(p); Spacer(); Text("your FM-1").foregroundStyle(Theme.textFaint) }
                        }
                        .onDelete { idx in settings.chosenPorts.remove(atOffsets: idx) }
                    }
                } header: { Text("MIDI") } footer: { Text("Port names you marked as your FM-1. Swipe to forget one.") }

                Section {
                    LabeledContent("Packages", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    LabeledContent("Backups", value: ByteCountFormatter.string(fromByteCount: library.snapshotsSize(), countStyle: .file))
                    LabeledContent("Catalogue", value: catalog.updated ?? "–")
                    Button("Delete the package cache", role: .destructive) { confirmClear = true }
                    Button("Refresh the catalogue") { Task { await catalog.refresh(force: true) } }
                } header: { Text("Storage") } footer: { Text("Backups are never deleted here: each has its own Delete button. Everything lives on this iPhone; nothing is sent anywhere, there is no account.") }

                Section {
                    LinkRow(icon: "exclamationmark.bubble", title: "Send feedback or report a problem", url: URL(string: "https://torindrax.com/Issues/fm-1-hub")!)
                    LinkRow(icon: "building.columns", title: "The FM-1 Firmware Hub", url: HubAPI.site)
                    LinkRow(icon: "book", title: "Knowledge base (install, rescue, backups)", url: HubAPI.knowledgeBase)
                    LinkRow(icon: "person.2", title: "Wall of creators", url: HubAPI.creatorsPage)
                    LinkRow(icon: "arrow.down.circle", title: "M-VAVE downloads (official firmware)", url: HubAPI.stockDownload)
                    LinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "This app on GitHub", url: URL(string: "https://github.com/debreczi/fm1firmwarehost")!)
                } header: { Text("Links") }

                Section {
                    Text("FM-1 Hub for iPhone puts the catalogue of The FM-1 Firmware Hub on your phone and installs firmwares over USB with the same update protocol the hub and M-VAVE's updater use. The hub mirrors each package from its project's GitHub release and checks it by SHA-256; this app checks the same hash before anything is written.")
                    Text("Every firmware is its author's work and responsibility. Neither the hub nor this app reviews what a firmware does. Flashing can leave a device needing a rescue: read the knowledge base first and keep the official V15 at hand.")
                    Text("The update and backup protocol code in this app is a port of GPL-3.0 code by Leo Kuroshita (Hügelton Instruments) from the hub's installer and the Felucca web editor, and as carried on in the SLOOP web editor. The app is therefore distributed under the GPL-3.0 too.")
                    Text("FM-1 Hub for iPhone · Copyright (C) 2026 Janos Debreczi. This program comes with ABSOLUTELY NO WARRANTY. It is free software, and you are welcome to redistribute it under the GNU General Public License version 3; the licence and the complete source are in the repository linked above.")
                } header: { Text("About") } footer: { Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")) · not affiliated with M-VAVE or the hub") }
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
            }
            .scrollContentBackground(.hidden)
            .hubBackground()
            .navigationTitle("Settings")
            .onAppear { cacheSize = PackageStore.shared.cacheSize() }
            .confirmationDialog("Delete the downloaded packages?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { PackageStore.shared.clearCache(); cacheSize = PackageStore.shared.cacheSize() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Packages inside backups are kept. A firmware that is only in the cache can no longer be restored without the network.") }
        }
    }
}
