import SwiftUI

struct FilterSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                ForEach(Kinds.groups) { g in
                    Section {
                        ForEach(g.kinds, id: \.key) { k in
                            Button {
                                if settings.selectedKinds.contains(k.key) { settings.selectedKinds.removeAll { $0 == k.key } }
                                else { settings.selectedKinds.append(k.key) }
                            } label: {
                                HStack {
                                    Label(k.label, systemImage: Kinds.icon(k.key)).foregroundStyle(.white)
                                    Spacer()
                                    if settings.selectedKinds.contains(k.key) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                            }
                        }
                    } header: { Text(g.title) } footer: {
                        Text(g.id == "type" ? "Within a group any ticked one matches; between the groups all must." : "")
                    }
                }
                Section("Show") {
                    Toggle("Betas", isOn: $settings.showBetas)
                    Toggle("Developer bases (a base to build on)", isOn: $settings.showDevOnly)
                }
                Section("Sort") {
                    Picker("Sort", selection: $settings.sort) { ForEach(SortOrder.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline).labelsHidden()
                }
            }
            .scrollContentBackground(.hidden)
            .hubBackground()
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Clear") { settings.selectedKinds = [] } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
    }
}
