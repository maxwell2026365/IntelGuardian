import SwiftUI

private extension Color {
    static var cardBackground: Color {
        #if os(macOS)
        if #available(macOS 10.14, *) {
            return Color(nsColor: .controlBackgroundColor)
        }
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: MonitorService
    @ObservedObject var settings: AppSettings

    private var recent: [ThermalSample] {
        monitor.store.recentSamples(hours: 2)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                titleRow
                statusCard
                currentMetricsGrid
                chartsCard
            }
            .padding()
        }
    }

    private var titleRow: some View {
        HStack {
            Spacer()
            Text("IntelGuardian")
                .font(.title2.bold())
            Spacer()
            Button {
                monitor.refreshNow()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(spacing: 6) {
            if monitor.isMonitoring {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                    Text("监测中 · 每 30 秒采样")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("监测未启动")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let updated = monitor.store.samples.first?.timestamp {
                Text("最近采样：\(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Current values

    @ViewBuilder
    private var currentMetricsGrid: some View {
        #if os(iOS)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: "热状态",
                value: monitor.latest.thermalState?.label ?? "N/A",
                color: thermalColor(monitor.latest.thermalState),
                subtitle: "设备发热程度"
            )
            batteryMetricCard
        }
        #else
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: "CPU 温度",
                value: valueText(monitor.latest.cpuTemp, unit: "°C"),
                color: .red,
                subtitle: cpuSubtitle
            )
            metricCard(
                title: "电池温度",
                value: valueText(monitor.latest.batteryTemp, unit: "°C"),
                color: .orange,
                subtitle: batterySubtitle
            )
            batteryMetricCard
        }
        #endif
    }

    private var cpuSubtitle: String {
        monitor.latest.cpuTemp.map { _ in "最近采样" } ?? "暂不可用"
    }

    private var batterySubtitle: String {
        monitor.latest.batteryTemp.map { _ in "最近采样" } ?? "暂不可用"
    }

    private var batteryMetricCard: some View {
        VStack(spacing: 4) {
            Text("电量")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(levelText(monitor.latest.batteryLevel))
                .font(.title3.bold())
                .foregroundColor(.blue)
            chargingStatusRow
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 12)
        .background(Color.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chargingStatusRow: some View {
        HStack(spacing: 4) {
            Image(systemName: chargingIcon)
                .font(.caption2)
            Text(chargingStatusText)
                .font(.caption2)
        }
        .foregroundColor(.secondary)
    }

    private var chargingIcon: String {
        switch monitor.latest.isCharging {
        case true: return "bolt.fill"
        case false: return "battery.0percent"
        case nil: return "questionmark.circle"
        }
    }

    private var chargingStatusText: String {
        switch monitor.latest.isCharging {
        case true: return "电源供电"
        case false: return "电池供电"
        case nil: return "状态未知"
        }
    }

    private func thermalColor(_ state: ThermalStateLevel?) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .orange
        case .serious: return .red
        case .critical: return .purple
        case nil: return .gray
        }
    }

    private func metricCard(title: String, value: String, color: Color, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundColor(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 0)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 12)
        .background(Color.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func valueText(_ value: Double?, unit: String) -> String {
        guard let value else { return "N/A" }
        return String(format: "%.1f%@", value, unit)
    }

    private func levelText(_ level: Double) -> String {
        guard level >= 0 else { return "N/A" }
        return String(format: "%.1f%%", level * 100)
    }

    // MARK: - Charts

    private var chartsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("趋势（近 2 小时）")
                .font(.headline)

            if #available(iOS 16.0, macOS 13.0, *) {
                modernCharts
            } else {
                legacyCharts
            }
        }
        .padding()
        .background(Color.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @available(iOS 16.0, macOS 13.0, *)
    private var modernCharts: some View {
        Group {
            #if os(iOS)
            // ── One combined chart: thermal state + battery level ────────
            let thermalRaw = recent.compactMap { s -> (Date, Double)? in
                s.thermalStateRaw.map { (s.timestamp, Double($0)) }
            }
            let batteryPoints = recent.map { ($0.timestamp, $0.batteryLevel * 100) }

            DualLineChart(
                thermalRaw: thermalRaw,
                thermalColor: thermalColor(recent.last?.thermalState),
                batteryPoints: batteryPoints,
                xDomain: xDomain
            )
            #else
            // ── macOS: CPU temp + battery temp + battery level in one chart ──
            let cpu   = recent.compactMap { s in s.cpuTemp.map    { (s.timestamp, $0) } }
            let btemp = recent.compactMap { s in s.batteryTemp.map { (s.timestamp, $0) } }
            let batt  = recent.map        { ($0.timestamp, $0.batteryLevel * 100) }

            TripleLineChart(
                cpuSeries:  cpu,
                btmpSeries: btemp,
                battSeries: batt,
                xDomain: xDomain
            )
            #endif
        }
    }

    /// iOS 15 / macOS 12 fallback: simple summary without Swift Charts.
    private var legacyCharts: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            Text("Swift Charts 在 iOS 16 以下不可用，请升级系统以查看趋势图。")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
            #else
            Text("Swift Charts 在 macOS 13 以下不可用，请升级系统以查看趋势图。")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
            #endif

            // Still show battery level as text summary.
            if let latest = monitor.store.samples.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最新读数")
                        .font(.caption.bold())
                    Text("时间：\(latest.timestamp.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                    Text("电量：\(String(format: "%.1f%%", latest.batteryLevel * 100))")
                        .font(.caption)
                    if let cpu = latest.cpuTemp {
                        Text("CPU 温度：\(String(format: "%.1f", cpu))°C")
                            .font(.caption)
                    }
                    if let bat = latest.batteryTemp {
                        Text("电池温度：\(String(format: "%.1f", bat))°C")
                            .font(.caption)
                    }
                    if let state = latest.thermalState {
                        Text("热状态：\(state.label)")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var xDomain: ClosedRange<Date> {
        Date().addingTimeInterval(-3 * 3600)...Date()
    }
}
