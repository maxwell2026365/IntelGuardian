import Foundation
import Combine

/// Device thermal state. On iOS this maps directly to `ProcessInfo.ThermalState`;
/// on macOS it is unused (temperatures are read directly via SMC/IOKit).
enum ThermalStateLevel: Int, Codable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    var label: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "轻微升温"
        case .serious: return "严重发热"
        case .critical: return "临界高温"
        }
    }
}

/// A single sample of system metrics, persisted as JSON on disk.
struct ThermalSample: Identifiable, Codable {
    var id = UUID()
    var timestamp: Date
    /// CPU temperature in °C. nil on iOS where the OS exposes no CPU temperature API.
    var cpuTemp: Double?
    /// Battery temperature in °C. nil on iOS and on macOS systems where it is unavailable.
    var batteryTemp: Double?
    /// Battery charge level in 0...1.
    var batteryLevel: Double
    /// Device thermal state. Valid on iOS; nil on macOS.
    var thermalStateRaw: Int?

    init(timestamp: Date, cpuTemp: Double?, batteryTemp: Double?, batteryLevel: Double, thermalState: ThermalStateLevel?) {
        self.id = UUID()
        self.timestamp = timestamp
        self.cpuTemp = cpuTemp
        self.batteryTemp = batteryTemp
        self.batteryLevel = batteryLevel
        self.thermalStateRaw = thermalState?.rawValue
    }

    var thermalState: ThermalStateLevel? {
        get { thermalStateRaw.map(ThermalStateLevel.init(rawValue:)) ?? nil }
        set { thermalStateRaw = newValue?.rawValue }
    }
}

/// Persists ThermalSamples to a JSON file on disk so history survives app restarts.
@MainActor
final class SampleStore: ObservableObject {
    @Published var samples: [ThermalSample] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = dir.appendingPathComponent("IntelGuardianSamples.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ThermalSample].self, from: data) else { return }
        samples = decoded.sorted { $0.timestamp > $1.timestamp }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func insert(_ sample: ThermalSample) {
        samples.insert(sample, at: 0)
        prune()
        save()
    }

    func delete(_ sample: ThermalSample) {
        samples.removeAll { $0.id == sample.id }
        save()
    }

    /// Keeps the last 7 days of samples.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        samples = samples.filter { $0.timestamp >= cutoff }
    }

    /// Recent samples for the last N hours (ascending).
    func recentSamples(hours: Int = 3) -> [ThermalSample] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        return samples.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
    }
}
