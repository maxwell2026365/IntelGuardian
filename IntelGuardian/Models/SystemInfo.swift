import Foundation

/// Aggregates the latest readable system values. Values that cannot be read
/// (e.g. CPU temperature on iOS) come back as nil.
struct SystemInfo: Sendable {
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
