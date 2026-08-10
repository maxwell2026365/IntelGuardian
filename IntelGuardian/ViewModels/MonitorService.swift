import Foundation
import Combine

/// Samples system metrics on a timer, stores them in a JSON-backed store,
/// prunes old data, and evaluates battery/charge alert conditions, emailing
/// on each trigger (with a cooldown).
@MainActor
final class MonitorService: ObservableObject {
    let store: SampleStore
    private let settings: AppSettings
    private let emailService: EmailService

    private var timer: Timer?
    private var lastSample: SystemInfo?
    /// Cooldown timestamps for the two independent alert families:
    /// temperature (battery temp + thermal state) and charge (80% / 20%).
    private var lastTempAlertAt: Date?
    private var lastChargeAlertAt: Date?

    @Published var latest: SystemInfo = SystemInfo(cpuTemp: nil, batteryTemp: nil, batteryLevel: -1, thermalState: nil)
    @Published var isMonitoring = false

    /// Initial cooldown so the app doesn't spam on first launch when the
    /// battery is already past a threshold.
    private var coolDownUntil: Date?

    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.store = SampleStore()
        self.settings = settings
        self.emailService = EmailService(settings: settings)

        // Forward store changes so that consumers observing `monitor`
        // (e.g. DashboardView) re-render when new samples land.
        store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)

        // Sync @Published settings to UserDefaults whenever they change.
        settings.objectWillChange.sink { [settings] _ in
            settings.sync()
        }
        .store(in: &cancellables)
    }

    var alertCooldownMinutes: Double { 10 }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        #if os(iOS)
        BatteryReader.configureMonitoring()
        #endif
        coolDownUntil = Date().addingTimeInterval(alertCooldownMinutes * 60)
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleNow()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    func sampleNow() {
        let info = SystemInfo.current()
        latest = info
        insertSample(info)

        guard settings.monitoringEnabled, settings.isEmailConfigured else { return }
        guard let coolDownUntil else { return }
        guard Date() >= coolDownUntil else { return }
        evaluateAlerts(info)
    }

    private func insertSample(_ info: SystemInfo) {
        let sample = ThermalSample(
            timestamp: Date(),
            cpuTemp: info.cpuTemp,
            batteryTemp: info.batteryTemp,
            batteryLevel: info.batteryLevel,
            thermalState: info.thermalState
        )
        store.insert(sample)
    }

    private func evaluateAlerts(_ info: SystemInfo) {
        var reasons: [AlertReason] = []

        // Temperature family (battery temp + thermal state): at most one email
        // per 10 minutes regardless of how many temperature conditions hit.
        let tempCooldownElapsed = lastTempAlertAt.map { Date().timeIntervalSince($0) >= alertCooldownMinutes * 60 } ?? true
        if tempCooldownElapsed {
            var tempReason: AlertReason?
            if settings.notifyBatteryTemp,
               let temp = info.batteryTemp,
               temp >= settings.highBatteryTemp {
                tempReason = .highBatteryTemp(temp)
            } else if settings.notifyThermalState,
                      let state = info.thermalState,
                      state.rawValue >= settings.thermalStateThreshold.rawValue {
                tempReason = .highThermalState(state)
            }
            if let tempReason {
                lastTempAlertAt = Date()
                reasons.append(tempReason)
            }
        }

        // Charge family: at most one email per 10 minutes.
        let chargeCooldownElapsed = lastChargeAlertAt.map { Date().timeIntervalSince($0) >= alertCooldownMinutes * 60 } ?? true
        if chargeCooldownElapsed {
            var chargeReason: AlertReason?
            let level = info.batteryLevel
            let charging = info.isCharging

            if settings.notifyCharge80,
               charging == true,
               level >= 0.80,
               level < 0.999 {
                chargeReason = .chargeHigh(level * 100)
            } else if settings.notifyCharge20,
                      charging == false,
                      level > 0,
                      level < 0.20 {
                chargeReason = .chargeLow(level * 100)
            }
            if let chargeReason {
                lastChargeAlertAt = Date()
                reasons.append(chargeReason)
            }
        }

        for reason in reasons {
            let samples = store.recentSamples(hours: 3)
            Task { [emailService] in
                _ = await emailService.sendAlert(reason: reason, samples: samples)
            }
        }
    }

    /// Manual "check now" used by the dashboard refresh button; records a sample
    /// but does not evaluate email alerts.
    func refreshNow() {
        let info = SystemInfo.current()
        latest = info
        insertSample(info)
    }
}
