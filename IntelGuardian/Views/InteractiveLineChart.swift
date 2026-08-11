import SwiftUI
import Charts

/// A combined chart for iOS: thermal state (0-3) and battery level (0-100%)
/// share one Y axis by normalising the thermal values to the 0-100 range.
/// A single X axis. Tap / drag to see a tooltip with the real readings.
///
/// Requires Swift Charts, available on iOS 16.0+ / macOS 13.0+.
@available(iOS 16.0, macOS 13.0, *)
struct DualLineChart: View {
    struct Series {
        let points: [(Date, Double)]
        let color: Color
        let label: String
        /// Formats the *original* non-normalized value for the tooltip.
        let valueText: (Double) -> String
    }

    /// Raw thermal points (0…3).
    let thermalRaw: [(Date, Double)]
    let thermalColor: Color
    /// Raw battery points (0…100).
    let batteryPoints: [(Date, Double)]
    let xDomain: ClosedRange<Date>

    @State private var selectedIndex: Int?

    /// Normalise thermal 0…3 → 0…100 so both series share the same Y axis.
    private var thermalNorm: [(Date, Double)] {
        thermalRaw.map { ($0.0, $0.1 * 100.0 / 3.0) }
    }

    /// Union of all time stamps (for crosshair alignment).
    private var alignedTimes: [Date] {
        Set(thermalNorm.map(\.0)).union(batteryPoints.map(\.0)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Legend
            HStack(spacing: 18) {
                legendDot(color: thermalColor, label: "热状态")
                legendDot(color: .blue, label: "电量")
                Spacer()
            }
            .font(.caption2)

            if batteryPoints.isEmpty && thermalRaw.isEmpty {
                Text("暂无数据 — 等待首次采样…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                chartBody
            }
        }
    }

    // MARK: - Chart

    private var chartBody: some View {
        Chart {
            // ── Thermal line (normalised to 0…100) ────────────────────────
            ForEach(Array(thermalNorm.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("时间", p.0), y: .value("热状态", p.1), series: .value("s", "热"))
                    .foregroundStyle(thermalColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("时间", p.0), y: .value("热状态", p.1), series: .value("s", "热"))
                    .foregroundStyle(LinearGradient(
                        colors: [thermalColor.opacity(0.25), thermalColor.opacity(0.01)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
            }

            // ── Battery line (native 0…100) ───────────────────────────────
            ForEach(Array(batteryPoints.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("时间", p.0), y: .value("电量", p.1), series: .value("s", "电"))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("时间", p.0), y: .value("电量", p.1), series: .value("s", "电"))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.blue.opacity(0.2), Color.blue.opacity(0.01)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
            }

            // ── Crosshair ─────────────────────────────────────────────────
            if let idx = selectedIndex, alignedTimes.indices.contains(idx) {
                let t = alignedTimes[idx]
                RuleMark(x: .value("时间", t))
                    .foregroundStyle(.gray.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                AxisTick()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date.time24)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing)
        }
        .chartLegend(.hidden)
        .frame(height: 200)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in updateSelection(at: val.location, proxy: proxy) }
                                .onEnded { _ in selectedIndex = nil }
                        )
                    if let idx = selectedIndex, alignedTimes.indices.contains(idx) {
                        tooltip(for: alignedTimes[idx])
                            .position(tooltipPos(proxy: proxy, geo: geo, date: alignedTimes[idx]))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func updateSelection(at location: CGPoint, proxy: ChartProxy) {
        guard let date = proxy.value(atX: location.x, as: Date.self), !alignedTimes.isEmpty else { return }
        selectedIndex = alignedTimes.enumerated()
            .min { abs($0.element.timeIntervalSince(date)) < abs($1.element.timeIntervalSince(date)) }?
            .offset
    }

    private func tooltipPos(proxy: ChartProxy, geo: GeometryProxy, date: Date) -> CGPoint {
        let x = proxy.position(forX: date) ?? geo.size.width / 2
        return CGPoint(x: min(max(x, 100), geo.size.width - 100), y: 22)
    }

    private func tooltip(for date: Date) -> some View {
        // Find closest raw points for this timestamp.
        let tIdx = thermalRaw.lastIndex(where: { $0.0 <= date }).map { thermalRaw[$0] }
        let bIdx = batteryPoints.lastIndex(where: { $0.0 <= date }).map { batteryPoints[$0] }
        return VStack(alignment: .leading, spacing: 3) {
            Text(date.time24)
                .font(.caption2).foregroundColor(.secondary)
            if let t = tIdx {
                let label = ThermalStateLevel(rawValue: Int(t.1))?.label ?? "未知"
                Text("热状态：\(label)").font(.caption.bold()).foregroundColor(thermalColor)
            }
            if let b = bIdx {
                Text("电量：\(String(format: "%.1f%%", b.1))").font(.caption.bold()).foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.thinMaterial)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(.gray.opacity(0.25), lineWidth: 1))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

// ── macOS three‑series combined chart ──────────────────────────────────────────

/// CPU temperature, battery temperature, and battery level on one shared Y axis.
/// CPU / battery temp use their raw °C values; battery level (%) maps naturally
/// onto the same 0–120 range.  Works well because the Y axis auto‑scales by
/// default — no normalisation needed.
@available(iOS 16.0, macOS 13.0, *)
struct TripleLineChart: View {
    let cpuSeries:   [(Date, Double)]   // °C,  nil-safe (pre-filtered)
    let btmpSeries:  [(Date, Double)]   // °C,  nil-safe (pre-filtered)
    let battSeries:  [(Date, Double)]   // 0…100
    let xDomain: ClosedRange<Date>

    @State private var selectedIndex: Int?

    private var allTimes: [Date] {
        Set(cpuSeries.map(\.0) + btmpSeries.map(\.0) + battSeries.map(\.0)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                legendDot(color: .red,    label: "CPU 温度")
                legendDot(color: .orange, label: "电池温度")
                legendDot(color: .blue,   label: "电量")
                Spacer()
            }
            .font(.caption2)

            if allTimes.isEmpty {
                Text("暂无数据 — 等待首次采样…")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                chartBody
            }
        }
    }

    private var chartBody: some View {
        Chart {
            if !cpuSeries.isEmpty {
                ForEach(Array(cpuSeries.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("时间", p.0), y: .value("CPU温度", p.1), series: .value("s", "CPU"))
                        .foregroundStyle(.red).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                }
            }
            if !btmpSeries.isEmpty {
                ForEach(Array(btmpSeries.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("时间", p.0), y: .value("电池温度", p.1), series: .value("s", "Btmp"))
                        .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                }
            }
            if !battSeries.isEmpty {
                ForEach(Array(battSeries.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("时间", p.0), y: .value("电量", p.1), series: .value("s", "Bat"))
                        .foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                }
            }

            if let idx = selectedIndex, allTimes.indices.contains(idx) {
                RuleMark(x: .value("时间", allTimes[idx]))
                    .foregroundStyle(.gray.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                AxisTick()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date.time24)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .trailing) }
        .chartLegend(.hidden)
        .frame(height: 150)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        #if os(macOS)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): updateSelection(at: loc, proxy: proxy)
                            case .ended:           selectedIndex = nil
                            }
                        }
                        #endif
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in updateSelection(at: v.location, proxy: proxy) }
                                .onEnded   { _ in selectedIndex = nil }
                        )
                    if let idx = selectedIndex, allTimes.indices.contains(idx) {
                        tooltip(for: allTimes[idx])
                            .position(tooltipPos(proxy: proxy, geo: geo, date: allTimes[idx]))
                    }
                }
            }
        }
    }

    private func updateSelection(at location: CGPoint, proxy: ChartProxy) {
        guard !allTimes.isEmpty, let date = proxy.value(atX: location.x, as: Date.self) else { return }
        selectedIndex = allTimes.enumerated()
            .min { abs($0.1.timeIntervalSince(date)) < abs($1.1.timeIntervalSince(date)) }?.offset
    }
    private func tooltipPos(proxy: ChartProxy, geo: GeometryProxy, date: Date) -> CGPoint {
        CGPoint(x: min(max(proxy.position(forX: date) ?? geo.size.width/2, 110), geo.size.width-110), y: 22)
    }
    private func tooltip(for date: Date) -> some View {
        let c = cpuSeries.last(where: { $0.0 <= date })
        let t = btmpSeries.last(where: { $0.0 <= date })
        let b = battSeries.last(where: { $0.0 <= date })
        return VStack(alignment: .leading, spacing: 3) {
            Text(date.time24).font(.caption2).foregroundColor(.secondary)
            if let c { Text("CPU：\(String(format: "%.1f", c.1))°C").font(.caption.bold()).foregroundColor(.red) }
            if let t { Text("电池：\(String(format: "%.1f", t.1))°C").font(.caption.bold()).foregroundColor(.orange) }
            if let b { Text("电量：\(String(format: "%.1f", b.1))%").font(.caption.bold()).foregroundColor(.blue) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.thinMaterial).shadow(color: .black.opacity(0.12), radius: 4, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.25), lineWidth: 1))
    }
    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 8, height: 8); Text(label) }
    }
}


// MARK: - 24-hour time formatter

/// Formats a date as 24-hour "HH:mm" regardless of the user's locale,
/// so chart axes and tooltips never flip to 12-hour (e.g. 下午3:00).
extension Date {
    /// "14:05" style, always 24-hour.
    var time24: String {
        Self.time24Formatter.string(from: self)
    }
    /// "14:05" style, always 24-hour.
    static let time24Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}
