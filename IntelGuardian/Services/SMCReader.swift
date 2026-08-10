#if os(macOS)
import Foundation
import Darwin

// SMC command codes (kern SMC_CMD_*).
private let SMC_CMD_READ_KEYINFO: UInt8 = 9
private let SMC_CMD_READ_BYTES: UInt8 = 5
private let KERNEL_INDEX_SMC: UInt32 = 2

// MARK: - SMC helpers (macOS only)

/// Reads temperatures from Apple's System Management Controller via IOKit.
/// Works on both Intel and Apple Silicon Macs. The AppleSMC user-client struct
/// must match the C layout exactly (80 bytes), otherwise the kernel rejects the
/// call — see the explicit padding fields below.
enum SMCReader {
    // Key naming conventions:
    //  - "Tp*"  -> CPU performance cores (Apple Silicon)
    //  - "Te*"  -> efficiency cores / ANE (Apple Silicon)
    //  - "Th*"  -> "high" / near-CPU sensors
    //  - "TC*"  -> Intel CPU core / SoC
    //  - "Ts*P" -> SoC / system power sensors
    //  - "Tf*"  -> fan-adjacent sensors
    private static let cpuKeys = [
        // Apple Silicon performance-core sensors.
        "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08", "Tp09", "Tp0A",
        "Tp0B", "Tp0C", "Tp0D", "Tp0E", "Tp0F",
        // Efficiency cores / ANE.
        "Te01", "Te02", "Te03", "Te04", "Te05", "Te06",
        // Near-CPU / SoC sensors.
        "Th00", "Th01", "Th02", "Th04", "Th05", "Th06", "Th08", "Th09", "Th0A", "Th0C",
        "Ts0P", "TS0P",
        // Intel keys (unused on Apple Silicon, harmless).
        "TC0P", "TC0F", "TC0D", "TC0H", "TC0G", "TC0C", "TC0E", "TC0J",
        "TC1P", "TC2P", "TC3P", "TC4P", "TC5P", "TC6P", "TC7P", "TC8P",
        "TC01", "TC02", "TC03", "TC04", "TC05", "TC06", "TC07", "TC08",
        "Tp0P", "Tp09", "Tp0A", "Tp0T", "TN0P", "TN0D", "TN0E", "TN0F",
    ]

    // MARK: - SMC structs (must match C layout exactly)

    private struct SMCKeyData {
        var key: UInt32 = 0
        var versMajor: UInt8 = 0
        var versMinor: UInt8 = 0
        var versBuild: UInt8 = 0
        var versReserved: UInt8 = 0
        var versRelease: UInt16 = 0
        var pLimitVersion: UInt16 = 0
        var pLimitLength: UInt16 = 0
        var pLimitCPU: UInt32 = 0
        var pLimitGPU: UInt32 = 0
        var pLimitMem: UInt32 = 0
        var keyInfoDataSize: UInt32 = 0
        var keyInfoDataType: UInt32 = 0
        var keyInfoDataAttributes: UInt8 = 0
        var keyInfoPadding: (UInt8, UInt8, UInt8) = (0, 0, 0) // C padding
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data8Padding: UInt8 = 0 // align data32
        var data32: UInt32 = 0
        var bytes: SMCBytes = SMCBytes()
    }

    private struct SMCBytes {
        var b0: UInt8 = 0; var b1: UInt8 = 0; var b2: UInt8 = 0; var b3: UInt8 = 0
        var b4: UInt8 = 0; var b5: UInt8 = 0; var b6: UInt8 = 0; var b7: UInt8 = 0
        var b8: UInt8 = 0; var b9: UInt8 = 0; var b10: UInt8 = 0; var b11: UInt8 = 0
        var b12: UInt8 = 0; var b13: UInt8 = 0; var b14: UInt8 = 0; var b15: UInt8 = 0
        var b16: UInt8 = 0; var b17: UInt8 = 0; var b18: UInt8 = 0; var b19: UInt8 = 0
        var b20: UInt8 = 0; var b21: UInt8 = 0; var b22: UInt8 = 0; var b23: UInt8 = 0
        var b24: UInt8 = 0; var b25: UInt8 = 0; var b26: UInt8 = 0; var b27: UInt8 = 0
        var b28: UInt8 = 0; var b29: UInt8 = 0; var b30: UInt8 = 0; var b31: UInt8 = 0
    }

    // MARK: - Connection

    private static var conn: io_connect_t = 0
    private static var openAttempted = false

    static func connect() -> Bool {
        if openAttempted { return conn != 0 }
        openAttempted = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return false }
        // Validate the connection with a key-info read. REV returns size 0 on
        // Apple Silicon, so probe a temperature key instead.
        return readRawKeyInfo("Tp01") != nil || readRawKeyInfo("TC0P") != nil
    }

    private static var structSize: Int { MemoryLayout<SMCKeyData>.size }

    private static func readRawKeyInfo(_ key: String) -> SMCKeyData? {
        guard key.count == 4, connect() else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = SMC_CMD_READ_KEYINFO
        let size = structSize
        var outSize = size
        let status = withUnsafeMutablePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, inPtr, size, outPtr, &outSize)
            }
        }
        guard status == KERN_SUCCESS, output.keyInfoDataSize > 0 else { return nil }
        return output
    }

    private static func readRaw(_ key: String) -> Data? {
        guard let info = readRawKeyInfo(key) else { return nil }
        let dataSize = Int(info.keyInfoDataSize)
        guard dataSize > 0 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfoDataSize = UInt32(dataSize)
        input.data8 = SMC_CMD_READ_BYTES
        let size = structSize
        var outSize = size
        let status = withUnsafeMutablePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, inPtr, size, outPtr, &outSize)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let count = min(dataSize, 32)
        var bytes = [UInt8](repeating: 0, count: count)
        withUnsafeBytes(of: &output.bytes) { raw in
            for i in 0..<count { bytes[i] = raw[i] }
        }
        return Data(bytes)
    }

    private static func fourCC(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Temperature in °C from an SMC "flt " (4-byte float) value, or nil.
    static func temperature(forKey key: String) -> Double? {
        guard let data = readRaw(key), data.count >= 4 else { return nil }
        let bits = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let value = Double(Float(bitPattern: bits))
        guard value.isFinite, value >= -20, value <= 150 else { return nil }
        return value
    }

    /// CPU die temperature in °C, averaged over the keys that exist.
    static func cpuTemperature() -> Double? {
        guard connect() else { return nil }
        var values: [Double] = []
        for key in cpuKeys {
            if let value = temperature(forKey: key) {
                values.append(value)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Battery temperature in °C from the SMC (BT0T), or nil. Most Macs expose
    /// battery temperature via the AppleSmartBattery IORegistry node instead;
    /// see BatteryReader.
    static func batteryTemperature() -> Double? {
        temperature(forKey: "BT0T")
    }
}
#endif
