import SwiftUI
import UniformTypeIdentifiers

struct DeviceView: View {
    @Environment(DeviceController.self) private var device
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var importing = false
    @State private var confirmStock = false
    @State private var confirmOfficialLatest = true
    @State private var askName = false
    @State private var snapshotName = ""
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if device.loaderWaiting != nil { resumeCard }
                    actions
                    officialCard
                    portsCard
                    howTo
                    logCard
                }
                .padding(16)
            }
            .hubBackground()
            .navigationTitle("Your FM-1")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first { device.installFile(u) }
            }
            .confirmationDialog(confirmOfficialLatest ? "Install M-VAVE's current firmware\(device.officialLatestVersion.map { " (\($0))" } ?? "")?" : "Back to the official V15?", isPresented: $confirmStock, titleVisibility: .visible) {
                Button(confirmOfficialLatest ? "Install the latest official" : "Install V15") { device.installOfficial(latest: confirmOfficialLatest) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmOfficialLatest
                     ? "The file M-VAVE publishes on m-vave.com, fetched now; its identity is read from the file before anything is written."
                     : "M-VAVE's own FM-1 V15 as the hub serves it: the recovery image, checked byte for byte (SHA-256) before anything is written.")
            }
            .task { await device.checkOfficial() }
            .alert("Name this backup", isPresented: $askName) {
                TextField("Name", text: $snapshotName)
                Button("Save") { device.snapshot(name: snapshotName.isEmpty ? nil : snapshotName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves which firmware is on the FM-1 and its package; a Felucca-family firmware's music, settings, projects and samples too.")
            }
        }
    }

    private var statusCard: some View {
        let who = device.whoIs
        let c = who?.firmware.map { Look.colour(for: $0.id) } ?? Theme.accent
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    Circle().fill(c.opacity(0.15)).frame(width: 56, height: 56)
                    Image(systemName: device.isConnected ? "cable.connector" : "cable.connector.slash").font(.system(size: 24, weight: .medium)).foregroundStyle(c)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let id = device.identity {
                        Text(who?.firmware?.name ?? who?.name ?? id.text).font(.system(size: 22, weight: .bold, design: .rounded))
                        if let f = who?.firmware {
                            Text(who?.exact == true ? "\(f.version) · the newest · by \(f.author)" : "another version than the hub's \(f.version) · reports \(id.text)")
                                .font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim)
                        } else {
                            Text("reports \(id.text)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.textDim)
                        }
                        if let d = device.identityDate { Text("asked \(d.shortText)").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.textFaint) }
                    } else {
                        Text(device.phase == .connecting ? "Looking…" : "Not connected").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Plug the FM-1 into the iPhone's USB-C port (Lightning: a camera adapter), switch it on, then Connect.")
                            .font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim)
                    }
                }
                Spacer(minLength: 0)
            }
            if let s = device.feluccaBackupSupported, device.isConnected {
                Label(s ? "Answers the music backup protocol: Backup saves projects, presets and samples." : "No music backup over USB: use this firmware's own backup tool for projects and presets.",
                      systemImage: s ? "checkmark.seal" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(s ? Theme.ok : Theme.textDim)
            }
            if !device.statusMessage.isEmpty {
                Text(device.statusMessage).font(.system(size: 13)).foregroundStyle(Theme.warn)
            }
            if !device.otherPorts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Is one of these your FM-1? (A firmware that names its port after itself. Nothing is written by asking.)").font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    ForEach(device.otherPorts, id: \.self) { n in
                        Button { device.choosePort(n); device.connect() } label: { Label(n, systemImage: "questionmark.circle") }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Button { device.connect() } label: {
                Label(device.isConnected ? "Ask again" : "Connect", systemImage: "bolt.fill")
            }
            .buttonStyle(PrimaryButtonStyle(tint: c)).disabled(device.isBusy)
        }
        .padding(16)
        .card(tint: c)
    }

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The FM-1 is in update mode", systemImage: "exclamationmark.triangle.fill").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.warn)
            if let p = library.pending {
                Text("The update to \(p.name)\(p.version.isEmpty ? "" : " \(p.version)") was interrupted (\(device.loaderWaiting?.text ?? "")). Installing any firmware from the list continues from here. Or write that same package again:")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                Button { device.resume() } label: { Label("Resume: \(p.name)", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.warn)).disabled(device.isBusy)
            } else {
                Text("An update was interrupted (\(device.loaderWaiting?.text ?? "")), but this app does not know which package was being written — it was another updater, or an older version of this app. Install any firmware from the list: that continues from here.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(16).card(tint: Theme.warn)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: "Actions")
            VStack(spacing: 10) {
                Button { snapshotName = device.whoIs?.firmware?.name ?? device.whoIs?.name ?? ""; askName = true } label: {
                    Label("Back up the FM-1 now", systemImage: "externaldrive.badge.plus")
                }.buttonStyle(PrimaryButtonStyle(tint: Theme.accent)).disabled(device.isBusy)
                Text("A backup keeps the firmware package (found on the hub, on this phone or in the maker's releases) and, on Felucca-family firmwares, your music, settings, projects and samples. Restore is one tap on the Backups tab.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            }
            .padding(14).card()
        }
    }

    private var officialCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: "Official firmware")
            VStack(spacing: 10) {
                Button { confirmOfficialLatest = true; confirmStock = true } label: {
                    Label(device.officialLatestVersion.map { "Install the latest official (\($0))" } ?? (device.officialChecking ? "Checking m-vave.com…" : "Install the latest official"), systemImage: "checkmark.seal")
                }
                .buttonStyle(PrimaryButtonStyle(tint: Color(hex: "#9aa4b2"))).disabled(device.isBusy)
                Button { confirmOfficialLatest = false; confirmStock = true } label: { Label("Back to V15 (recovery image)", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(device.isBusy)
                Text("The latest comes straight from M-VAVE's download server, so a new official version shows up here without an app update. V15 is the known-good image the hub keeps for getting back to stock.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            }
            .padding(14).card()
        }
    }

    private var portsCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: "MIDI ports")
            VStack(alignment: .leading, spacing: 6) {
                if device.midiPorts.isEmpty {
                    Text("No USB MIDI device. The FM-1 shows up as a MIDI device when it is plugged in and on.").font(.system(size: 13)).foregroundStyle(Theme.textDim)
                } else {
                    ForEach(device.midiPorts, id: \.self) { n in
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.accent)
                            Text(n).font(.system(size: 14, design: .rounded))
                            Spacer()
                            if FM1Protocol.mayProbe(n) || settings.chosenPorts.contains(n) || settings.probeAllPorts {
                                Chip(text: "probed", tint: Theme.ok)
                            } else {
                                Button("This is my FM-1") { device.choosePort(n) }.font(.system(size: 12, weight: .semibold)).buttonStyle(.bordered).controlSize(.mini)
                            }
                        }
                    }
                }
                Button { device.refreshPorts() } label: { Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .semibold)) }.buttonStyle(.borderless).padding(.top, 4)
            }
            .padding(14).card()
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: "Good to know")
            VStack(alignment: .leading, spacing: 10) {
                tip("cable.connector", "iPhone 15 and newer: a USB-C to USB-C cable straight into the FM-1. Older iPhones: Apple's Lightning to USB camera adapter, best the powered one. Battery or a powered hub helps if the FM-1 does not power up from the phone.")
                tip("xmark.circle", "Close other MIDI apps while installing: one app at a time may talk to the FM-1.")
                tip("hand.raised", "If a firmware does not start the update: hold OCT− while switching the FM-1 on. It then waits for an update over USB; press Install again.")
                tip("externaldrive", "All firmwares keep what you make in the same flash memory. After a switch, the new firmware may not read what the old one saved. Back up first.")
                tip("book", "The hub's knowledge base has the details.")
                Link("Open the knowledge base", destination: HubAPI.knowledgeBase).font(.system(size: 13, weight: .semibold))
            }
            .padding(14).card()
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private var logCard: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 2) {
                Button { importing = true } label: { Label("Install a .fwsc from Files (last resort)", systemImage: "folder").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.borderless).disabled(device.isBusy).padding(.vertical, 6)
                if device.log.isEmpty { Text("Nothing yet.").foregroundStyle(Theme.textFaint) }
                ForEach(Array(device.log.suffix(60).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim).textSelection(.enabled)
                }
                Button("Clear") { device.clearLog() }.font(.system(size: 12)).padding(.top, 6)
            }
            .padding(.top, 8)
        } label: {
            Label("More and log", systemImage: "terminal").font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .padding(14).card()
    }
}
