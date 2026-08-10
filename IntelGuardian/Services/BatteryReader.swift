import Foundation
#if os(macOS)
import IOKit
import IOKit.ps
#endif
#if os(iOS)
import UIKit
#endif

/// Reads battery state. Battery charge level works everywhere; temperature is
/// read on macOS from the AppleSmartBattery IORegistry node ("Temperature" in
/// deci-Kelvin) and is unavailable on iOS (no public API).
enum BatteryReader {
    #if os(iOS)
    /// Cache so we keep returning the last known level once the device reports
    /// it, instead of -1 forever if a single read races the monitoring setup.
    private static var cachedLevel: Double = -1
    private static var monitoringConfigured = false

    /// Enables battery monitoring once and keeps it on. Safe to call repeatedly.
    static func configureMonitoring() {
        guard !monitoringConfigured else { return }
        monitoringConfigured = true
        UIDevice.current.isBatteryMonitoringEnabled = true
    }
    #endif

    static func batteryLevel() -> Double {
        #if os(iOS)
        configureMonitoring()

        // iOS simulators have no real battery — UIDevice always returns -1.
        // Fall back to a simulated level so UI / testing work out of the box.
        #if targetEnvironment(simulator)
        return simulatedLevel()
        #endif

        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            cachedLevel = Double(level)
            return cachedLevel
        }
        return cachedLevel
        #else
        return macLevel()
        #endif
    }

    static func batteryTemperature() -> Double? {
        #if os(macOS)
        return macTemperature()
        #else
        return nil
        #endif
    }

    /// Whether the battery is currently charging. Returns nil if unknown.
    static func isCharging() -> Bool? {
        #if os(iOS)
        configureMonitoring()

        #if targetEnvironment(simulator)
        return simulatedIsCharging()
        #endif

        switch UIDevice.current.batteryState {
        case .charging: return true
        case .full: return true   // at 100% and plugged in; treat as charging
        case .unplugged, .unknown: return false
        @unknown default: return false
        }
        #else
        return macIsCharging()
        #endif
    }

    // ── Simulator defaults ─────────────────────────────────────────────────
    // Unless overridden via env vars, the simulator reports ~85% battery and
    // not charging — enough to verify the UI without false alerts.

    #if os(iOS) && targetEnvironment(simulator)
    private static func simulatedLevel() -> Double {
        if let raw = ProcessInfo.processInfo.environment["SIMULATOR_BATTERY_LEVEL"],
           let val = Double(raw), val >= 0, val <= 1 {
            return val
        }
        return 0.85
    }

    private static func simulatedIsCharging() -> Bool {
        if let raw = ProcessInfo.processInfo.environment["SIMULATOR_BATTERY_CHARGING"] {
            return raw.lowercased() == "true" || raw == "1"
        }
        return false
    }
    #endif

    #if os(macOS)
    private static func macIsCharging() -> Bool? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            // "Power Source State" tells whether the Mac is plugged into AC or
            // running on battery. This is the authoritative signal for "on AC
            // power": "Is Charging" only means charging is in progress right now
            // and turns false once full, which would mislabel a plugged-in Mac
            // as on battery.
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
            if let charging = info[kIOPSIsChargingKey] as? Bool {
                return charging
            }
        }
        return nil
    }
    private static func macLevel() -> Double {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return -1
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int,
               let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Double(capacity) / Double(max)
            }
        }
        return -1
    }

    /// Battery temperature in °C from the AppleSmartBattery IORegistry node.
    private static func macTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            // Fall back to the SMC BT0T key.
            return SMCReader.batteryTemperature()
        }
        defer { IOObjectRelease(service) }
        guard let node = IORegistryEntryCreateCFProperty(
            service, "Temperature" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Int else {
            return SMCReader.batteryTemperature()
        }
        return Double(node) / 10.0 - 273.15
    }
    #endif
}
