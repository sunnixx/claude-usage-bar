#if os(macOS)
import AppKit
import HeadroomCore

/// Draws one provider as a bounded card: header, a large headline percentage
/// with its context, the headline meter, then the secondary windows.
///
/// One view per provider rather than one per row. That is fewer menu items than
/// the previous layout, not more, and it means the spacing inside a card is ours
/// rather than `NSMenu`'s — which is the whole reason the old version looked
/// cramped.
///
/// The fill is deliberately faint. `NSMenu` draws a vibrant, translucent
/// backdrop, and an opaque card sitting on it reads as a heavy patch; a very low
/// alpha lets the vibrancy through so the card reads as a grouping rather than a
/// panel. Colours are semantic, resolved at draw time, so light and dark follow
/// the system.
final class ProviderCardView: NSView {
    private enum Metric {
        static let cardInsetX: CGFloat = 9
        static let cardInsetY: CGFloat = 5
        static let padX: CGFloat = 12
        static let corner: CGFloat = 9

        static let headerHeight: CGFloat = 26
        static let heroHeight: CGFloat = 40
        static let meterHeight: CGFloat = 5
        static let meterGap: CGFloat = 9
        static let rowHeight: CGFloat = 22
        static let messageHeight: CGFloat = 26
        static let bottomPad: CGFloat = 10
        static let rowMeterWidth: CGFloat = 54
        static let percentWidth: CGFloat = 38
        static let markSize: CGFloat = 12
    }

    private static let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let planFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    private static let statusFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    private static let heroFont = NSFont.systemFont(ofSize: 30, weight: .semibold)
    private static let heroUnitFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    private static let contextFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    private static let rowFont = NSFont.menuFont(ofSize: 12)
    private static let rowPercentFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let messageFont = NSFont.menuFont(ofSize: 12)

    private let section: ProviderSection

    init(section: ProviderSection, width: CGFloat) {
        self.section = section
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(of: section)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The width every card shares, so the two never differ. Measured from the
    /// longest secondary label rather than hardcoded — model names come from the
    /// API and a long one would otherwise clip.
    static func width(for sections: [ProviderSection]) -> CGFloat {
        func measure(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        // The widest row: label, meter, percentage.
        let rowContent = sections.reduce(CGFloat(0)) { widest, section in
            section.others.reduce(widest) { inner, row in
                let indent: CGFloat = row.isIndented ? 12 : 0
                return max(inner, indent + measure(row.label, rowFont))
            }
        } + 10 + Metric.rowMeterWidth + 8 + Metric.percentWidth

        // The widest header: mark, name, optional plan pill, then the status
        // pushed right. Measured too, because the status can carry a whole
        // condition ("Rate limited · last updated 06:40") and would otherwise
        // collide with the provider name.
        let headerContent = sections.reduce(CGFloat(0)) { widest, section in
            var width = Metric.markSize + 7 + measure(section.provider.displayName, nameFont) + 8
            if let plan = section.planName {
                width += measure(plan, planFont) + 12 + 8
            }
            if let status = section.status {
                width += measure(status, statusFont) + 12
            }
            return max(widest, width)
        }

        let content = max(rowContent, headerContent)
        return max(content + (Metric.padX + Metric.cardInsetX) * 2, 260)
    }

    static func height(of section: ProviderSection) -> CGFloat {
        var height = Metric.cardInsetY * 2 + Metric.headerHeight + Metric.bottomPad
        if section.hero != nil {
            height += Metric.heroHeight + Metric.meterHeight + Metric.meterGap
        }
        height += CGFloat(section.others.count) * Metric.rowHeight
        if section.message != nil { height += Metric.messageHeight }
        return height
    }

    private func tint(_ percent: Int) -> NSColor {
        switch Formatting.severity(for: percent) {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: Metric.cardInsetX, dy: Metric.cardInsetY)
        let path = NSBezierPath(roundedRect: card, xRadius: Metric.corner, yRadius: Metric.corner)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        let left = card.minX + Metric.padX
        let right = card.maxX - Metric.padX
        var y = card.maxY

        y -= Metric.headerHeight
        drawHeader(in: NSRect(x: left, y: y, width: right - left, height: Metric.headerHeight))

        if let hero = section.hero {
            y -= Metric.heroHeight
            drawHero(hero, in: NSRect(x: left, y: y, width: right - left, height: Metric.heroHeight))
            y -= Metric.meterGap + Metric.meterHeight
            drawMeter(
                percent: hero.percent ?? 0,
                in: NSRect(x: left, y: y, width: right - left, height: Metric.meterHeight)
            )
        }

        for row in section.others {
            y -= Metric.rowHeight
            drawRow(row, in: NSRect(x: left, y: y, width: right - left, height: Metric.rowHeight))
        }

        if let message = section.message {
            y -= Metric.messageHeight
            draw(
                message, font: Self.messageFont, color: .secondaryLabelColor,
                in: NSRect(x: left, y: y, width: right - left, height: Metric.messageHeight)
            )
        }
    }

    private func drawHeader(in rect: NSRect) {
        var x = rect.minX

        let mark = ProviderMark.image(for: section.provider)
        let markRect = NSRect(
            x: x, y: rect.midY - Metric.markSize / 2,
            width: Metric.markSize, height: Metric.markSize
        )
        // Template images carry no colour of their own; tint to the label colour
        // so the mark tracks light and dark like the text beside it.
        NSColor.labelColor.set()
        mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
        markRect.fill(using: .sourceAtop)
        x += Metric.markSize + 7

        let name = section.provider.displayName
        let nameSize = (name as NSString).size(withAttributes: [.font: Self.nameFont])
        draw(
            name, font: Self.nameFont, color: .labelColor,
            in: NSRect(x: x, y: rect.minY, width: nameSize.width + 2, height: rect.height)
        )
        x += nameSize.width + 8

        if let plan = section.planName {
            let planSize = (plan as NSString).size(withAttributes: [.font: Self.planFont])
            let pill = NSRect(
                x: x, y: rect.midY - 8, width: planSize.width + 12, height: 16
            )
            let pillPath = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
            NSColor.separatorColor.setStroke()
            pillPath.lineWidth = 1
            pillPath.stroke()
            draw(plan, font: Self.planFont, color: .secondaryLabelColor, in: pill, alignment: .center)
        }

        if let status = section.status {
            // Secondary, not tertiary: this line can carry a real condition
            // ("Rate limited", "Offline"), so it must read as easily as the
            // window labels rather than fading into the card.
            draw(
                status, font: Self.statusFont, color: .secondaryLabelColor,
                in: rect, alignment: .right
            )
        }
    }

    private func drawHero(_ hero: MenuRow, in rect: NSRect) {
        let number = "\(hero.percent ?? 0)"
        let numberSize = (number as NSString).size(withAttributes: [.font: Self.heroFont])
        // Baseline-align the number and its unit rather than centring both.
        let baseline = rect.minY + 6
        draw(
            number, font: Self.heroFont, color: .labelColor,
            in: NSRect(x: rect.minX, y: baseline, width: numberSize.width + 2, height: numberSize.height),
            centred: false
        )
        draw(
            "%", font: Self.heroUnitFont, color: .labelColor,
            in: NSRect(
                x: rect.minX + numberSize.width + 1, y: baseline + 3,
                width: 20, height: 18
            ),
            centred: false
        )

        var context = hero.label
        if let reset = hero.reset { context += "\n\(reset)" }
        draw(
            context, font: Self.contextFont, color: .secondaryLabelColor,
            in: NSRect(x: rect.minX + 90, y: rect.minY, width: rect.width - 90, height: rect.height),
            alignment: .right
        )
    }

    private func drawRow(_ row: MenuRow, in rect: NSRect) {
        let percent = row.percent ?? 0
        let indent: CGFloat = row.isIndented ? 12 : 0
        let percentX = rect.maxX - Metric.percentWidth
        let meterX = percentX - 8 - Metric.rowMeterWidth

        draw(
            row.label, font: Self.rowFont,
            color: row.isIndented ? .secondaryLabelColor : .labelColor,
            in: NSRect(
                x: rect.minX + indent, y: rect.minY,
                width: meterX - rect.minX - indent - 8, height: rect.height
            )
        )
        drawMeter(
            percent: percent,
            in: NSRect(
                x: meterX, y: rect.midY - Metric.meterHeight / 2,
                width: Metric.rowMeterWidth, height: Metric.meterHeight
            )
        )
        draw(
            Formatting.percentText(percent), font: Self.rowPercentFont,
            color: percent >= Formatting.criticalThreshold ? .systemRed : .labelColor,
            in: NSRect(x: percentX, y: rect.minY, width: Metric.percentWidth, height: rect.height),
            alignment: .right
        )
    }

    private func drawMeter(percent: Int, in rect: NSRect) {
        let radius = rect.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(Double(percent), 0), 100) / 100
        guard fraction > 0 else { return }
        // A non-zero reading never renders as an empty track — a sliver still
        // reads as "some usage", which nothing does not.
        let filled = NSRect(
            x: rect.minX, y: rect.minY,
            width: max(rect.width * fraction, rect.height), height: rect.height
        )
        tint(percent).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    private func draw(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in rect: NSRect,
        alignment: NSTextAlignment = .left,
        centred: Bool = true
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.lineSpacing = 1

        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        guard centred else {
            attributed.draw(in: rect)
            return
        }
        let height = attributed.boundingRect(
            with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        attributed.draw(
            in: NSRect(
                x: rect.minX, y: rect.minY + (rect.height - height) / 2,
                width: rect.width, height: height
            )
        )
    }
}
#endif
