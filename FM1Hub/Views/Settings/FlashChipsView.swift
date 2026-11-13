import SwiftUI

/// What the app checks before an install on a newer FM-1, and why. The README has the same text: change both together.
struct FlashChipsView: View {
    var body: some View {
        List {
            Section {
                Text("FM-1s are made with two different flash chips. A firmware written before the newer chip can't save or start another update on it, so the FM-1 is stuck on that firmware (bricked) until it is rescued from a computer.")
            }

            Section {
                ForEach(FlashChip.known) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(FlashChip.hex(c.id)).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        Text(c.part).font(.system(size: 13, weight: .medium, design: .rounded))
                        Text(c.units).font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("The chips the app knows") } footer: { Text("The JEDEC ID each chip answers with.") }

            Section {
                Text("Only from the firmware running on the FM-1, when it reports its chip: some community firmwares send the chip's ID in bytes 24 to 26 of their answer to the identity request. Connect one FM-1 at a time: the app stops when another one answers, but while an FM-1 restarts during an update it can't tell it from another plugged into the same port. M-VAVE's own firmware never reports it, so most of the time the chip is not reported, and the app can't tell a newer FM-1 from a first one.")
            } header: { Text("How the app learns the chip") }

            Section {
                Text("The FM-1 Firmware Hub reads from each package which chips it works on and lists it in its catalogue: every FM-1 with the newer chip too, the first FM-1s only, or a firmware that doesn't check the chip. M-VAVE's own firmware works on both: the V15 the hub keeps, and what the app fetched from M-VAVE's server. A package the catalogue doesn't list counts as the hub said of it when the app last read the catalogue, and is otherwise unknown. If the catalogue stops rating a package, only “the first FM-1s only” is kept. A backup or an interrupted update that says “the first FM-1s only” counts too when nothing else is known: it can only make the check stricter.")
            } header: { Text("Which firmwares work on it") }

            Section {
                rule("Reports \(FlashChip.hex(FlashChip.first))", "Every firmware installs.")
                rule("Reports \(FlashChip.hex(FlashChip.newer))", "A firmware for the first FM-1s only is refused, or, with Allow installing on unsafe FM-1s on, asked about as dangerous. An unknown one gets a red warning. The rest install.")
                rule("Reports another ID", "A firmware for the first FM-1s only is treated as above. One made for the newer chip, M-VAVE's own and an unknown one get a red warning. One that doesn't check the chip installs.")
                rule("Doesn't report it", "A firmware for the first FM-1s only and an unknown one get a red warning. The rest install.")
            } header: { Text("What the app does") } footer: { Text("The same applies to restoring a backup, installing a file or M-VAVE's firmware, and Resume. The check runs again just before anything is written, with what the FM-1 reports then.") }

            Section {
                Text("A bricked FM-1 can almost always be rescued, but only from a computer: iOS can't do it.")
                Link("The hub's rescue page", destination: HubAPI.rescue)
            } header: { Text("If it happens") }
        }
        .font(.system(size: 14))
        .scrollContentBackground(.hidden)
        .hubBackground()
        .navigationTitle("Flash chips")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rule(_ when: String, _ what: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(when).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(what).font(.footnote).foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 2)
    }
}
