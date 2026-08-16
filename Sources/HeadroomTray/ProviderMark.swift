#if os(macOS)
import AppKit
import HeadroomCore

/// Monochrome template marks identifying each provider in the menu bar.
///
/// Drawn in code rather than bundled as brand assets: template images adapt to
/// light mode, dark mode and tinted menu bars automatically, and there is no
/// artwork to license or keep in sync. These are recognisable renditions, not
/// pixel-exact logos.
enum ProviderMark {
    /// `renderTitle` calls `image(for:)` once per configured provider on
    /// every publish — roughly twice a minute per provider, ~2,880 times a
    /// day for two providers — and the mark itself never changes once drawn.
    /// Rasterising it fresh each time was pure waste with no correctness
    /// upside, so each provider's `NSImage` is built exactly once and reused;
    /// `NSImage` is immutable after construction here (nothing ever mutates
    /// the cached instances), so sharing one across every render is safe.
    private static let images: [Provider: NSImage] = [
        .anthropic: makeImage(for: .anthropic),
        .codex: makeImage(for: .codex),
    ]

    static func image(for provider: Provider) -> NSImage {
        // Force-unwrap is safe: `images` is populated for every `Provider`
        // case above, and `Provider` is a closed enum only this module edits.
        images[provider]!
    }

    private static func makeImage(for provider: Provider) -> NSImage {
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
