import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var monitor: MonitorService

    var body: some View {
        Group {
            if #available(iOS 16.0, macOS 13.0, *) {
                modernTabs
            } else {
                legacyTabs
            }
        }
        .task {
            ensureMonitor()
        }
    }

    private func ensureMonitor() {
        guard !monitor.isMonitoring, settings.monitoringEnabled else { return }
        monitor.start()
    }

    // MARK: - iOS 16+ / macOS 13+ (NavigationStack)
    @available(iOS 16.0, macOS 13.0, *)
    private var modernTabs: some View {
        TabView {
            NavigationStack {
                DashboardView(monitor: monitor, settings: settings)
            }
            .tabItem {
                Label("概览", systemImage: "gauge")
            }

            NavigationStack {
                SettingsView(settings: settings, monitor: monitor)
            }
            .tabItem {
                Label("设置", systemImage: "gear")
            }
        }
    }

    // MARK: - iOS 15 / macOS 12 fallback (NavigationView)
    // .stack is unavailable in newer SDKs; NavigationView defaults to stack on
    // iPhone anyway, and iPad / macOS are covered by the modernTabs path above.
    private var legacyTabs: some View {
        TabView {
            NavigationView {
                DashboardView(monitor: monitor, settings: settings)
            }
            .tabItem {
                Image(systemName: "gauge")
                Text("概览")
            }

            NavigationView {
                SettingsView(settings: settings, monitor: monitor)
            }
            .tabItem {
                Image(systemName: "gear")
                Text("设置")
            }
        }
    }
}

// #Preview removed — SwiftUI Previews need iOS 15+ compatible setup.
