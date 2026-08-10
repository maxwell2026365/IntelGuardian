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
        let levelText = latest.map { String(format: "%.1f%%", $0.batteryLevel * 100) } ?? "N/A"
        let thermalText = latest?.thermalState?.label ?? "N/A"

        let deviceType = Self.deviceTypeName()
        let deviceUser = Self.deviceUserName()
        let chargingText: String
        if let charging = latest?.batteryLevel, charging >= 0 {
            chargingText = Self.isChargingText()
        } else {
            chargingText = "未知"
        }

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
        let subject = reason.subject

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

        func chart(for title: String, series: [(Date, Double)], colorHex: String, rgb: (Double, Double, Double), yMin: Double, yMax: Double) -> String {
            guard !series.isEmpty else { return "" }
            let innerW = chartWidth - padLeft - padRight
            let innerH = chartHeight - padTop - padBottom
            let cls = "c\(chartCounter)"
            chartCounter += 1

            // Downsample to at most 20 points evenly spread.
            var pts = series
            if pts.count > 20 {
                var sampled: [(Date, Double)] = []
                let step = Double(pts.count - 1) / 19.0
                for i in 0..<20 {
                    let idx = Int((Double(i) * step).rounded())
                    sampled.append(pts[min(idx, pts.count - 1)])
                }
                pts = sampled
            }

            let timeRange = max(pts.last!.0.timeIntervalSince(pts.first!.0), 1)
            let valueRange = max(yMax - yMin, 0.0001)

            func x(_ d: Date) -> Double { padLeft + (d.timeIntervalSince(pts.first!.0) / timeRange) * innerW }
            func y(_ v: Double) -> Double { padTop + (1 - (v - yMin) / valueRange) * innerH }

            // Smooth path (Catmull-Rom to Bezier) for the line.
            let path = Self.smoothPath(pts, x: x, y: y)

            // Area fill under the line.
            let areaPath = path + " L\(String(format: "%.1f", x(pts.last!.0))),\(padTop + innerH) L\(String(format: "%.1f", x(pts.first!.0))),\(padTop + innerH) Z"

            // Light horizontal grid lines + y tick labels.
            var grid = ""
            for i in 1...4 {
                let gy = padTop + innerH * Double(i) / 4
                let val = yMax - (yMax - yMin) * Double(i) / 4
                grid += "<line x1='\(padLeft)' y1='\(String(format: "%.1f", gy))' x2='\(chartWidth - padRight)' y2='\(String(format: "%.1f", gy))' stroke='#f0f0f0' stroke-width='1'/>"
                grid += "<text x='\(padLeft - 8)' y='\(String(format: "%.1f", gy + 3.5))' text-anchor='end' font-size='10' fill='#b0b0b0'>\(String(format: "%.0f", val))</text>"
            }

            // X-axis time ticks.
            var xTicks = ""
            let tickCount = 5
            for i in 0...tickCount {
                let frac = Double(i) / Double(tickCount)
                let tickDate = pts.first!.0.addingTimeInterval(timeRange * frac)
                let tx = padLeft + innerW * frac
                let label = Self.timeFormatter.string(from: tickDate)
                xTicks += "<text x='\(String(format: "%.1f", tx))' y='\(padTop + innerH + 18)' text-anchor='middle' font-size='10' fill='#b0b0b0'>\(label)</text>"
            }

            let baseline = "<line x1='\(padLeft)' y1='\(padTop + innerH)' x2='\(chartWidth - padRight)' y2='\(padTop + innerH)' stroke='#e2e2e2' stroke-width='1'/>"

            // Each point = hot-zone group: big transparent circle for hover,
            // visible dot, and a hidden tooltip that appears on hover.
            var dots = ""
            for (i, p) in pts.enumerated() {
                let cx = String(format: "%.1f", x(p.0))
                let cy = String(format: "%.1f", y(p.1))
                let timeLabel = Self.timeFormatter.string(from: p.0)
                let valLabel = String(format: "%.1f", p.1)
                let tooltip = "\(timeLabel)  \(valLabel)"

                let visible = i == pts.count - 1
                let r = visible ? "5" : "3"
                let strokeW = visible ? "2.5" : "2"

                // Clamp tooltip position so it stays inside the SVG.
                let tipX = min(max(Double(cx)!, 46), chartWidth - 46)
                let tipY = max(Double(cy)! - 14, 12)
                let tipW = 92.0
                let tipH = 22.0

                dots += """
                <g class="dp-\(cls)" style="cursor:pointer;">
                  <circle cx="\(cx)" cy="\(cy)" r="13" fill="transparent"/>
                  <circle cx="\(cx)" cy="\(cy)" r="\(r)" fill="\(visible ? colorHex : "#ffffff")" stroke="\(colorHex)" stroke-width="\(strokeW)">
                    <title>\(tooltip)</title>
                  </circle>
                  <g class="tip-\(cls)">
                    <rect x="\(String(format: "%.1f", tipX - tipW / 2))" y="\(String(format: "%.1f", tipY - tipH / 2))" width="\(tipW)" height="\(tipH)" rx="5" fill="#333"/>
                    <text x="\(String(format: "%.1f", tipX))" y="\(String(format: "%.1f", tipY + 1))" text-anchor="middle" font-size="10.5" font-weight="600" fill="#fff">\(timeLabel)  \(valLabel)</text>
                  </g>
                </g>
                """
            }

            let svg = """
            <svg width="\(Int(chartWidth))" height="\(Int(chartHeight))" viewBox="0 0 \(chartWidth) \(chartHeight)" xmlns="http://www.w3.org/2000/svg" style="position:absolute; top:0; left:0; width:100%; height:100%; background:#ffffff;">
              <defs>
                <linearGradient id="fill-\(colorHex.hashValue & 0x7fffffff)" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stop-color="\(colorHex)" stop-opacity="0.16"/>
                  <stop offset="100%" stop-color="\(colorHex)" stop-opacity="0.0"/>
                </linearGradient>
              </defs>
              \(grid)
              \(baseline)
              <path d="\(areaPath)" fill="url(#fill-\(colorHex.hashValue & 0x7fffffff))"/>
              <path d="\(path)" fill="none" stroke="\(colorHex)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
              \(dots)
              \(xTicks)
            </svg>
            """

            // PNG fallback so clients that strip SVG (Gmail) still see the chart.
            let pngData = EmailChartRenderer.render(
                samples: samples,
                series: series,
                color: rgb,
                title: title,
                yMin: yMin,
                yMax: yMax
            )
            let pngB64 = pngData?.base64EncodedString() ?? ""

            return """
            <div style="margin:14px 0; background:#ffffff; border:1px solid #ececec; border-radius:10px; padding:14px 8px 10px 8px;">
              <style>
                .dp-\(cls) .tip-\(cls) { opacity: 0; }
                .dp-\(cls):hover .tip-\(cls) { opacity: 1; }
              </style>
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
        result += chart(
            for: "热状态（0 正常 · 1 轻微 · 2 严重 · 3 临界）",
            series: samples.compactMap { s in s.thermalStateRaw.map { (s.timestamp, Double($0)) } },
            colorHex: "#ff9500",
            rgb: (1.0, 0.58, 0.0),
            yMin: 0, yMax: 3
        )
        #else
        result += chart(
            for: "CPU 温度 (°C)",
            series: samples.compactMap { s in s.cpuTemp.map { (s.timestamp, $0) } },
            colorHex: "#ff3b30",
            rgb: (1.0, 0.23, 0.19),
            yMin: 0, yMax: 120
        )
        result += chart(
            for: "电池温度 (°C)",
            series: samples.compactMap { s in s.batteryTemp.map { (s.timestamp, $0) } },
            colorHex: "#ff9500",
            rgb: (1.0, 0.58, 0.0),
            yMin: 0, yMax: 80
        )
        #endif
        result += chart(
            for: "电量 (%)",
            series: samples.map { ($0.timestamp, $0.batteryLevel * 100) },
            colorHex: "#007aff",
            rgb: (0.0, 0.48, 1.0),
            yMin: 0, yMax: 100
        )
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
