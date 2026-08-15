#if os(macOS)
import AppKit
import ClaudeUsageCore

/// Monochrome template marks identifying each provider in the menu bar.
///
/// Drawn in code rather than bundled as brand assets: template images adapt to
/// light mode, dark mode and tinted menu bars automatically, and there is no
/// artwork to license or keep in sync. These are recognisable renditions, not
/// pixel-exact logos.
enum ProviderMark {
    static func image(for provider: Provider) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            switch provider {
            case .anthropic: drawAnthropic(in: rect)
            case .codex: drawCodex(in: rect)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = provider.displayName
        return image
    }

    /// Anthropic's mark: a radial burst.
    private static func drawAnthropic(in rect: NSRect) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        for spoke in 0..<6 {
            let angle = Double(spoke) * .pi / 3
            path.move(to: centre)
            path.line(to: NSPoint(
                x: centre.x + CGFloat(cos(angle)) * radius,
                y: centre.y + CGFloat(sin(angle)) * radius
            ))
        }
        path.stroke()
    }

    /// OpenAI's mark: an interlocking hexagonal knot, reduced to a hexagon ring
    /// with an inner node — legible at 14pt, where the full knot is mud.
    private static func drawCodex(in rect: NSRect) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1.4
        let ring = NSBezierPath()
        ring.lineWidth = 1.5
        ring.lineJoinStyle = .round
        for corner in 0..<6 {
            let angle = Double(corner) * .pi / 3 + .pi / 6
            let point = NSPoint(
                x: centre.x + CGFloat(cos(angle)) * radius,
                y: centre.y + CGFloat(sin(angle)) * radius
            )
            corner == 0 ? ring.move(to: point) : ring.line(to: point)
        }
        ring.close()
        ring.stroke()

        let node = radius * 0.34
        NSBezierPath(ovalIn: NSRect(
            x: centre.x - node, y: centre.y - node, width: node * 2, height: node * 2
        )).fill()
    }
}
#endif
