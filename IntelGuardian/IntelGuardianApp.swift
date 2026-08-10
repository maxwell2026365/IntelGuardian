import SwiftUI

@main
struct IntelGuardianApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var monitor: MonitorService

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: MonitorService(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(monitor)
                #if os(macOS)
                .frame(minWidth: 680, idealWidth: 680, minHeight: 420, idealHeight: 420)
                #endif
        }
    }
}
