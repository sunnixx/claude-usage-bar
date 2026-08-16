#if os(macOS)
import AppKit
import HeadroomCore

/// Draws one usage row in the dropdown: label, a rounded capsule meter tinted
/// by severity, the percentage right-aligned, and the reset time as a caption
/// beneath when there is one.
///
/// Everything is drawn rather than composed from subviews — a menu row is a
/// handful of primitives, and drawing avoids Auto Layout inside `NSMenu`,
/// which is where most custom-menu-view trouble lives. The rows are
/// non-interactive, so there is no highlight or keyboard-selection behaviour
/// to reproduce.
///
/// Colours are semantic `NSColor`s resolved at draw time, so light and dark
/// mode follow the system with no extra work.
final class UsageRowView: NSView {
    private enum Metric {
        /// Matches the text inset AppKit gives an ordinary menu item, so these
        /// rows line up with "Refresh Now" below them.
        static let leadingInset: CGFloat = 21
        static let trailingInset: CGFloat = 14
        static let indent: CGFloat = 14
        static let gap: CGFloat = 10
        static let barWidth: CGFloat = 78
        static let barHeight: CGFloat = 6
        static let percentWidth: CGFloat = 34
        static let lineHeight: CGFloat = 20
        static let captionHeight: CGFloat = 15
    }

    private static let labelFont = NSFont.menuFont(ofSize: 13)
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let captionFont = NSFont.menuFont(ofSize: 11)

    private let row: MenuRow

    init(row: MenuRow, labelColumnWidth: CGFloat) {
        self.row = row
        let height = Metric.lineHeight + (row.reset == nil ? 0 : Metric.captionHeight)
        let width = Metric.leadingInset + labelColumnWidth + Metric.gap
            + Metric.barWidth + Metric.gap + Metric.percentWidth + Metric.trailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The width the label column needs so every row's meter starts at the same
    /// x. Measured rather than hardcoded — model names come from the API and a
    /// long one would otherwise clip.
    static func labelColumnWidth(for rows: [MenuRow]) -> CGFloat {
        let widest = rows.reduce(CGFloat(0)) { widest, row in
            guard row.percent != nil else { return widest }
            let indent = row.isIndented ? Metric.indent : 0
            let size = (row.label as NSString).size(withAttributes: [.font: labelFont])
            return max(widest, indent + size.width)
        }
        // A floor keeps short-label menus from looking cramped.
        return max(widest, 96)
    }

    private var tint: NSColor {
        switch row.severity {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelX = Metric.leadingInset + (row.isIndented ? Metric.indent : 0)
        let topLineY = bounds.maxY - Metric.lineHeight

        draw(
            row.label,
            font: Self.labelFont,
            color: row.isIndented ? .secondaryLabelColor : .labelColor,
            in: NSRect(
                x: labelX, y: topLineY,
                width: bounds.maxX - Metric.trailingInset - labelX,
                height: Metric.lineHeight
            )
        )

        if let percent = row.percent {
            let percentX = bounds.maxX - Metric.trailingInset - Metric.percentWidth
            drawMeter(
                percent: percent,
                in: NSRect(
                    x: percentX - Metric.gap - Metric.barWidth,
                    y: topLineY + (Metric.lineHeight - Metric.barHeight) / 2,
                    width: Metric.barWidth,
                    height: Metric.barHeight
                )
            )
            draw(
                Formatting.percentText(percent),
                font: Self.percentFont,
                color: row.severity == .critical ? .systemRed : .labelColor,
                in: NSRect(
                    x: percentX, y: topLineY,
                    width: Metric.percentWidth, height: Metric.lineHeight
                ),
                alignment: .right
            )
        }

        if let reset = row.reset {
            draw(
                reset,
                font: Self.captionFont,
                color: .secondaryLabelColor,
                in: NSRect(
                    x: labelX, y: bounds.minY,
                    width: bounds.maxX - Metric.trailingInset - labelX,
                    height: Metric.captionHeight
                )
            )
        }
    }

    private func drawMeter(percent: Int, in rect: NSRect) {
        let radius = rect.height / 2

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(Double(percent), 0), 100) / 100
        guard fraction > 0 else { return }

        // Never let a non-zero reading render as an empty capsule — a sliver
        // still reads as "some usage", which nothing is not.
        let filledWidth = max(rect.width * fraction, rect.height)
        let filled = NSRect(x: rect.minX, y: rect.minY, width: filledWidth, height: rect.height)
        tint.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    private func draw(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in rect: NSRect,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        // Centre the glyphs vertically in the line box.
        let textHeight = attributed.size().height
        let y = rect.minY + (rect.height - textHeight) / 2
        attributed.draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: textHeight))
    }
}
#endif
