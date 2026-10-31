import SwiftUI

/// A firmware's picture from the hub (its own screen), with a tinted placeholder.
struct HubImage: View {
    let url: URL?
    let tint: Color
    var wide = false

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder(icon: "waveform")
            case .empty:
                placeholder(icon: nil)
            @unknown default:
                placeholder(icon: nil)
            }
        }
    }

    private func placeholder(icon: String?) -> some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let icon = icon { Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(tint.opacity(0.7)) }
            else { ProgressView().tint(tint) }
        }
    }
}

/// One row of a facts table.
struct FactRow: View {
    let label: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.textFaint).frame(width: 96, alignment: .leading)
            Text(value).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 14, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Said out loud when the history and backup list could not be read or written: an empty list that is only empty
/// because of a file error must never look like an empty list that is simply empty.
struct LibraryProblemCard: View {
    let notice: LibraryNotice
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(notice.kind == .rescue ? "The saved list could not be read" : "The saved list could not be written",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.warn)
            Text(notice.text).font(.system(size: 13)).foregroundStyle(Theme.textDim)
            if notice.dismissible {
                Button("I have the file, put this away", action: onDismiss)
                    .buttonStyle(.bordered).controlSize(.small).font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(tint: Theme.warn)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textFaint)
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

/// A link row: an icon, a name, out to Safari.
struct LinkRow: View {
    let icon: String
    let title: String
    let url: URL
    var body: some View {
        Link(destination: url) {
            HStack {
                Image(systemName: icon).frame(width: 22).foregroundStyle(Theme.accent)
                Text(title).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: 15, design: .rounded))
            .padding(.vertical, 10)
        }
    }
}

/// The identity pill: "On your FM-1: Felucca 1.6.1".
struct DevicePill: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(device.isConnected ? Theme.ok : Theme.textFaint).frame(width: 8, height: 8)
                .shadow(color: device.isConnected ? Theme.ok.opacity(0.8) : .clear, radius: 4)
            if let id = device.identity {
                let w = device.whoIs
                Text("On your FM-1: ").foregroundStyle(Theme.textDim) +
                Text(w?.firmware?.name ?? w?.name ?? id.text).fontWeight(.semibold) +
                Text(w?.firmware != nil ? (w?.exact == true ? " \(w!.firmware!.version)" : " (another version: \(id.text))") : "").foregroundStyle(Theme.textDim)
            } else {
                Text(device.phase == .connecting ? "Looking for the FM-1…" : "Not connected").foregroundStyle(Theme.textDim)
            }
        }
        .font(.system(size: 13, design: .rounded))
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Theme.surfaceRaised).overlay(Capsule().strokeBorder(Theme.stroke)))
    }
}
