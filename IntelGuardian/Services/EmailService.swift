import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Reasons an alert email is being sent.
enum AlertReason {
    case highBatteryTemp(Double)
    case highThermalState(ThermalStateLevel)
    case chargeHigh(Double)
    case chargeLow(Double)

    /// Which category this alert belongs to, so temperature and charge alerts
    /// are never conflated.
    enum Category {
        case temperature
        case charge

        var label: String {
            switch self {
            case .temperature: return "温度告警"
            case .charge: return "电量告警"
            }
        }

        var badgeColor: String {
            switch self {
            case .temperature: return "#ff3b30" // red
            case .charge: return "#007aff"      // blue
            }
        }
    }

    var category: Category {
        switch self {
        case .highBatteryTemp, .highThermalState: return .temperature
        case .chargeHigh, .chargeLow: return .charge
        }
    }

    var title: String {
        switch self {
        case .highBatteryTemp:
            return "电池温度过高预警"
        case .highThermalState(let state):
            return "设备发热预警（\(state.label)）"
        case .chargeHigh:
            return "充电电量过高提醒"
        case .chargeLow:
            return "电量偏低提醒"
        }
    }

    /// Full subject line with an explicit category prefix.
    var subject: String {
        "【\(category.label)】\(title)"
    }

    var reasonText: String {
        switch self {
        case .highBatteryTemp(let temp):
            return "电池温度达到 \(String(format: "%.1f", temp))°C，超过设定阈值，请留意散热。"
        case .highThermalState(let state):
            return "设备热状态已达到「\(state.label)」，请降低负载或暂停使用以帮助设备降温。"
        case .chargeHigh(let level):
            return "设备正在充电且电量已达 \(String(format: "%.0f", level))%，建议停止充电以延长电池寿命。"
        case .chargeLow(let level):
            return "设备未在充电且电量已降至 \(String(format: "%.0f", level))%，建议及时充电。"
        }
    }
}

/// Builds a multipart MIME email (HTML + inline chart PNG) describing an alert,
/// then sends it through SMTP. All sending runs in a detached task so it never
/// blocks the UI; a per-send mutex prevents overlapping sessions.
@MainActor
final class EmailService {
    enum SendOutcome {
        case sent
        case notConfigured
        case failed(String)
    }

    private let settings: AppSettings
    private var activeSend = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func sendAlert(reason: AlertReason, samples: [ThermalSample]) async -> SendOutcome {
        guard settings.isEmailConfigured else { return .notConfigured }
        guard !activeSend else { return .failed("另一封邮件正在发送中") }
        activeSend = true
        defer { activeSend = false }

        // Message construction (chart rendering) runs on the main actor; only the
        // network send is offloaded to a background task.
        let message: Data
        do {
            message = try Self.makeMessage(reason: reason, samples: samples, settings: settings)
        } catch {
            return .failed(error.localizedDescription)
        }
        let serverConfig = SMTPServerConfig(
            host: settings.smtpHost,
            port: settings.smtpPort,
            username: settings.smtpUser,
            password: settings.smtpPassword,
            recipient: settings.recipient
        )
        return await Task.detached(priority: .utility) {
            do {
                let client = SMTPClient(
                    host: serverConfig.host,
                    port: serverConfig.port,
                    username: serverConfig.username,
                    password: serverConfig.password,
                    recipient: serverConfig.recipient
                )
                try await client.send(messageData: message)
                return SendOutcome.sent
            } catch {
                return SendOutcome.failed(error.localizedDescription)
            }
        }.value
    }

    func sendTest(samples: [ThermalSample]) async -> SendOutcome {
        await sendAlert(reason: .chargeHigh(80), samples: samples)
    }

    private static func makeMessage(reason: AlertReason, samples: [ThermalSample], settings: AppSettings) throws -> Data {
        let dateText = Self.dateFormatter.string(from: Date())
        let latest = samples.last
        let cpuText = latest?.cpuTemp.map { String(format: "%.1f", $0) } ?? "N/A"
        let batteryTempText = latest?.batteryTemp.map { String(format: "%.1f", $0) } ?? "N/A"
        let levelText = latest.map { String(format: "%.0f%%", $0.batteryLevel * 100) } ?? "N/A"
        let thermalText = latest?.thermalState?.label ?? "N/A"

        let deviceType = Self.deviceTypeName()
        let deviceUser = Self.deviceUserName()
        let chargingText = Self.isChargingText()

        #if os(iOS)
        // iOS has no CPU/battery temperature API; show thermal state + level only.
        let statusRows = "热状态：\(thermalText)<br>电量：\(levelText)"
        #else
        let statusRows = "CPU 温度：\(cpuText)°C<br>电池温度：\(batteryTempText)°C<br>电量：\(levelText)"
        #endif

        // SVG line charts so recipients can read each point's time + value.
        let svgCharts = Self.makeSVGCharts(samples: samples)

        let html = """
        <html>
        <head><meta charset="utf-8"></head>
        <body style="font-family:-apple-system, sans-serif; color:#1c1c1e;">
          <table role="presentation" cellpadding="0" cellspacing="0" style="margin-bottom:10px;">
            <tr>
              <td style="background:\(reason.category.badgeColor); color:#ffffff; font-size:12px; font-weight:700; padding:3px 10px; border-radius:12px;">\(reason.category.label)</td>
            </tr>
          </table>
          <h2 style="color:#1c1c1e; margin-top:4px;">\(reason.title)</h2>
          <p style="font-size:14px; color:#3a3a3c;">发送时间：\(dateText)</p>
          <p style="font-size:13px; color:#666;">
            设备：\(deviceType) ｜ 用户：\(deviceUser) ｜ 充电状态：\(chargingText)
          </p>
          <p style="font-size:14px;">\(reason.reasonText)</p>
          <hr>
          <h3 style="color:#1c1c1e;">当前状态</h3>
          <p style="font-size:14px;">
            \(statusRows)
          </p>
          <hr>
          <h3 style="color:#1c1c1e;">近况趋势</h3>
          \(svgCharts)
        </body>
        </html>
        """

        let boundary = "IntelGuardianBoundary_\(UUID().uuidString)"
        var parts = [Data]()

        // HTML part
        var header = Data()
        header.append(Data("Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n".utf8))
        header.append(Data(Self.wrappedBase64(html.data(using: .utf8)!.base64EncodedString()).utf8))
        header.append(Data("\r\n".utf8))
        parts.append(header)

        let sender = settings.smtpSender.isEmpty ? settings.smtpUser : settings.smtpSender
        let subject = "\(reason.subject)｜\(deviceType)｜\(deviceUser)"

        var message = Data()
        message.append(Data("From: \(Self.encodeHeader(sender)) <\(settings.smtpUser)>\r\n".utf8))
        message.append(Data("To: \(Self.encodeHeader(settings.recipient)) <\(settings.recipient)>\r\n".utf8))
        message.append(Data("Subject: =?UTF-8?B?\(subject.data(using: .utf8)!.base64EncodedString())?=\r\n".utf8))
        message.append(Data("MIME-Version: 1.0\r\n".utf8))
        message.append(Data("Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n".utf8))

        for part in parts {
            message.append(Data("--\(boundary)\r\n".utf8))
            message.append(part)
        }
        message.append(Data("--\(boundary)--\r\n.\r\n".utf8))
        return message
    }

    // MARK: - SVG charts

    /// Counter so each chart's CSS class names stay unique inside the email.
    private static var chartCounter = 0

    /// Builds inline SVG line charts for the 3-hour window. Each data point is a
    /// hot zone: hovering highlights the point and reveals its time/value tooltip
    /// (via SVG CSS :hover). A native <title> fallback shows the same on clients
    /// that ignore the CSS.
    private static func makeSVGCharts(samples: [ThermalSample]) -> String {
        let chartWidth = 620.0
        let chartHeight = 200.0
        let padLeft = 40.0
        let padRight = 16.0
        let padTop = 22.0
        let padBottom = 34.0

        /// Merges several series (each with its own full-scale `yMax`) onto one
        /// shared 0…100 Y axis. Tooltips show the real values.
        func multiChart(
            title: String,
            series: [(name: String, points: [(Date, Double)], colorHex: String, rgb: (Double, Double, Double), yMax: Double)]
        ) -> String {
            let live = series.filter { !$0.points.isEmpty }
            guard !live.isEmpty else { return "" }
            let innerW = chartWidth - padLeft - padRight
            let innerH = chartHeight - padTop - padBottom
            let cls = "c\(chartCounter)"
            chartCounter += 1

            // Shared X domain across all series.
            let allDates = live.flatMap { $0.points.map(\.0) }
            let minDate = allDates.min()!
            let maxDate = allDates.max()!
            let timeRange = max(maxDate.timeIntervalSince(minDate), 1)

            func x(_ d: Date) -> Double { padLeft + (d.timeIntervalSince(minDate) / timeRange) * innerW }
            // Normalise each value to the shared 0…100 axis.
            func yn(_ v: Double, yMax: Double) -> Double { padTop + (1 - (v / max(yMax, 0.0001))) * innerH }

            // Downsample helper.
            func downsample(_ pts: [(Date, Double)], to n: Int) -> [(Date, Double)] {
                guard pts.count > n else { return pts }
                var out: [(Date, Double)] = []
                let step = Double(pts.count - 1) / Double(n - 1)
                for i in 0..<n {
                    let idx = Int((Double(i) * step).rounded())
                    out.append(pts[min(idx, pts.count - 1)])
                }
                return out
            }
            let sampled = live.map { s in (name: s.name, pts: downsample(s.points, to: 20), colorHex: s.colorHex, rgb: s.rgb, yMax: s.yMax) }

            // Grid + y labels (0…100).
            var grid = ""
            for i in 1...4 {
                let gy = padTop + innerH * Double(i) / 4
                let val = 100 - 100 * Double(i) / 4
                grid += "<line x1='\(padLeft)' y1='\(String(format: "%.1f", gy))' x2='\(chartWidth - padRight)' y2='\(String(format: "%.1f", gy))' stroke='#f0f0f0' stroke-width='1'/>"
                grid += "<text x='\(padLeft - 8)' y='\(String(format: "%.1f", gy + 3.5))' text-anchor='end' font-size='10' fill='#b0b0b0'>\(String(format: "%.0f", val))</text>"
            }

            // X ticks.
            var xTicks = ""
            let tickCount = 5
            for i in 0...tickCount {
                let frac = Double(i) / Double(tickCount)
                let tickDate = minDate.addingTimeInterval(timeRange * frac)
                xTicks += "<text x='\(String(format: "%.1f", padLeft + innerW * frac))' y='\(padTop + innerH + 18)' text-anchor='middle' font-size='10' fill='#b0b0b0'>\(Self.timeFormatter.string(from: tickDate))</text>"
            }

            let baseline = "<line x1='\(padLeft)' y1='\(padTop + innerH)' x2='\(chartWidth - padRight)' y2='\(padTop + innerH)' stroke='#e2e2e2' stroke-width='1'/>"

            // Legend.
            var legend = ""
            var lx = padLeft
            for s in sampled {
                let w = Double(s.name.count * 7 + 14)
                legend += "<circle cx='\(String(format: "%.1f", lx + 4))' cy='\(padTop - 10)' r='4' fill='\(s.colorHex)'/>"
                legend += "<text x='\(String(format: "%.1f", lx + 12))' y='\(padTop - 6)' font-size='10' fill='#666'>\(s.name)</text>"
                lx += w
            }

            // Lines + hover dots per series.
            var paths = ""
            var dots = ""
            var css = ""
            for (si, s) in sampled.enumerated() {
                let path = Self.smoothPath(s.pts.map { ($0.0, $0.1) }, x: x, y: { yn($0, yMax: s.yMax) })
                paths += "<path d='\(path)' fill='none' stroke='\(s.colorHex)' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'/>"

                let pcls = "\(cls)-\(si)"
                css += ".dp-\(pcls) .tip-\(pcls){opacity:0;} .dp-\(pcls):hover .tip-\(pcls){opacity:1;} "
                for (i, p) in s.pts.enumerated() {
                    let cx = String(format: "%.1f", x(p.0))
                    let cy = String(format: "%.1f", yn(p.1, yMax: s.yMax))
                    let timeLabel = Self.timeFormatter.string(from: p.0)
                    let visible = i == s.pts.count - 1
                    let r = visible ? "5" : "3"
                    let tipX = min(max(Double(cx)!, 60), chartWidth - 60)
                    let tipY = max(Double(cy)! - 14, 12)
                    dots += """
                    <g class="dp-\(pcls)" style="cursor:pointer;">
                      <circle cx="\(cx)" cy="\(cy)" r="13" fill="transparent"/>
                      <circle cx="\(cx)" cy="\(cy)" r="\(r)" fill="\(visible ? s.colorHex : "#ffffff")" stroke="\(s.colorHex)" stroke-width="2">
                        <title>\(timeLabel)  \(s.name)  \(String(format: "%.1f", p.1))</title>
                      </circle>
                      <g class="tip-\(pcls)">
                        <rect x="\(String(format: "%.1f", tipX - 46))" y="\(String(format: "%.1f", tipY - 11))" width="92" height="22" rx="5" fill="#333"/>
                        <text x="\(String(format: "%.1f", tipX))" y="\(String(format: "%.1f", tipY + 1))" text-anchor="middle" font-size="10.5" font-weight="600" fill="#fff">\(timeLabel)  \(s.name) \(String(format: "%.1f", p.1))</text>
                      </g>
                    </g>
                    """
                }
            }

            let svg = """
            <svg width="\(Int(chartWidth))" height="\(Int(chartHeight))" viewBox="0 0 \(chartWidth) \(chartHeight)" xmlns="http://www.w3.org/2000/svg" style="position:absolute; top:0; left:0; width:100%; height:100%; background:#ffffff;">
              <style>\(css)</style>
              \(legend)
              \(grid)
              \(baseline)
              \(paths)
              \(dots)
              \(xTicks)
            </svg>
            """

            // PNG fallback — one combined chart.
            let pngData = EmailChartRenderer.renderMulti(
                series: sampled.map { s in s.pts.map { ($0.0, $0.1) } },
                colors: sampled.map { $0.rgb },
                labels: sampled.map { $0.name },
                title: title,
                yMin: 0,
                yMax: 100
            )
            let pngB64 = pngData?.base64EncodedString() ?? ""

            return """
            <div style="margin:14px 0; background:#ffffff; border:1px solid #ececec; border-radius:10px; padding:14px 8px 10px 8px;">
              <style>.dp-\(cls) .tip-\(cls) { opacity: 0; } .dp-\(cls):hover .tip-\(cls) { opacity: 1; }</style>
              <div style="font-size:13px; font-weight:600; color:#333; margin:0 6px 8px 6px;">\(title)</div>
              <div style="position:relative;">
                <img src="data:image/png;base64,\(pngB64)" width="\(Int(chartWidth))" height="\(Int(chartHeight))" alt="\(title)" style="display:block; width:100%; height:auto; max-width:\(Int(chartWidth))px; border:0;"/>
                \(svg)
              </div>
            </div>
            """
        }

        var result = ""
        #if os(iOS)
        // Combine thermal state (0…3) and battery level (0…100%) into one chart;
        // each series is normalised onto the shared axis using its own full scale.
        result += multiChart(
            title: "热状态与电量趋势",
            series: [
                (name: "热状态(0-3)",
                 points: samples.compactMap { s in s.thermalStateRaw.map { (s.timestamp, Double($0)) } },
                 colorHex: "#ff9500", rgb: (1.0, 0.58, 0.0), yMax: 3),
                (name: "电量(%)",
                 points: samples.map { ($0.timestamp, $0.batteryLevel * 100) },
                 colorHex: "#007aff", rgb: (0.0, 0.48, 1.0), yMax: 100),
            ]
        )
        #else
        result += multiChart(
            title: "温度与电量趋势",
            series: [
                (name: "CPU 温度(°C)",
                 points: samples.compactMap { s in s.cpuTemp.map { (s.timestamp, $0) } },
                 colorHex: "#ff3b30", rgb: (1.0, 0.23, 0.19), yMax: 120),
                (name: "电池温度(°C)",
                 points: samples.compactMap { s in s.batteryTemp.map { (s.timestamp, $0) } },
                 colorHex: "#ff9500", rgb: (1.0, 0.58, 0.0), yMax: 80),
                (name: "电量(%)",
                 points: samples.map { ($0.timestamp, $0.batteryLevel * 100) },
                 colorHex: "#007aff", rgb: (0.0, 0.48, 1.0), yMax: 100),
            ]
        )
        #endif
        return result
    }

    private static var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func encodeHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    // MARK: - Device info

    /// Human-readable device type, e.g. "iPhone 17 Pro" or "macOS 26.6.1 (Mac14,6)".
    private static func deviceTypeName() -> String {
        #if os(iOS)
        let name = UIDevice.current.model
        let systemName = UIDevice.current.systemName
        let systemVersion = UIDevice.current.systemVersion
        return "\(name)（\(systemName) \(systemVersion)）"
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var hwModel = "Mac"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            hwModel = String(cString: model)
        }
        return "\(macVersion)（\(hwModel)）"
        #endif
    }

    /// The current user's account name.
    private static func deviceUserName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return NSFullUserName()
        #endif
    }

    /// Whether the device is currently charging.
    private static func isChargingText() -> String {
        guard let charging = BatteryReader.isCharging() else { return "未知" }
        return charging ? "充电中" : "未充电"
    }

    /// Builds a smooth SVG path through the given points using Catmull-Rom
    /// interpolation converted to cubic Bezier segments.
    private static func smoothPath(_ pts: [(Date, Double)], x: (Date) -> Double, y: (Double) -> Double) -> String {
        guard !pts.isEmpty else { return "" }
        guard pts.count > 2 else {
            return pts.enumerated().map { i, p in
                "\(i == 0 ? "M" : "L")\(String(format: "%.1f", x(p.0))),\(String(format: "%.1f", y(p.1)))"
            }.joined(separator: " ")
        }
        let points = pts.map { CGPoint(x: x($0.0), y: y($0.1)) }
        var path = "M\(String(format: "%.1f", points[0].x)),\(String(format: "%.1f", points[0].y))"
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let cp1x = p1.x + (p2.x - p0.x) / 6
            let cp1y = p1.y + (p2.y - p0.y) / 6
            let cp2x = p2.x - (p3.x - p1.x) / 6
            let cp2y = p2.y - (p3.y - p1.y) / 6
            path += " C\(String(format: "%.1f", cp1x)),\(String(format: "%.1f", cp1y)) \(String(format: "%.1f", cp2x)),\(String(format: "%.1f", cp2y)) \(String(format: "%.1f", p2.x)),\(String(format: "%.1f", p2.y))"
        }
        return path
    }

    /// Wraps a base64 string into lines of at most `lineLength` characters.
    /// SMTP (RFC 5321) forbids text lines over 998 octets; base64 bodies can be
    /// arbitrarily wrapped because decoders ignore CRLF inside the data.
    private static func wrappedBase64(_ base64: String, lineLength: Int = 76) -> String {
        guard base64.count > lineLength else { return base64 }
        var lines: [String] = []
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: lineLength, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[start..<end]))
            start = end
        }
        return lines.joined(separator: "\r\n")
    }

    private static var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// Value-type snapshot of the SMTP settings, safe to cross into a detached task.
private struct SMTPServerConfig: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let recipient: String
}
