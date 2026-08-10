import AppKit

enum MeterIcon {
    struct Entry {
        let percent: Double?
        let color: NSColor

        /// A configured provider whose last fetch failed: keep its column so the
        /// icon does not reflow, but show it as unknown rather than as 0%.
        static func unknown() -> Entry { Entry(percent: nil, color: .tertiaryLabelColor) }
    }

    /// One column per provider.
    ///
    /// A single aggregated number was useless in practice: any provider sitting at
    /// 100% for days pinned the whole icon to 100% and hid every other service.
    /// Columns keep each provider independently visible, and the width tracks how
    /// many providers are actually configured — two providers must not leave a
    /// gap where the other two would be.
    static func image(entries: [Entry]) -> NSImage {
        guard !entries.isEmpty else { return placeholder() }

        let count = entries.count
        let barWidth: CGFloat = count <= 2 ? 5 : (count <= 4 ? 4 : 3)
        let gap: CGFloat = count <= 4 ? 3 : 2
        let trackHeight: CGFloat = 13
        let width = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        let height: CGFloat = 18
        let top = (height - trackHeight) / 2

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for (index, entry) in entries.enumerated() {
                let x = CGFloat(index) * (barWidth + gap)
                let track = CGRect(x: x, y: top, width: barWidth, height: trackHeight)
                context.setFillColor(NSColor.labelColor.withAlphaComponent(0.22).cgColor)
                context.addPath(CGPath(roundedRect: track, cornerWidth: barWidth / 2,
                                       cornerHeight: barWidth / 2, transform: nil))
                context.fillPath()

                guard let percent = entry.percent else {
                    // Unknown: a dot at the base reads as "no reading", not "empty".
                    let dot = CGRect(x: x, y: top + trackHeight - barWidth, width: barWidth, height: barWidth)
                    context.setFillColor(entry.color.withAlphaComponent(0.55).cgColor)
                    context.addPath(CGPath(roundedRect: dot, cornerWidth: barWidth / 2,
                                           cornerHeight: barWidth / 2, transform: nil))
                    context.fillPath()
                    continue
                }
                let clamped = min(100, max(0, percent))
                // Keep a visible stub at 0% so an idle provider still reads as present.
                let filled = max(barWidth, trackHeight * CGFloat(clamped / 100))
                let fill = CGRect(x: x, y: top + trackHeight - filled, width: barWidth, height: filled)
                context.setFillColor(entry.color.cgColor)
                context.addPath(CGPath(roundedRect: fill, cornerWidth: barWidth / 2,
                                       cornerHeight: barWidth / 2, transform: nil))
                context.fillPath()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Nothing configured yet — a dimmed ring keeps the item findable.
    private static func placeholder() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setLineWidth(3.2)
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.3).cgColor)
            context.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: 6.5,
                           startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.strokePath()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func color(for percent: Double) -> NSColor {
        switch Severity.of(percent) {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
