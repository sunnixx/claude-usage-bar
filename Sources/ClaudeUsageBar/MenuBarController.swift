import AppKit
import ClaudeUsageCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Called when the user picks Refresh Now, or opens the menu.
    var onRefreshRequested: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var state: UsageState = .loading

    override init() {
        super.init()

        if let button = statusItem.button {
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
        statusItem.menu = menu

        render()
    }

    func update(state: UsageState) {
        self.state = state
        render()
    }

    // MARK: - Rendering

    private func render() {
        renderTitle()
        renderMenu()
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        let title = MenuModel.statusTitle(for: state)
        button.attributedTitle = NSAttributedString(
            string: " \(title.text)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: title.isCritical ? NSColor.systemRed : NSColor.labelColor,
            ]
        )
    }

    private func renderMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        for row in MenuModel.rows(
            for: state,
            now: Date(),
            calendar: .current,
            locale: .current,
            timeZone: .current
        ) {
            let item = NSMenuItem(title: row.text, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: row.isIndented ? "   └ \(row.text)" : row.text,
                attributes: [.font: font]
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: "Refresh Now",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        onRefreshRequested?()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        renderMenu()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Rebuild first so relative reset times ("in 1h 12m") are current,
        // then ask for fresh data.
        renderMenu()
        onRefreshRequested?()
    }
}
