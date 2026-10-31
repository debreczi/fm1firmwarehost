import SwiftUI

/// The first-launch warning: full screen, with the whole app behind it until the user accepts it once.
struct DisclaimerView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        GeometryReader { screen in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Use at your own risk", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Installing firmware can leave your FM-1 not working any more. The makers of this app take no responsibility for any damage to your device, and are not associated with M-VAVE or The FM-1 Firmware Hub.")
                        .font(.system(size: 17))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only continue if you understand and accept this.")
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        settings.disclaimerAccepted = true
                    } label: { Text("I understand and accept the risk").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle(tint: .white))
                }
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: screen.size.height)
            }
        }
        .background(Color(hex: "#c62828").ignoresSafeArea())
    }
}
