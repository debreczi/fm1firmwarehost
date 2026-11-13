import SwiftUI
import UniformTypeIdentifiers

struct BackupsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceController.self) private var device
    @State private var askName = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(library.notices) { n in LibraryProblemCard(notice: n) { library.dismiss(n) } }
                    intro
                    if library.snapshots.isEmpty {
                        EmptyState(icon: "externaldrive", title: "No backups yet",
                                   text: "A backup remembers which firmware is on your FM-1 and keeps its package, so you can put it back any time. If several firmwares can report the same identity, you choose. On Felucca and SLOOP firmwares it also saves your music, settings, projects and samples.")
                    } else {
                        ForEach(library.snapshots) { s in
                            NavigationLink(value: s) { SnapshotCard(snapshot: s) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .hubBackground()
            .navigationTitle("Backups")
            .navigationDestination(for: Snapshot.self) { SnapshotDetailView(snapshot: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { name = device.backupName; askName = true } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(device.isBusy)
                }
            }
            .alert("Name this backup", isPresented: $askName) {
                TextField("Name", text: $name)
                Button("Save") { device.snapshot(name: name.isEmpty ? nil : name) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The FM-1 must be plugged in and stopped.") }
        }
    }

    private var intro: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 26)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Files › On My iPhone › FM-1 Hub › Snapshots").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Every backup is a folder there: copy it to iCloud Drive or a computer to keep it beyond this app.").font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            Spacer()
        }
        .padding(14).card()
    }
}

struct SnapshotCard: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CatalogStore.self) private var catalog
    let snapshot: Snapshot

    var body: some View {
        let c = snapshot.firmwareId.map { Look.colour(for: $0) } ?? Theme.accent
        HStack(spacing: 14) {
            if let id = snapshot.firmwareId {
                HubImage(url: HubAPI.url("img/\(id).png"), tint: c).frame(width: 72, height: 56).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.opacity(0.15)).frame(width: 72, height: 56)
                    Image(systemName: "externaldrive").foregroundStyle(c)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.name).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
                Text("\(snapshot.firmwareName)\(snapshot.version.map { " \($0)" } ?? "") · \(snapshot.identity)").font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                // Side by side when they fit, else one above the other, smaller on the narrowest cards: no word may break or be cut.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { chips(tint: c) }
                    VStack(alignment: .leading, spacing: 4) { chips(tint: c) }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                Text(snapshot.date.shortText).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 17)).foregroundStyle(Theme.textFaint)   // a fixed size, like the rest of this card
        }
        .padding(12).card(tint: c)
    }

    @ViewBuilder private func chips(tint c: Color) -> some View {
        if snapshot.hasPackage {
            Chip(text: catalog.packageIsUnconfirmed(in: snapshot) ? "firmware (unconfirmed)" : snapshot.packageExact ? "firmware" : "firmware (hub's version)", icon: "shippingbox", tint: c)
        }
        if snapshot.hasArchive { Chip(text: "music \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.archiveBytes ?? 0), countStyle: .file))", icon: "music.note", tint: Theme.ok) }
    }
}

struct SnapshotDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceController.self) private var device
    @Environment(CatalogStore.self) private var catalog
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State var snapshot: Snapshot
    @State private var confirmDelete = false
    @State private var restorePrompt: InstallPrompt?
    @State private var confirmArchive = false
    @State private var editing = false
    @State private var newName = ""

    /// The firmwares this backup's identity may belong to.
    private var sharing: [Firmware] { catalog.firmwares(reporting: snapshot.identity) }
    private var unconfirmed: Bool { catalog.packageIsUnconfirmed(in: snapshot) }

    private func askRestore() {
        let s = snapshot
        restorePrompt = InstallPrompt(title: s.firmwareId == nil && unconfirmed ? "Put this package back on the FM-1?" : "Put \(s.firmwareName) back on the FM-1?",
                                      message: (unconfirmed ? "The app can't confirm this is the firmware that was on your FM-1. " : "") + "Installs the saved package." + (s.hasArchive && s.musicRestoresInApp ? " Restore the music archive afterwards, from this same backup." : ""),
                                      confirm: "Restore the firmware", verdict: device.chipVerdict(device.chipSupport(of: s))) { consent in device.restoreFirmware(s, consent: consent) }
    }

    private var musicFacts: String {
        guard snapshot.hasArchive else { return "none (this firmware has no backup over USB that the app knows)" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(snapshot.archiveBytes ?? 0), countStyle: .file)
        let format = !snapshot.hasSloopArchive ? "felucca-backup v1, opens in the Felucca web editor too" : snapshot.musicRestoresInApp ? "sloop-backup v1, opens in the SLOOP web editor too" : "sloop-backup v1"
        return "\(snapshot.archiveObjects ?? 0) objects, \(size) (\(format))"
    }

    var body: some View {
        let c = snapshot.firmwareId.map { Look.colour(for: $0) } ?? Theme.accent
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let id = snapshot.firmwareId {
                    HubImage(url: HubAPI.url("img/\(id).png"), tint: c, wide: Look.wide.contains(id)).frame(height: 160).frame(maxWidth: .infinity).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.name).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("\(snapshot.firmwareName)\(snapshot.version.map { " \($0)" } ?? "") · \(snapshot.date.shortText)").font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim)
                }

                VStack(spacing: 10) {
                    if let page = catalog.ownInstaller(of: snapshot) {
                        if let u = URL(string: page) {
                            Link(destination: u) { Label("Install with its own installer", systemImage: "arrow.up.right.square") }.buttonStyle(SecondaryButtonStyle())
                        }
                        Text("\(snapshot.firmwareName) is installed by its maker's own page: the package alone is not all of it.").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    } else if snapshot.hasPackage {
                        Button { askRestore() } label: { Label("Restore the firmware", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(PrimaryButtonStyle(tint: c)).disabled(device.isBusy)
                        if unconfirmed {
                            Text("The app can't confirm that this package is the firmware that was on your FM-1: it only reports \(snapshot.identity), and other firmwares may use that number too.")
                                .font(.system(size: 12)).foregroundStyle(Theme.warn)
                            if !sharing.isEmpty {
                                NavigationLink { FirmwareChoiceView(snapshot: snapshot, firmwares: sharing) } label: { Label("Choose another firmware", systemImage: "list.bullet") }
                                    .buttonStyle(SecondaryButtonStyle()).disabled(device.isBusy)
                            }
                            AttachPackageView(snapshot: $snapshot)
                        } else if !snapshot.packageExact {
                            Text("The FM-1 reported \(snapshot.identity). The package saved is \(snapshot.firmwareName) \(snapshot.version ?? ""), which may not be the version that was on it.")
                                .font(.system(size: 12)).foregroundStyle(Theme.warn)
                            AttachPackageView(snapshot: $snapshot)
                        }
                    } else {
                        if !sharing.isEmpty {
                            NavigationLink { FirmwareChoiceView(snapshot: snapshot, firmwares: sharing) } label: { Label("Choose the firmware", systemImage: "list.bullet") }
                                .buttonStyle(PrimaryButtonStyle(tint: c)).disabled(device.isBusy)
                        }
                        AttachPackageView(snapshot: $snapshot)
                    }
                    if snapshot.hasArchive {
                        if snapshot.musicRestoresInApp {
                            Button { confirmArchive = true } label: { Label("Restore the music archive", systemImage: "music.note") }
                                .buttonStyle(SecondaryButtonStyle(tint: Theme.ok)).disabled(device.isBusy)
                        } else {
                            Text(SloopBackup.ownEditorOnly).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        }
                    }
                    if let u = library.packageURL(for: snapshot) ?? library.archiveURL(for: snapshot) {
                        ShareLink(items: [library.packageURL(for: snapshot), library.archiveURL(for: snapshot)].compactMap { $0 }) {
                            Label("Share the files", systemImage: "square.and.arrow.up")
                        }.buttonStyle(SecondaryButtonStyle())
                        Text(u.deletingLastPathComponent().path.replacingOccurrences(of: Paths.documents.path, with: "FM-1 Hub")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(text: "What it holds")
                    VStack(spacing: 0) {
                        FactRow(label: "Reported", value: snapshot.identity, mono: true)
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Firmware", value: snapshot.firmwareName + (snapshot.version.map { " \($0)" } ?? ""))
                        if snapshot.hasPackage {
                            Divider().overlay(Theme.stroke)
                            FactRow(label: "Package", value: "\(ByteCountFormatter.string(fromByteCount: Int64(snapshot.packageSize ?? 0), countStyle: .file)) · \(snapshot.product ?? "")")
                            Divider().overlay(Theme.stroke)
                            FactRow(label: "SHA-256", value: snapshot.packageSHA256 ?? "", mono: true)
                        }
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Music", value: musicFacts)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6).card()
                }

                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(text: "Notes")
                    TextField("Notes", text: $snapshot.notes, axis: .vertical).lineLimit(2...6)
                        .padding(14).card()
                        .onChange(of: snapshot.notes) { _, _ in library.update(snapshot) }
                }

                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete this backup", systemImage: "trash") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.err))
            }
            .padding(16)
        }
        .hubBackground()
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: library.snapshots) { _, all in
            // a package chosen for this backup arrives through the library
            if let fresh = all.first(where: { $0.id == snapshot.id }), fresh != snapshot { snapshot = fresh }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Rename") { newName = snapshot.name; editing = true } }
        }
        .alert("Rename", isPresented: $editing) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { snapshot.name = name; library.update(snapshot) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .installPrompt($restorePrompt) { settings.newerChipOnly = true; settings.tab = 0 }
        .confirmationDialog("Write the music archive to the FM-1?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Restore the music", role: .destructive) { device.restoreArchive(snapshot) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Replaces the current music, settings, projects, user banks and samples on the FM-1 with the archive. The FM-1 must run a \(snapshot.hasSloopArchive ? "SLOOP" : "Felucca-family") firmware, best \(catalog.firmwareName(of: snapshot)), and be stopped.") }
        .confirmationDialog("Delete this backup?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { library.remove(snapshot); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The saved package and archive are deleted from this iPhone.") }
    }
}


/// This backup's identity can't name its firmware and the device did not say, so the user chooses. The package comes from
/// the hub, checked against the catalogue.
struct FirmwareChoiceView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceController.self) private var device
    @Environment(\.dismiss) private var dismiss
    let snapshot: Snapshot
    let firmwares: [Firmware]

    var body: some View {
        // installed with this app before this backup was made: a later install says nothing about what was on it then
        let last = library.history.first { $0.success && $0.identityAfter == snapshot.identity && $0.date <= snapshot.date }?.firmwareId
        let choices = firmwares.filter { !$0.needsOwnInstaller }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(firmwares.count > 1 ? "Several firmwares" : firmwares.first?.name ?? "A firmware") can report \(snapshot.identity). Choose what was on your FM-1 when you made this backup, and the hub's package of it goes into the backup. The hub keeps only each firmware's newest version.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textDim)
                if let said = snapshot.reportedName, !Firmware.saidName(said, among: firmwares, identity: snapshot.identity).isEmpty {
                    Text("It called itself “\(said)”.").font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                ForEach(Firmware.likeliestFirst(choices, identity: snapshot.identity, reported: snapshot.reportedName, lastInstalled: last)) { f in
                    Button { device.attachFirmware(f, to: snapshot); dismiss() } label: {
                        HStack(spacing: 12) {
                            HubImage(url: f.imageURL, tint: Look.colour(for: f.id)).frame(width: 56, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(f.name) \(f.version)").font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                                Text("by \(f.author)").font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10).card()
                    }
                    .buttonStyle(.plain).disabled(device.isBusy)
                }
                // no package of theirs can be chosen, as it is not all of them: their maker's page puts them back
                ForEach(firmwares.filter(\.needsOwnInstaller)) { f in
                    if let u = f.install.flatMap(URL.init) {
                        Link(destination: u) { Label("\(f.name): installed by its maker's own page", systemImage: "arrow.up.right.square") }
                            .font(.system(size: 13))
                    }
                }
            }
            .padding(16)
        }
        .hubBackground()
        .navigationTitle("Which firmware?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A backup the app could not complete on its own: the package is nowhere it knows to look. The last resort is a
/// .fwsc from Files; everything else was tried automatically.
struct AttachPackageView: View {
    @Environment(DeviceController.self) private var device
    @Binding var snapshot: Snapshot
    @State private var importing = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !snapshot.hasPackage {
                Label("No firmware package in this backup", systemImage: "shippingbox").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.warn)
                Text(snapshot.packageNote ?? "The FM-1 reported \(snapshot.identity), and no package with that identity could be found on the hub, on this phone or among the makers' releases.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
            Button { importing = true } label: { Label("Pick its .fwsc from Files", systemImage: "folder") }.buttonStyle(SecondaryButtonStyle())
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Theme.err) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                if let e = device.attachPackage(to: snapshot, fileURL: u) { error = e }
                else if let fresh = device.library.snapshots.first(where: { $0.id == snapshot.id }) { snapshot = fresh; error = "" }
            }
        }
    }
}
