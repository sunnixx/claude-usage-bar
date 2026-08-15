#if os(macOS)
import AppKit
import ClaudeUsageCore

public final class AppKitTray: NSObject, TrayBackend, NSMenuDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var handlers: TrayHandlers?
    /// Guarded by `lock`; read on the main thread, written from the poll task.
    private var pending: TrayContent?
    private var shown: TrayContent?
    private let lock = NSLock()

    public override init() { super.init() }

    public func run(handlers: TrayHandlers) -> Never {
        self.handlers = handlers

        let app = NSApplication.shared
        // Menu bar only: no Dock icon, no app menu.
        app.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                accessibilityDescription: "Claude usage"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = image == nil ? .noImage : .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        drainPending()
        app.run()
        fatalError("NSApplication.run returned")
    }

    public func update(_ content: TrayContent) {
        lock.lock()
        pending = content
        lock.unlock()
        // Drain inline when already on the main thread — notably when this is
        // called synchronously from `menuWillOpen`, via the driver's forced
        // publish. Deferring with `DispatchQueue.main.async` in that case
        // would land the rebuild after AppKit has already populated and drawn
        // the menu, which is the stale-menu-on-open bug this exists to avoid.
        // Off the main thread (the poll task), keep hopping over as before.
        if Thread.isMainThread {
            drainPending()
        } else {
            DispatchQueue.main.async { [weak self] in self?.drainPending() }
        }
    }

    // MARK: - Main thread only

    private func drainPending() {
        // `driver.start()` (in main.swift) publishes synchronously before
        // `run()` installs `statusItem`, so `update` can call this before
        // there is anywhere to draw. Bail without consuming `pending` in
        // that case, so the content survives for `run()`'s own drain call
        // once `statusItem` exists — otherwise it is read and discarded here
        // (renderTitle/renderMenu both bail on `statusItem == nil`) and the
        // initial "Loading…" state is never shown.
        guard statusItem != nil else { return }

        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next else { return }
        // Skip the rebuild when nothing changed, so a poll landing while the
        // menu is open doesn't flicker or reset the current highlight.
        guard next != shown else { return }
        shown = next
        render(next)
    }

    private func render(_ content: TrayContent) {
        renderTitle(content.title)
        renderMenu(content)
    }

    private func renderTitle(_ title: StatusTitle) {
        guard let button = statusItem?.button else { return }
        let color: NSColor
        if title.isCritical {
            // A near-limit warning must not be softened, even while stale.
            color = .systemRed
        } else if title.isStale {
            color = .secondaryLabelColor
        } else {
            color = .labelColor
        }
        button.attributedTitle = NSAttributedString(
            string: " \(title.text)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ]
        )
    }

    private func renderMenu(_ content: TrayContent) {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        // Usage rows are drawn (label, tinted meter, percentage, reset caption);
        // message rows such as "Not signed in to Claude Code" or "Updated 13:44"
        // stay ordinary text items. One shared label-column width keeps every
        // meter starting at the same x.
        let labelColumnWidth = UsageRowView.labelColumnWidth(for: content.rows)
        for row in content.rows {
            let item = NSMenuItem(title: row.label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if row.percent == nil {
                item.attributedTitle = NSAttributedString(
                    string: row.label,
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 12),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
            } else {
                item.view = UsageRowView(row: row, labelColumnWidth: labelColumnWidth)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        launch.target = self
        launch.state = content.loginItemEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))
    }

    @objc private func refreshNow() { handlers?.refresh() }
    @objc private func toggleLogin() { handlers?.toggleLoginItem() }

    public func menuWillOpen(_ menu: NSMenu) {
        handlers?.menuWillOpen()
    }
}
#endif
