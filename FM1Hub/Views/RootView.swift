import SwiftUI

struct RootView: View {
    @Environment(DeviceController.self) private var device
    @Environment(CatalogStore.self) private var catalog
    @State private var tab = 0

    var body: some View {
        @Bindable var device = device
        TabView(selection: $tab) {
            FirmwareListView()
                .tabItem { Label("Firmwares", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            DeviceView()
                .tabItem { Label("FM-1", systemImage: "cable.connector") }
                .tag(1)
            BackupsView()
                .tabItem { Label("Backups", systemImage: "externaldrive.fill") }
                .tag(2)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .sheet(isPresented: $device.showJobSheet) {
            JobSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(device.isBusy)
        }
        .task { await catalog.refresh() }
    }
}
