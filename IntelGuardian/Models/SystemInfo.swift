import Foundation
import Darwin

/// Aggregates the latest readable system values. Values that cannot be read
/// (e.g. CPU temperature on iOS) come back as nil.
struct SystemInfo: Sendable {

    /// System boot time, read via sysctl(KERN_BOOTTIME). Works on iOS and macOS;
    /// nil only if the sysctl call fails.
    static var bootDate: Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }
    var cpuTemp: Double?
    var batteryTemp: Double?
    var batteryLevel: Double
    var thermalState: ThermalStateLevel?
    var isCharging: Bool?

    static func current() -> SystemInfo {
        SystemInfo(
            cpuTemp: readCPUTemp(),
            batteryTemp: BatteryReader.batteryTemperature(),
            batteryLevel: BatteryReader.batteryLevel(),
            thermalState: readThermalState(),
            isCharging: BatteryReader.isCharging()
        )
    }

    private static func readCPUTemp() -> Double? {
        #if os(macOS)
        return SMCReader.cpuTemperature()
        #else
        return nil
        #endif
    }

    private static func readThermalState() -> ThermalStateLevel? {
        #if os(iOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
        #else
        return nil
        #endif
    }
}
