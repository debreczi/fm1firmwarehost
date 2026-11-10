import SwiftUI

/// What finds M-VAVE's own firmware on the Firmwares tab.
enum OfficialFirmware {
    /// Does a search find it? Every word must be in what people call it, its identities and versions included (`latest`
    /// is the current release's identity, "FM-1_016"): an empty search does.
    static func matches(_ query: String, latest: String?) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let current = latest.map { "\($0) \(FWSCPackage.officialVersion(of: $0) ?? "")" } ?? ""
        let text = "official firmware m-vave mvave stock original factory recovery fm-1_015 v15 \(current)".lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

/// M-VAVE's own firmware, first on the Firmwares tab: the current release from m-vave.com and the V15 recovery image
/// the hub keeps, the same two as on the FM-1 tab. Both run on every FM-1, the newer chip too.
struct OfficialFirmwareCard: View {
    @Environment(DeviceController.self) private var device
    /// `true` for the current release, `false` for V15.
    let onInstall: (_ latest: Bool) -> Void

    private var tint: Color { Color(hex: "#9aa4b2") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Official firmware").font(.system(size: 20, weight: .bold, design: .rounded))
                    if let v = device.officialLatestVersion {
                        Text(v).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(tint)
                    }
                    Spacer()
                    Text("by M-VAVE").font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                ChipSupportChip(support: .official)
                Text("M-VAVE's own firmware. The latest comes straight from M-VAVE's download server, so a new version shows up here without an app update. V15 is the known-good image the hub keeps for getting back to stock.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                Button { onInstall(true) } label: {
                    Label(device.officialLatestVersion.map { "Install the latest official (\($0))" } ?? (device.officialChecking ? "Checking m-vave.com…" : "Install the latest official"), systemImage: "checkmark.seal")
                }
                .buttonStyle(PrimaryButtonStyle(tint: tint)).disabled(device.isBusy)
                Button { onInstall(false) } label: { Label("Back to V15 (recovery image)", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(device.isBusy)
            }
        }
        .padding(14)
        .card(tint: tint)
    }
}
