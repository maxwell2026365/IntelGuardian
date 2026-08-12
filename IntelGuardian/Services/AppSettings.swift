import Foundation
import Combine

/// App-wide user configuration, persisted to UserDefaults with the SMTP
/// password held in the Keychain. ObservableObject so the UI reacts to changes.
///
/// Each `@Published` property writes its backing value to UserDefaults on every
/// change (via `didSet`), so callers never need to call a manual `sync()`.
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
        static let windowOnTop = "windowOnTop"
    }

    private let defaults: UserDefaults
    private let keychainPasswordKey = "smtpPassword"

    @Published var smtpHost: String {
        didSet { defaults.set(smtpHost, forKey: Keys.smtpHost) }
    }
    @Published var smtpPort: Int {
        didSet { defaults.set(smtpPort, forKey: Keys.smtpPort) }
    }
    @Published var smtpUser: String {
        didSet { defaults.set(smtpUser, forKey: Keys.smtpUser) }
    }
    @Published var smtpPassword: String {
        didSet { KeychainStore.set(smtpPassword, forKey: keychainPasswordKey) }
    }
    @Published var smtpSender: String {
        didSet { defaults.set(smtpSender, forKey: Keys.smtpSender) }
    }
    @Published var recipient: String {
        didSet { defaults.set(recipient, forKey: Keys.recipient) }
    }
    @Published var highBatteryTemp: Double {
        didSet { defaults.set(highBatteryTemp, forKey: Keys.highBatteryTemp) }
    }
    @Published var thermalStateThresholdRaw: Int {
        didSet { defaults.set(thermalStateThresholdRaw, forKey: Keys.thermalStateThreshold) }
    }
    @Published var notifyBatteryTemp: Bool {
        didSet { defaults.set(notifyBatteryTemp, forKey: Keys.notifyBatteryTemp) }
    }
    @Published var notifyThermalState: Bool {
        didSet { defaults.set(notifyThermalState, forKey: Keys.notifyThermalState) }
    }
    @Published var notifyCharge80: Bool {
        didSet { defaults.set(notifyCharge80, forKey: Keys.notifyCharge80) }
    }
    @Published var notifyCharge20: Bool {
        didSet { defaults.set(notifyCharge20, forKey: Keys.notifyCharge20) }
    }
    @Published var monitoringEnabled: Bool {
        didSet { defaults.set(monitoringEnabled, forKey: Keys.monitoringEnabled) }
    }
    /// Whether the macOS window floats above other windows ("always on top").
    /// Only meaningful on macOS; ignored on iOS.
    @Published var windowOnTop: Bool {
        didSet { defaults.set(windowOnTop, forKey: Keys.windowOnTop) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Note: didSet does not fire during init, so these stored-property
        // assignments don't re-write the values we just read back.
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
        windowOnTop = defaults.object(forKey: Keys.windowOnTop) as? Bool ?? false
    }

    var thermalStateThreshold: ThermalStateLevel {
        get { ThermalStateLevel(rawValue: thermalStateThresholdRaw) ?? .serious }
        // Assigning thermalStateThresholdRaw triggers its didSet, which persists.
        set { thermalStateThresholdRaw = newValue.rawValue }
    }

    var isEmailConfigured: Bool {
        !smtpHost.isEmpty && !smtpUser.isEmpty && !smtpPassword.isEmpty && !recipient.isEmpty
    }
}
