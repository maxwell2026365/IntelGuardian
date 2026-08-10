import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Renders a line chart to PNG for embedding in alert emails. Uses CoreGraphics
/// directly so output is deterministic and every point carries its time/value
/// label. This works in every email client — including Gmail, which strips
/// inline SVG and would otherwise leave only the raw coordinate text.
@MainActor
enum EmailChartRenderer {
    static func render(samples: [ThermalSample], series: [(Date, Double)], color: (Double, Double, Double), title: String, yMin: Double, yMax: Double) -> Data? {
        let width: CGFloat = 640
        let height: CGFloat = 320
        let padLeft: CGFloat = 52
        let padRight: CGFloat = 20
        let padTop: CGFloat = 40
        let padBottom: CGFloat = 46

        // Downsample to at most 12 points so labels stay readable.
        var pts = series
        if pts.count > 12 {
            var sampled: [(Date, Double)] = []
            let step = Double(pts.count - 1) / 11.0
            for i in 0..<12 {
                let idx = Int((Double(i) * step).rounded())
                sampled.append(pts[min(idx, pts.count - 1)])
            }
            pts = sampled
        }
        guard !pts.isEmpty else { return nil }

        let innerW = width - padLeft - padRight
        let innerH = height - padTop - padBottom
        let timeRange = max(pts.last!.0.timeIntervalSince(pts.first!.0), 1)
        let valueRange = max(yMax - yMin, 0.0001)

        func px(_ d: Date) -> CGFloat { padLeft + CGFloat(d.timeIntervalSince(pts.first!.0) / timeRange) * innerW }
        func py(_ v: Double) -> CGFloat { padTop + CGFloat(1 - (v - yMin) / valueRange) * innerH }

        let renderBlock: (CGContext) -> Void = { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            // Title.
            let titleText = title as NSString
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.font(size: 14, bold: true),
                .foregroundColor: Self.color(0.1, 0.1, 0.12, 1),
            ]
            let titleSize = titleText.size(withAttributes: titleAttrs)
            titleText.draw(at: CGPoint(x: (width - titleSize.width) / 2, y: 12), withAttributes: titleAttrs)

            // Horizontal grid + y labels.
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "HH:mm"
            for i in 0...4 {
                let gy = padTop + innerH * CGFloat(i) / 4
                let val = yMax - (yMax - yMin) * Double(i) / 4
                ctx.setStrokeColor(CGColor(gray: 0.9, alpha: 1))
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: padLeft, y: gy))
                ctx.addLine(to: CGPoint(x: width - padRight, y: gy))
                ctx.strokePath()

                let label = String(format: "%.0f", val) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Self.font(size: 10, bold: false),
                    .foregroundColor: Self.color(0.55, 0.55, 0.58, 1),
                ]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: padLeft - size.width - 6, y: gy - size.height / 2), withAttributes: attrs)
            }

            // x time labels.
            for i in 0...4 {
                let frac = Double(i) / 4
                let tx = padLeft + innerW * CGFloat(frac)
                let d = pts.first!.0.addingTimeInterval(timeRange * frac)
                let label = dateFmt.string(from: d) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Self.font(size: 10, bold: false),
                    .foregroundColor: Self.color(0.55, 0.55, 0.58, 1),
                ]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: tx - size.width / 2, y: padTop + innerH + 10), withAttributes: attrs)
            }

            // Line.
            let linePath = CGMutablePath()
            for (i, p) in pts.enumerated() {
                let point = CGPoint(x: px(p.0), y: py(p.1))
                if i == 0 { linePath.move(to: point) } else { linePath.addLine(to: point) }
            }
            ctx.setStrokeColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            ctx.setLineWidth(2.5)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.addPath(linePath)
            ctx.strokePath()

            // Points + coordinate labels.
            for p in pts {
                let point = CGPoint(x: px(p.0), y: py(p.1))
                // White fill + colored ring so points read against the line.
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                ctx.setStrokeColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))

                let label = "\(dateFmt.string(from: p.0))  \(String(format: "%.1f", p.1))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Self.font(size: 10, bold: true),
                    .foregroundColor: Self.color(0.15, 0.15, 0.18, 1),
                ]
                let size = label.size(withAttributes: attrs)
                var lx = point.x - size.width / 2
                lx = min(max(lx, padLeft), width - padRight - size.width)
                var ly = point.y - size.height - 6
                ly = max(ly, padTop - 2)
                // Small white backing so labels stay readable over the line.
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.75))
                ctx.fill(CGRect(x: lx - 2, y: ly - 1, width: size.width + 4, height: size.height + 2))
                label.draw(at: CGPoint(x: lx, y: ly), withAttributes: attrs)
            }
        }

        #if os(macOS)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        renderBlock(ctx)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
        #else
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            renderBlock(ctx.cgContext)
        }
        return image.pngData()
        #endif
    }

    // MARK: - Platform font/color helpers

    #if canImport(AppKit)
    private static func font(size: CGFloat, bold: Bool) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }
    #else
    private static func font(size: CGFloat, bold: Bool) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .regular
        return UIFont.systemFont(ofSize: size, weight: weight)
    }
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a)
    }
    #endif
}
