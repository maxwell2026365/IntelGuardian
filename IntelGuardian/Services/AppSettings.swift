import Foundation
import Combine

/// App-wide user configuration, persisted to UserDefaults with the SMTP
/// password held in the Keychain. ObservableObject so the UI reacts to changes.
///
/// Properties are backed by stored Swift properties and synced to UserDefaults on write.
final class AppSettings: ObservableObject {
    enum Keys {
        static let smtpHost = "smtpHost"
        static let smtpPort = "smtpPort"
        static let smtpUser = "smtpUser"
        static let smtpSender = "smtpSender"
        static let recipient = "recipient"
        static let highBatteryTemp = "highBatteryTemp"
        static let thermalStateThreshold = "thermalStateThreshold"
        static let notifyBatteryTemp = "notifyBatteryTemp"
        static let notifyThermalState = "notifyThermalState"
        static let notifyCharge80 = "notifyCharge80"
        static let notifyCharge20 = "notifyCharge20"
        static let monitoringEnabled = "monitoringEnabled"
    }

    private let defaults: UserDefaults
    private let keychainPasswordKey = "smtpPassword"

    @Published var smtpHost: String
    @Published var smtpPort: Int
    @Published var smtpUser: String
    @Published var smtpPassword: String
    @Published var smtpSender: String
    @Published var recipient: String
    @Published var highBatteryTemp: Double
    @Published var notifyBatteryTemp: Bool
    @Published var notifyThermalState: Bool
    @Published var notifyCharge80: Bool
    @Published var notifyCharge20: Bool
    @Published var monitoringEnabled: Bool

    @Published var thermalStateThresholdRaw: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        smtpHost = defaults.string(forKey: Keys.smtpHost) ?? ""
        smtpPort = defaults.object(forKey: Keys.smtpPort) as? Int ?? 465
        smtpUser = defaults.string(forKey: Keys.smtpUser) ?? ""
        smtpPassword = KeychainStore.string(forKey: keychainPasswordKey) ?? ""
        smtpSender = defaults.string(forKey: Keys.smtpSender) ?? ""
        recipient = defaults.string(forKey: Keys.recipient) ?? ""
        highBatteryTemp = defaults.object(forKey: Keys.highBatteryTemp) as? Double ?? 40.0
        thermalStateThresholdRaw = ThermalStateLevel(rawValue: defaults.integer(forKey: Keys.thermalStateThreshold))?.rawValue ?? ThermalStateLevel.serious.rawValue
        notifyBatteryTemp = defaults.object(forKey: Keys.notifyBatteryTemp) as? Bool ?? true
        notifyThermalState = defaults.object(forKey: Keys.notifyThermalState) as? Bool ?? true
        notifyCharge80 = defaults.object(forKey: Keys.notifyCharge80) as? Bool ?? true
        notifyCharge20 = defaults.object(forKey: Keys.notifyCharge20) as? Bool ?? true
        monitoringEnabled = defaults.object(forKey: Keys.monitoringEnabled) as? Bool ?? true
    }

    var thermalStateThreshold: ThermalStateLevel {
        get { ThermalStateLevel(rawValue: thermalStateThresholdRaw) ?? .serious }
        set { thermalStateThresholdRaw = newValue.rawValue; defaults.set(newValue.rawValue, forKey: Keys.thermalStateThreshold) }
    }

    var isEmailConfigured: Bool {
        !smtpHost.isEmpty && !smtpUser.isEmpty && !smtpPassword.isEmpty && !recipient.isEmpty
    }

    /// Sync individual published changes to UserDefaults.
    func sync() {
        defaults.set(smtpHost, forKey: Keys.smtpHost)
        defaults.set(smtpPort, forKey: Keys.smtpPort)
        defaults.set(smtpUser, forKey: Keys.smtpUser)
        KeychainStore.set(smtpPassword, forKey: keychainPasswordKey)
        defaults.set(smtpSender, forKey: Keys.smtpSender)
        defaults.set(recipient, forKey: Keys.recipient)
        defaults.set(highBatteryTemp, forKey: Keys.highBatteryTemp)
        defaults.set(thermalStateThresholdRaw, forKey: Keys.thermalStateThreshold)
        defaults.set(notifyBatteryTemp, forKey: Keys.notifyBatteryTemp)
        defaults.set(notifyThermalState, forKey: Keys.notifyThermalState)
        defaults.set(notifyCharge80, forKey: Keys.notifyCharge80)
        defaults.set(notifyCharge20, forKey: Keys.notifyCharge20)
        defaults.set(monitoringEnabled, forKey: Keys.monitoringEnabled)
    }
}
