import SwiftUI

/// An install the user is asked to confirm, with what the flash chip check says about it. `run` is called with what
/// the user agreed to, which the device layer checks again before anything is written.
struct InstallPrompt: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirm: String
    var verdict: ChipVerdict
    var run: @MainActor (ChipVerdict) -> Void
}

extension InstallPrompt {
    /// M-VAVE's own firmware: the current release from m-vave.com (`latest`) or the V15 recovery image from the hub.
    /// The same question on the FM-1 tab and the Firmwares tab.
    @MainActor
    static func official(latest: Bool, device: DeviceController) -> InstallPrompt {
        InstallPrompt(title: latest ? "Install M-VAVE's current firmware\(device.officialLatestVersion.map { " (\($0))" } ?? "")?" : "Back to the official V15?",
                      message: latest
                          ? "The file M-VAVE publishes on m-vave.com, fetched now; its identity is read from the file before anything is written."
                          : "M-VAVE's own FM-1 V15 as the hub serves it: the recovery image, checked byte for byte (SHA-256) before anything is written.",
                      confirm: latest ? "Install the latest official" : "Install V15",
                      verdict: device.chipVerdict(.official)) { consent in device.installOfficial(latest: latest, consent: consent) }
    }
}

extension View {
    /// Asks before an install: the usual confirmation when the flash chip check has nothing to say, a red warning sheet
    /// when it warns or the install is dangerous, and a refusal otherwise. `showSafe` opens the firmwares that work on
    /// newer FM-1s too.
    func installPrompt(_ prompt: Binding<InstallPrompt?>, showSafe: @escaping () -> Void) -> some View {
        modifier(InstallPromptModifier(prompt: prompt, showSafe: showSafe))
    }
}

private struct InstallPromptModifier: ViewModifier {
    @Binding var prompt: InstallPrompt?
    let showSafe: () -> Void
    /// Agreed to in the sheet: run once the sheet is gone, so that the progress sheet the install opens can show.
    @State private var agreed: InstallPrompt?

    private enum Kind { case plain, sheet, refused }

    private func kind(_ p: InstallPrompt) -> Kind {
        switch p.verdict {
        case .install: return .plain
        case .warn, .dangerous: return .sheet
        case .refused: return .refused
        }
    }

    private func shown(_ k: Kind) -> Binding<Bool> {
        Binding(get: { prompt.map { kind($0) == k } ?? false }, set: { if !$0 { prompt = nil } })
    }

    private var sheetPrompt: Binding<InstallPrompt?> {
        Binding(get: { prompt.flatMap { kind($0) == .sheet ? $0 : nil } }, set: { if $0 == nil { prompt = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(prompt?.title ?? "", isPresented: shown(.plain), titleVisibility: .visible, presenting: prompt) { p in
                Button(p.confirm) { p.run(.install) }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                Text(p.message)
            }
            .sheet(item: sheetPrompt, onDismiss: {
                if let p = agreed { agreed = nil; p.run(p.verdict) }
            }) { p in
                ChipWarningSheet(prompt: p, cancel: { prompt = nil }, confirm: { agreed = p; prompt = nil })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert(ChipGuard.heading(prompt?.verdict ?? .install), isPresented: shown(.refused), presenting: prompt) { _ in
                Button("OK", role: .cancel) {}
                Button("Show safe firmwares") { showSafe() }
            } message: { p in
                Text(ChipGuard.text(p.verdict))
            }
    }
}

/// The red warning before an install the flash chip check warns about, or a dangerous one. Cancel (No) is the
/// prominent button.
struct ChipWarningSheet: View {
    let prompt: InstallPrompt
    let cancel: () -> Void
    let confirm: () -> Void

    private var dangerous: Bool {
        if case .dangerous = prompt.verdict { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(ChipGuard.heading(prompt.verdict), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.err)
                    Text(ChipGuard.text(prompt.verdict))
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.err.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.err, lineWidth: 2))
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt.title).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(prompt.message).font(.system(size: 13)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button(dangerous ? "No" : "Cancel", action: cancel)
                        .buttonStyle(PrimaryButtonStyle(tint: .white))
                        .keyboardShortcut(.defaultAction)
                    Button(dangerous ? "Yes, install" : "Install anyway", role: .destructive, action: confirm)
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.err))
                }
            }
            .padding(20)
        }
        .hubBackground()
    }
}
