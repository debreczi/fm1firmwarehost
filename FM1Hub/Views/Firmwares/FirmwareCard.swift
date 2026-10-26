import SwiftUI

/// One firmware as a card: its screen, the facts that matter, the Install key.
struct FirmwareCard: View {
    @Environment(DeviceController.self) private var device
    let firmware: Firmware
    let installCount: Int
    let onInstall: () -> Void

    var body: some View {
        let c = Look.colour(for: firmware.id)
        let cached = PackageStore.shared.isCached(firmware)
        let onDevice = device.identity?.text == firmware.product
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: firmware) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        HubImage(url: firmware.imageURL, tint: c, wide: Look.wide.contains(firmware.id))
                            .frame(height: Look.wide.contains(firmware.id) ? 150 : 120).frame(maxWidth: .infinity).clipped()
                        HStack(spacing: 6) {
                            if onDevice { Chip(text: "on your FM-1", icon: "checkmark", tint: Theme.ok, filled: true) }
                            if firmware.beta && !firmware.isDevOnly { Chip(text: "beta", tint: Theme.warn, filled: true) }
                            if cached { Chip(text: "offline", icon: "arrow.down.circle", tint: .white) }
                        }
                        .padding(10)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(firmware.name).font(.system(size: 20, weight: .bold, design: .rounded))
                            Text(firmware.version).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(c)
                            Spacer()
                            Text("by \(firmware.author)").font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            ForEach(firmware.allKinds, id: \.self) { k in Chip(text: Kinds.label(k), icon: Kinds.icon(k), tint: k == "vintage" ? Theme.warm : c) }
                            if let h = firmware.hid, !h.kinds.isEmpty { Chip(text: "USB \(h.kinds.joined(separator: "/"))", icon: "keyboard", tint: Theme.warn) }
                        }
                        Text(firmware.what).font(.system(size: 14)).foregroundStyle(.white.opacity(0.82)).lineLimit(3).multilineTextAlignment(.leading)
                        HStack(spacing: 10) {
                            if let n = firmware.installs, n > 0 { Label(n.formatted(), systemImage: "arrow.down.to.line").help("installs via the hub") }
                            if let s = firmware.stars { Label(s.formatted(), systemImage: "star") }
                            if let d = firmware.date { Label(d.dayText, systemImage: "calendar") }
                            Text(firmware.sizeText)
                            if installCount > 0 { Label("\(installCount)× by you", systemImage: "iphone") }
                        }
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                if firmware.needsOwnInstaller, let u = firmware.install.flatMap(URL.init) {
                    Link(destination: u) { Label("Install with its own installer", systemImage: "arrow.up.right.square") }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(action: onInstall) { Label(onDevice ? "Install again" : "Install", systemImage: "bolt.fill") }
                        .buttonStyle(PrimaryButtonStyle(tint: c)).disabled(device.isBusy)
                }
                NavigationLink(value: firmware) { Image(systemName: "info.circle").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 42) }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 48)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .card(tint: c)
    }
}
