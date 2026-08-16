import SwiftUI

@main
struct IntelGuardianApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var monitor: MonitorService
    #if os(macOS)
    @StateObject private var windowOnTop = WindowOnTopController()
    #endif

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: MonitorService(settings: settings))
        #if os(iOS)
        monitor.registerBackgroundRefresh()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(monitor)
                #if os(macOS)
                .frame(minWidth: 680, idealWidth: 760, minHeight: 420, idealHeight: 800)
                .onAppear {
                    windowOnTop.observe(settings)
                }
                #endif
        }
    }
}
