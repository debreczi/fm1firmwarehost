import SwiftUI

struct FirmwareDetailView: View {
    @Environment(DeviceController.self) private var device
    @Environment(LibraryStore.self) private var library
    @Environment(CatalogStore.self) private var catalog
    let firmware: Firmware
    @State private var confirm = false
    @State private var saving = false
    @State private var saveMessage = ""

    var body: some View {
        let c = Look.colour(for: firmware.id)
        let onDevice = device.isRunning(firmware)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HubImage(url: firmware.imageURL, tint: c, wide: Look.wide.contains(firmware.id))
                    .frame(height: 200).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 6) {
                            if onDevice { Chip(text: "on your FM-1", icon: "checkmark", tint: Theme.ok, filled: true) }
                            if firmware.beta && !firmware.isDevOnly { Chip(text: "beta", tint: Theme.warn, filled: true) }
                        }.padding(10)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(firmware.name).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(firmware.version).font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(c)
                    }
                    Text("by \(firmware.author)").font(.system(size: 15, design: .rounded)).foregroundStyle(Theme.textDim)
                    HStack(spacing: 6) {
                        ForEach(firmware.allKinds, id: \.self) { k in Chip(text: Kinds.label(k), icon: Kinds.icon(k), tint: k == "vintage" ? Theme.warm : c) }
                        Chip(text: firmware.licenseText, tint: .white)
                    }
                    Text(firmware.what).font(.system(size: 16)).foregroundStyle(.white.opacity(0.88)).padding(.top, 4)
                    if let h = firmware.hid, !h.kinds.isEmpty {
                        Label("Contains a USB \(h.kinds.joined(separator: " and ")) interface: plugged into a computer, it can type or move the pointer like one. Common for macro pads, worth knowing.", systemImage: "keyboard")
                            .font(.system(size: 13)).foregroundStyle(Theme.warn).padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warn.opacity(0.1)))
                    }
                }

                VStack(spacing: 10) {
                    if firmware.needsOwnInstaller, let u = firmware.install.flatMap(URL.init) {
                        Link(destination: u) { Label("Install with its own installer", systemImage: "arrow.up.right.square") }.buttonStyle(SecondaryButtonStyle())
                        Text("This firmware is installed by its maker's own page: the package alone is not all of it.").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    } else {
                        Button { confirm = true } label: { Label(onDevice ? "Install again" : "Install on the FM-1", systemImage: "bolt.fill") }
                            .buttonStyle(PrimaryButtonStyle(tint: c)).disabled(device.isBusy)
                    }
                    Button { save() } label: {
                        Label(PackageStore.shared.isCached(firmware) ? "Package saved for offline use" : (saving ? "Saving…" : "Save package for offline use"), systemImage: PackageStore.shared.isCached(firmware) ? "checkmark.circle" : "arrow.down.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(saving || PackageStore.shared.isCached(firmware))
                    if !saveMessage.isEmpty { Text(saveMessage).font(.system(size: 12)).foregroundStyle(Theme.textDim) }
                }

                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(text: "Facts")
                    VStack(spacing: 0) {
                        FactRow(label: "Version", value: firmware.version + (firmware.tag.map { " (\($0))" } ?? ""))
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Released", value: firmware.date?.dayText ?? "–")
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "On the hub", value: firmware.added?.dayText ?? "–")
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Installs", value: firmware.installs.map { "\($0.formatted()) via the hub" } ?? "–")
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Stars", value: firmware.stars.map { $0.formatted() } ?? "–")
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "By you", value: library.installCount(firmwareId: firmware.id) == 0 ? "never installed" : "installed \(library.installCount(firmwareId: firmware.id))×")
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Package", value: "\(firmware.sizeText) · \(firmware.pkg.split(separator: "/").last.map(String.init) ?? firmware.pkg)")
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Identity", value: firmware.product + (firmware.ident.map { " (family \($0))" } ?? ""), mono: true)
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "SHA-256", value: firmware.sha256, mono: true)
                        Divider().overlay(Theme.stroke)
                        FactRow(label: "Licence", value: firmware.licenseText)
                        if firmware.usesStockLoader {
                            Divider().overlay(Theme.stroke)
                            FactRow(label: "Loader", value: "M-VAVE's own update loader (built on the official V15)")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .card()
                }

                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(text: "Links")
                    VStack(spacing: 0) {
                        if let u = firmware.site.flatMap(URL.init) { LinkRow(icon: "globe", title: "Project page", url: u) }
                        if let u = firmware.release.flatMap(URL.init) { LinkRow(icon: "shippingbox", title: "Release", url: u) }
                        if let u = firmware.source.flatMap(URL.init) { LinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "Source code", url: u) }
                        if let u = firmware.editor.flatMap(URL.init) { LinkRow(icon: "slider.horizontal.3", title: "Web editor", url: u) }
                        if let u = firmware.play.flatMap(URL.init) { LinkRow(icon: "play.circle", title: "Play in the browser", url: u) }
                        if let u = firmware.cheat.flatMap(URL.init) { LinkRow(icon: "doc.text", title: "Cheat sheet", url: u) }
                        if let u = firmware.talk.flatMap(URL.init) { LinkRow(icon: "bubble.left.and.bubble.right", title: "Feedback to the maker", url: u) }
                        LinkRow(icon: "building.columns", title: "On the Firmware Hub", url: HubAPI.url("#\(firmware.id)"))
                    }
                    .padding(.horizontal, 14)
                    .card()
                }

                recentInstalls
            }
            .padding(16)
        }
        .hubBackground()
        .navigationTitle(firmware.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Put \(firmware.name) \(firmware.version) on your FM-1?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Install") { device.install(firmware) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((device.whoIs.map { "It replaces \($0.firmware?.name ?? $0.name). " } ?? "") + "The new firmware may not read the old one's projects: a Felucca or SLOOP firmware is backed up first when that setting is on.")
        }
    }

    private var recentInstalls: some View {
        let mine = library.history.filter { $0.firmwareId == firmware.id }.prefix(5)
        return Group {
            if !mine.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(text: "Your installs")
                    VStack(spacing: 0) {
                        ForEach(Array(mine)) { r in
                            HStack {
                                Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.success ? Theme.ok : Theme.err)
                                Text(r.version).font(.system(size: 14, design: .rounded))
                                Spacer()
                                Text(r.date.shortText).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textFaint)
                            }.padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 14)
                    .card()
                }
            }
        }
    }

    private func save() {
        saving = true
        saveMessage = ""
        Task {
            do {
                _ = try await PackageStore.shared.package(for: firmware)
                saveMessage = "Saved in Files › On My iPhone › FM-1 Hub › Packages."
            } catch {
                saveMessage = error.localizedDescription
            }
            saving = false
        }
    }
}
