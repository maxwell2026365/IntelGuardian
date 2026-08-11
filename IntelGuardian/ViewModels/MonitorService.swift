import Foundation
import Combine
#if os(iOS)
import BackgroundTasks
#endif

/// Samples system metrics on a timer, stores them in a JSON-backed store,
/// prunes old data, and evaluates battery/charge alert conditions, emailing
/// on each trigger (with a cooldown).
@MainActor
final class MonitorService: ObservableObject {
    let store: SampleStore
    private let settings: AppSettings
    private let emailService: EmailService

    private var timer: Timer?
    /// On iOS the battery level from `UIDevice` updates slowly and coarsely,
    /// so we poll it on a separate, faster timer and refresh `latest.batteryLevel`
    /// in place — without inserting extra samples into the store.
    private var batteryTimer: Timer?
    private var lastSample: SystemInfo?
    /// Cooldown timestamps for the two independent alert families:
    /// temperature (battery temp + thermal state) and charge (80% / 20%).
    private var lastTempAlertAt: Date?
    private var lastChargeAlertAt: Date?

    @Published var latest: SystemInfo = SystemInfo(cpuTemp: nil, batteryTemp: nil, batteryLevel: -1, thermalState: nil)
    @Published var isMonitoring = false
    #if os(macOS)
    /// Live CPU-heat ranking shown on the dashboard: per-process accumulated
    /// CPU time over the trailing 2-hour window. Empty until a second sample
    /// lands (the first sample only establishes a baseline).
    @Published var topProcesses: [ProcessUsage] = []
    #endif

    /// Initial cooldown so the app doesn't spam on first launch when the
    /// battery is already past a threshold.
    private var coolDownUntil: Date?

    #if os(macOS)
    /// Computes the CPU-usage ranking from per-process CPU-time deltas.
    private let processSampler = ProcessSampler()
    #endif

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
        #if os(iOS)
        // Poll battery level on a separate, faster cadence so the dashboard
        // value tracks the status bar closely. This only updates `latest`
        // in place — no extra samples are stored.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshBatteryLevel()
            }
        }
        #endif
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        #if os(macOS)
        processSampler.reset()
        topProcesses = []
        #endif
        isMonitoring = false
    }

    /// Re-reads only the battery level and updates `latest` in place. On iOS
    /// `UIDevice.batteryLevel` lags and steps in 1% increments; re-reading is
    /// cheap and `BatteryReader` caches the last non-stale value.
    private func refreshBatteryLevel() {
        #if os(iOS)
        let level = BatteryReader.batteryLevel()
        guard level >= 0, level != latest.batteryLevel else { return }
        latest = SystemInfo(
            cpuTemp: latest.cpuTemp,
            batteryTemp: latest.batteryTemp,
            batteryLevel: level,
            thermalState: latest.thermalState,
            isCharging: BatteryReader.isCharging()
        )
        #endif
    }

    func sampleNow() {
        let info = SystemInfo.current()
        latest = info
        insertSample(info)
        #if os(macOS)
        refreshTopProcesses()
        #endif

        guard settings.monitoringEnabled, settings.isEmailConfigured else { return }
        guard let coolDownUntil else { return }
        guard Date() >= coolDownUntil else { return }
        evaluateAlerts(info)
    }

    /// Manual "check now" used by the dashboard refresh button; records a sample
    /// but does not evaluate email alerts.
    func refreshNow() {
        let info = SystemInfo.current()
        latest = info
        insertSample(info)
        #if os(macOS)
        refreshTopProcesses()
        #endif
    }

    #if os(iOS)
    /// Identifier for the background refresh task. Must match the
    /// `BGTaskSchedulerPermittedIdentifiers` entry in Info.plist.
    private static let bgRefreshIdentifier = "max.com.IntelGuardian.refresh"

    /// Registers the background refresh handler and schedules the first task.
    /// Call once at app launch (after the SMTP password is loaded). iOS only.
    func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgRefreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(task)
        }
        scheduleBackgroundRefresh()
    }

    /// Asks the system for the next background refresh opportunity. The system
    /// decides when to run it; this only requests that a slot be granted.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // e.g. the user disabled background refresh for this app in Settings.
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        guard settings.monitoringEnabled else {
            task.setTaskCompleted(success: true)
            return
        }

        sampleNow()
        task.setTaskCompleted(success: true)
    }
    #endif

    #if os(macOS)
    /// Recomputes the CPU-heat ranking. The first call only establishes a
    /// baseline (no deltas yet), so `topProcesses` stays empty until the second.
    private func refreshTopProcesses() {
        topProcesses = processSampler.sampleTopProcesses()
    }
    #endif

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
               level > 0.80,
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
}
