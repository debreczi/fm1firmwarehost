import SwiftUI

struct FirmwareListView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(DeviceController.self) private var device
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var showFilters = false
    @State private var prompt: InstallPrompt?
    @State private var path: [Firmware] = []

    private var selected: Set<String> { Set(settings.selectedKinds) }

    /// M-VAVE's own firmware comes first, unless a kind is picked (it is none) or the search is for something else.
    /// The filter for newer FM-1s keeps it: it runs on both chips.
    private var showOfficial: Bool { selected.isEmpty && OfficialFirmware.matches(query, latest: device.officialLatest) }

    private var filtered: [Firmware] {
        let q = query.lowercased().split(separator: " ").map(String.init)
        var list = catalog.firmwares.filter { f in
            if !settings.showBetas && f.beta && !f.isDevOnly { return false }
            if !settings.showDevOnly && f.isDevOnly { return false }
            if settings.newerChipOnly && f.chipSupport != .new { return false }
            for g in Kinds.groups {
                let ticked = g.kinds.map(\.key).filter { selected.contains($0) }
                if !ticked.isEmpty && !ticked.contains(where: { f.allKinds.contains($0) }) { return false }
            }
            if !q.isEmpty {
                let t = f.searchText
                if !q.allSatisfy({ t.contains($0) }) { return false }
            }
            return true
        }
        switch settings.sort {
        case .installs: list.sort { ($0.installs ?? 0, $0.stars ?? -1) > ($1.installs ?? 0, $1.stars ?? -1) }
        case .newest: list.sort { ($0.published ?? $0.date ?? "") > ($1.published ?? $1.date ?? "") }
        case .added: list.sort { ($0.added ?? "") > ($1.added ?? "") }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .stars: list.sort { ($0.stars ?? -1, $0.installs ?? 0) > ($1.stars ?? -1, $1.installs ?? 0) }
        }
        return list
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    header
                    if showOfficial { OfficialFirmwareCard { latest in prompt = .official(latest: latest, device: device) } }
                    if catalog.firmwares.isEmpty {
                        if catalog.loading { ProgressView("Loading the catalogue…").padding(40) }
                        else { EmptyState(icon: "wifi.exclamationmark", title: "No catalogue yet", text: catalog.error ?? "Pull to refresh.") }
                    } else if filtered.isEmpty {
                        // when the official card above matches, that is the answer
                        if !showOfficial { EmptyState(icon: "line.3.horizontal.decrease.circle", title: "Nothing matches", text: "Loosen the filters or the search.") }
                    } else if settings.gridView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { f in
                                NavigationLink(value: f) { FirmwareTile(firmware: f) }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(filtered) { f in
                            FirmwareCard(firmware: f, installCount: library.installCount(firmwareId: f.id)) { ask(f) }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .hubBackground()
            .scrollContentBackground(.hidden)
            .refreshable { device.checkOfficialOnce(); await catalog.refresh(force: true) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search name, maker, what it does")
            .navigationTitle("Firmwares")
            .navigationDestination(for: Firmware.self) { FirmwareDetailView(firmware: $0) }
            .onChange(of: catalog.firmwares.count, initial: true) { _, _ in
                if Demo.isOn, path.isEmpty, let id = Demo.open, let f = catalog.firmware(id: id) { path = [f] }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $settings.sort) {
                            ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                        }
                        Divider()
                        Toggle("Show betas", isOn: $settings.showBetas)
                        Toggle("Show developer bases", isOn: $settings.showDevOnly)
                        Toggle("Grid view", isOn: $settings.gridView)
                    } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                    Button { showFilters = true } label: {
                        Image(systemName: selected.isEmpty && !settings.newerChipOnly ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                FilterSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .installPrompt($prompt) { settings.newerChipOnly = true }
            .onAppear { device.checkOfficialOnce() }   // the official card's version
        }
    }

    private func ask(_ f: Firmware) {
        prompt = InstallPrompt(title: "Put \(f.name) on your FM-1?", message: confirmMessage(f), confirm: "Install \(f.name) \(f.version)",
                               verdict: device.chipVerdict(f.chipSupport)) { consent in device.install(f, consent: consent) }
    }

    private func confirmMessage(_ f: Firmware) -> String {
        var s = "\(f.sizeText), by \(f.author). "
        if let w = device.whoIs { s += "It replaces \(w.firmware?.name ?? w.name). " }
        s += settings.autoSnapshotBeforeInstall
            ? "The music of a Felucca or SLOOP firmware is backed up first. On a firmware built on SLOOP the app can't put it back, and on others it saves none: save your work with their own tool first."
            : "Saved what you want to keep? The new firmware may not read the old one's projects."
        return s
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DevicePill()
                Spacer()
                if !device.isConnected {
                    Button { device.connect() } label: { Label("Connect", systemImage: "bolt.fill").font(.system(size: 13, weight: .semibold, design: .rounded)) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).disabled(device.isBusy)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    kindChip(key: nil, label: "All", icon: "square.grid.2x2")
                    ForEach(Kinds.groups) { g in
                        ForEach(g.kinds, id: \.key) { k in kindChip(key: k.key, label: k.label, icon: Kinds.icon(k.key)) }
                    }
                }
                .padding(.vertical, 2)
            }
            if settings.newerChipOnly {
                Button { settings.newerChipOnly = false } label: {
                    Label("Only firmwares that work on newer FM-1s too", systemImage: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ok)
            }
            HStack {
                Text("\(filtered.count) of \(catalog.firmwares.count) firmwares")
                if let u = catalog.updated { Text("· catalogue \(u)") }
                Spacer()
                Text(settings.sort.label)
            }
            .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textFaint)
        }
    }

    private func kindChip(key: String?, label: String, icon: String) -> some View {
        let on = key == nil ? selected.isEmpty : selected.contains(key!)
        return Button {
            if let k = key {
                if selected.contains(k) { settings.selectedKinds.removeAll { $0 == k } } else { settings.selectedKinds.append(k) }
            } else { settings.selectedKinds = [] }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(on ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(on ? Theme.accent : Theme.surfaceRaised).overlay(Capsule().strokeBorder(on ? .clear : Theme.stroke)))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Catalogue and packages from The FM-1 Firmware Hub. Each firmware is its maker's: the hub and this app do not review what a firmware does.")
            Link("thefirmwarehub.com", destination: HubAPI.site)
        }
        .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textFaint).multilineTextAlignment(.center)
        .padding(.top, 12)
    }
}

/// A compact tile for the grid view.
struct FirmwareTile: View {
    let firmware: Firmware
    var body: some View {
        let c = Look.colour(for: firmware.id)
        VStack(alignment: .leading, spacing: 8) {
            HubImage(url: firmware.imageURL, tint: c)
                .frame(height: 96).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(firmware.name).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
            Text("\(firmware.version) · \(firmware.author)").font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
            HStack(spacing: 4) {
                ForEach(firmware.allKinds.prefix(2), id: \.self) { Chip(text: Kinds.label($0), tint: c) }
                if firmware.beta { Chip(text: "beta", tint: Theme.warn) }
            }
        }
        .padding(10)
        .card(tint: c)
    }
}

