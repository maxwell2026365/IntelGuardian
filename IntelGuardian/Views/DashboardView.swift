import SwiftUI

private extension Color {
    static var cardBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: MonitorService

    #if os(macOS)
    /// Sort key for the CPU ranking table. Defaults to accumulated CPU time.
    private enum RankSortKey: Hashable {
        case name, pid, ppid, startDate, runtime, usagePercent, cpuSeconds
    }
    @State private var sortKey: RankSortKey = .cpuSeconds
    @State private var sortAscending = false
    #endif

    private var recent: [ThermalSample] {
        monitor.store.recentSamples(hours: 2)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                titleRow
                statusCard
                currentMetricsGrid
                uptimeCard
                chartsCard
                #if os(macOS)
                if !monitor.topProcesses.isEmpty {
                    cpuRankingCard
                }
                #endif
            }
            .padding()
        }
        #if os(iOS)
        .background(Color.black.ignoresSafeArea())
        #endif
        .onAppear {
            monitor.refreshNow()
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

    // MARK: - System uptime

    private var uptimeCard: some View {
        VStack(spacing: 6) {
            Label("系统启动", systemImage: "power")
                .font(.caption)
                .foregroundColor(.secondary)
            if let bootDate = SystemInfo.bootDate {
                Text(bootDate.formatted(date: .abbreviated, time: .standard))
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Text("已运行 \(uptimeText(from: bootDate))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("暂不可用")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func uptimeText(from bootDate: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(bootDate)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时 \(minutes) 分钟" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(max(1, minutes)) 分钟"
    }

    private func valueText(_ value: Double?, unit: String) -> String {
        guard let value else { return "N/A" }
        return String(format: "%.1f%@", value, unit)
    }

    private func levelText(_ level: Double) -> String {
        guard level >= 0 else { return "N/A" }
        // Integer percentage to match the status-bar style (e.g. "62%").
        return String(format: "%.0f%%", level * 100)
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

    // MARK: - CPU usage ranking

    #if os(macOS)
    private var sortedProcesses: [ProcessUsage] {
        let list = monitor.topProcesses
        let sorted = list.sorted { a, b in
            switch sortKey {
            case .name: return a.name < b.name
            case .pid: return a.pid < b.pid
            case .ppid: return a.ppid < b.ppid
            case .startDate: return a.startDate < b.startDate
            case .runtime: return a.runtimeSeconds < b.runtimeSeconds
            case .usagePercent: return a.cpuUsagePercent < b.cpuUsagePercent
            case .cpuSeconds: return a.cpuSeconds < b.cpuSeconds
            }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private var cpuRankingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU 发热 Top")
                    .font(.headline)
                Spacer()
                Text("点击列表头排序")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            rankingHeader
            Divider()
            ForEach(Array(sortedProcesses.enumerated()), id: \.element.id) { index, process in
                rankingRow(rank: index + 1, process: process)
            }
        }
        .padding()
        .background(Color.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sortBy(_ key: RankSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = false
        }
    }

    private func sortedHeader(_ title: String, width: CGFloat?, align: Alignment, key: RankSortKey) -> some View {
        Button {
            sortBy(key)
        } label: {
            HStack(spacing: 3) {
                columnText(title, width: width, align: align, header: true)
                if sortKey == key {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var rankingHeader: some View {
        HStack(spacing: 10) {
            columnText("名次", width: 32, align: .trailing, header: true)
            sortedHeader("进程", width: nil, align: .leading, key: .name)
            sortedHeader("PID", width: 52, align: .trailing, key: .pid)
            sortedHeader("PPID", width: 56, align: .trailing, key: .ppid)
            sortedHeader("启动时间", width: 58, align: .trailing, key: .startDate)
            sortedHeader("已运行", width: 64, align: .trailing, key: .runtime)
            sortedHeader("CPU 使用率", width: 72, align: .trailing, key: .usagePercent)
            sortedHeader("CPU 累计", width: 72, align: .trailing, key: .cpuSeconds)
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.bottom, 2)
    }

    private func rankingRow(rank: Int, process: ProcessUsage) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundColor(rank <= 3 ? Color.red.opacity(0.8) : Color.secondary)
                .frame(width: 32, alignment: .trailing)

            Text(process.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            columnText("\(process.pid)", width: 52, align: .trailing)
            columnText(process.ppid > 0 ? "\(process.ppid)" : "—", width: 56, align: .trailing)
            columnText(startTimeText(process.startDate), width: 58, align: .trailing)
            columnText(runtimeText(process.runtimeSeconds), width: 64, align: .trailing)
            columnText(percentText(process.cpuUsagePercent), width: 72, align: .trailing, color: usageColor(process.cpuUsagePercent))
            columnText(timeText(process.cpuSeconds), width: 72, align: .trailing, color: percentColor(process.cpuSeconds))
        }
        .padding(.vertical, 2)
    }

    private func columnText(_ text: String, width: CGFloat?, align: Alignment, color: Color = .secondary, header: Bool = false) -> some View {
        let base = Text(text)
            .font(header ? .caption2 : .subheadline)
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        if let width {
            return AnyView(base.frame(width: width, alignment: align))
        }
        return AnyView(base.frame(maxWidth: .infinity, alignment: align))
    }

    private func startTimeText(_ date: Date) -> String {
        guard date != .distantPast else { return "—" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func runtimeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 24 * 3600 {
            let d = total / (24 * 3600), h = (total % (24 * 3600)) / 3600
            return d > 0 ? String(format: "%d 天 %d 时", d, h) : String(format: "%d 时", h)
        }
        if total >= 3600 {
            let h = total / 3600, m = (total % 3600) / 60
            return m > 0 ? String(format: "%d 时 %d 分", h, m) : String(format: "%d 时", h)
        }
        let m = total / 60
        return m > 0 ? String(format: "%d 分", m) : "\(total) 秒"
    }

    private func timeText(_ seconds: UInt64) -> String {
        let minutes = seconds / 60
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m > 0 ? String(format: "%d 小时 %d 分", h, m) : String(format: "%d 小时", h)
        }
        return String(format: "%d 分", minutes)
    }

    private func percentText(_ percent: Double) -> String {
        guard percent > 0 else { return "—" }
        return String(format: "%.0f%%", percent)
    }

    private func usageColor(_ percent: Double) -> Color {
        switch percent {
        case 80...: return .red            // pegged core(s)
        case 50..<80: return .orange       // heavy
        default: return .secondary
        }
    }

    private func percentColor(_ seconds: UInt64) -> Color {
        switch seconds {
        case 3600...: return .red            // ≥ 1 hour of CPU time
        case 900..<3600: return .orange      // ≥ 15 minutes
        default: return .secondary
        }
    }
    #endif
}
