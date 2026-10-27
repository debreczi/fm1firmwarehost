import SwiftUI

/// The progress of an install, backup or restore: the firmware, the step, the bar, then the result and what to do next.
struct JobSheet: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        VStack(spacing: 18) {
            if let j = device.job {
                HStack(spacing: 14) {
                    if let u = j.imageURL {
                        HubImage(url: u, tint: j.colour).frame(width: 72, height: 54).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(j.colour.opacity(0.18)).frame(width: 72, height: 54)
                            Image(systemName: icon(for: j.kind)).font(.system(size: 22)).foregroundStyle(j.colour)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(j.title).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(2)
                        Text(j.subtitle).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(2)
                    }
                    Spacer()
                }

                if j.finished {
                    VStack(spacing: 10) {
                        Image(systemName: j.success ? "checkmark.circle.fill" : "xmark.octagon.fill").font(.system(size: 48)).foregroundStyle(j.success ? Theme.ok : Theme.err)
                        Text(j.message).font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9))
                        if !j.hint.isEmpty { Text(j.hint).font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(Theme.textDim) }
                    }
                    .padding(.vertical, 8)
                    Button("Done") { device.dismissJob() }.buttonStyle(PrimaryButtonStyle(tint: j.colour))
                } else {
                    if writes(j.kind) {
                        HStack(spacing: 12) {
                            Image(systemName: "cable.connector.slash").font(.system(size: 28, weight: .bold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DO NOT UNPLUG YOUR FM-1").font(.system(size: 18, weight: .heavy, design: .rounded))
                                Text("Keep it connected and keep this app open until it says Done.").font(.system(size: 13, weight: .medium))
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "#d32f2f")))
                    }
                    VStack(spacing: 10) {
                        HStack {
                            ProgressView().tint(j.colour)
                            Text(device.phase.title).font(.system(size: 16, weight: .semibold, design: .rounded))
                            Spacer()
                            if let f = device.phase.fraction { Text("\(Int(f * 100)) %").font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.textDim) }
                        }
                        ProgressView(value: device.phase.fraction ?? 0).tint(j.colour).animation(.linear(duration: 0.2), value: device.phase.fraction ?? 0)
                        Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                    }
                    .padding(14).card(tint: j.colour)
                    steps
                    Label("About a minute.", systemImage: "hourglass")
                        .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    Button("Cancel") { device.cancel() }.buttonStyle(SecondaryButtonStyle()).disabled(!cancellable)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .hubBackground()
    }

    /// Jobs that write to the FM-1 (a backup only reads it).
    private func writes(_ k: DeviceJob.Kind) -> Bool {
        switch k {
        case .install, .official, .resume, .file, .restoreFirmware, .restoreArchive: return true
        case .snapshot: return false
        }
    }

    private func icon(for k: DeviceJob.Kind) -> String {
        switch k {
        case .install, .resume, .file: return "bolt.fill"
        case .official: return "checkmark.seal"
        case .snapshot: return "externaldrive.badge.plus"
        case .restoreFirmware, .restoreArchive: return "arrow.counterclockwise"
        }
    }

    private var cancellable: Bool {
        switch device.phase {
        case .connecting, .downloading, .searching: return true
        case .installing(let s):
            switch s { case .start, .verify: return true; default: return false }
        default: return false
        }
    }

    private var detail: String {
        switch device.phase {
        case .idle: return ""
        case .connecting: return "Asking the MIDI ports which one is the FM-1."
        case .downloading(let f): return f >= 1 ? "Checking the package (SHA-256)…" : "Downloading the package and checking it."
        case .searching(let where_): return where_
        case .installing(let s):
            switch s {
            case .start(let id): return "The FM-1 (\(id)) is asked to start the update."
            case .verify(let n): return "Step 1: the running firmware reads the package header and stages the update loader (\(n) reads)."
            case .loader: return "The FM-1 restarts into the update loader. Its screen may go dark for a moment."
            case .write(let n): return "Step 2: the loader reads the whole image and writes it to flash (\(n) of about \(FM1Protocol.step2Reads) reads). Do not unplug."
            case .reboot: return "The FM-1 restarts with the new firmware."
            case .done(let id): return "Done: \(id)."
            }
        case .backingUp(let d, let t): return "Reading the music, settings, projects and samples over USB (\(ByteCountFormatter.string(fromByteCount: Int64(d), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(t), countStyle: .file))). Keep the FM-1 stopped."
        case .restoring(let d, let t): return "Writing the archive back (\(ByteCountFormatter.string(fromByteCount: Int64(d), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(t), countStyle: .file))). Keep the FM-1 stopped."
        }
    }

    private var steps: some View {
        let names = ["Find", "Package", "Check", "Loader", "Write", "Restart"]
        let current: Int = {
            switch device.phase {
            case .idle: return 0
            case .connecting: return 0
            case .downloading, .searching: return 1
            case .installing(let s):
                switch s { case .start, .verify: return 2; case .loader: return 3; case .write: return 4; case .reboot: return 5; case .done: return 6 }
            case .backingUp, .restoring: return -1
            }
        }()
        return Group {
            if current >= 0 {
                HStack(spacing: 6) {
                    ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                        VStack(spacing: 4) {
                            Capsule().fill(i < current ? Theme.ok : (i == current ? (device.job?.colour ?? Theme.accent) : Theme.surfaceRaised)).frame(height: 4)
                            Text(n).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(i <= current ? .white : Theme.textFaint)
                        }
                    }
                }
            }
        }
    }
}
