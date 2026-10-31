import SwiftUI

@main
struct FM1HubApp: App {
    @State private var settings: AppSettings
    @State private var catalog: CatalogStore
    @State private var library: LibraryStore
    @State private var device: DeviceController

    init() {
        let settings = AppSettings()
        let catalog = CatalogStore()
        let library = LibraryStore()
        _settings = State(initialValue: settings)
        _catalog = State(initialValue: catalog)
        _library = State(initialValue: library)
        _device = State(initialValue: DeviceController(catalog: catalog, library: library, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(catalog)
                .environment(library)
                .environment(device)
                .task {
                    if Demo.isOn {
                        // the first launch loads the catalogue from the network: wait for it
                        for _ in 0..<60 where catalog.firmwares.isEmpty {
                            await catalog.refresh(force: true)
                            if catalog.firmwares.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
                        }
                        library.seedDemo(catalog: catalog)
                        device.seedDemo()
                    } else {
                        library.nameRecovered(using: catalog)
                    }
                }
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
