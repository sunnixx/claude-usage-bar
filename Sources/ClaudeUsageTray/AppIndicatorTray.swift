#if os(Linux)
import CAppIndicator
import ClaudeUsageCore
import Foundation

/// Linux tray via libayatana-appindicator, which speaks StatusNotifierItem with
/// an XEmbed fallback — so KDE, XFCE, Cinnamon, MATE and Budgie work. Vanilla
/// GNOME needs the AppIndicator extension; that is true of every tray app and
/// is not this app's to fix.
///
/// GTK is not thread-safe. Every call into GTK below happens on the thread that
/// called `run`, and `update` reaches it only through `g_idle_add`.
public final class AppIndicatorTray: TrayBackend, @unchecked Sendable {
    private var indicator: UnsafeMutablePointer<AppIndicator>?
    private var handlers: TrayHandlers?

    private let lock = NSLock()
    private var pending: TrayContent?
    private var shown: TrayContent?

    public init() {}

    public func run(handlers: TrayHandlers) -> Never {
        self.handlers = handlers

        var argc: Int32 = 0
        gtk_init(&argc, nil)

        indicator = app_indicator_new(
            "claude-usage-bar",
            "utilities-system-monitor",
            APP_INDICATOR_CATEGORY_APPLICATION_STATUS
        )
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
        app_indicator_set_title(indicator, "Claude usage")

        applyPending()
        gtk_main()
        fatalError("gtk_main returned")
    }

    public func update(_ content: TrayContent) {
        lock.lock()
        pending = content
        lock.unlock()

        // Hop to the GTK thread. The retained pointer is balanced by the
        // takeRetainedValue in the callback below. g_idle_add itself does not
        // invoke the callback synchronously — it only schedules it on the
        // default main context, which the thread running gtk_main() drains —
        // so this call cannot block or re-enter the driver, satisfying the
        // TrayBackend.update contract.
        let box = Unmanaged.passRetained(self).toOpaque()
        g_idle_add({ raw in
            guard let raw else { return 0 }
            let tray = Unmanaged<AppIndicatorTray>.fromOpaque(raw).takeRetainedValue()
            tray.applyPending()
            return 0  // G_SOURCE_REMOVE — one-shot
        }, box)
    }

    // MARK: - GTK thread only

    private func applyPending() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next, next != shown else { return }
        shown = next
        render(next)
    }

    private func render(_ content: TrayContent) {
        // The label is the only place the percentage can appear; the icon is a
        // fixed themed glyph.
        app_indicator_set_label(indicator, content.title.text, "100%")

        let menu = gtk_menu_new()

        for row in content.rows {
            // Pango <tt> keeps the columns aligned in a proportional menu font.
            let markup = "<tt>\(escapeMarkup(MenuModel.monospaceLine(row)))</tt>"
            let item = gtk_menu_item_new()
            let label = gtk_label_new(nil)
            gtk_label_set_markup(OpaquePointer(label), markup)
            gtk_label_set_xalign(OpaquePointer(label), 0)
            gtk_container_add(OpaquePointer(item), label)
            gtk_widget_set_sensitive(item, 0)
            gtk_menu_shell_append(OpaquePointer(menu), item)
        }

        appendSeparator(to: menu)
        appendAction(to: menu, title: "Refresh Now") { [weak self] in
            self?.handlers?.refresh()
        }
        appendCheck(
            to: menu, title: "Launch at Login", checked: content.loginItemEnabled
        ) { [weak self] in
            self?.handlers?.toggleLoginItem()
        }
        appendSeparator(to: menu)
        appendAction(to: menu, title: "Quit") { gtk_main_quit() }

        gtk_widget_show_all(menu)
        // app_indicator_set_menu releases the previous menu (g_object_unref)
        // and takes ownership of the new one (g_object_ref_sink) internally —
        // verified against libayatana-appindicator's app-indicator.c. Losing
        // the last reference to the old GtkMenu drops its child widgets too,
        // which runs the GDestroyNotify passed to g_signal_connect_data below
        // and frees the associated Box. So rebuilding the whole menu on every
        // render (once a minute) does not leak a widget per poll; no explicit
        // teardown of the previous menu is needed here.
        app_indicator_set_menu(indicator, OpaquePointer(menu))
    }

    private func appendSeparator(to menu: UnsafeMutablePointer<GtkWidget>?) {
        let sep = gtk_separator_menu_item_new()
        gtk_menu_shell_append(OpaquePointer(menu), sep)
    }

    private func appendAction(
        to menu: UnsafeMutablePointer<GtkWidget>?,
        title: String,
        action: @escaping () -> Void
    ) {
        let item = gtk_menu_item_new_with_label(title)
        connectActivate(item, action)
        gtk_menu_shell_append(OpaquePointer(menu), item)
    }

    private func appendCheck(
        to menu: UnsafeMutablePointer<GtkWidget>?,
        title: String,
        checked: Bool,
        action: @escaping () -> Void
    ) {
        let item = gtk_check_menu_item_new_with_label(title)
        gtk_check_menu_item_set_active(OpaquePointer(item), checked ? 1 : 0)
        connectActivate(item, action)
        gtk_menu_shell_append(OpaquePointer(menu), item)
    }

    /// Bridges a Swift closure to a GTK signal. The box is freed by the
    /// destroy notify when the menu item goes away.
    private func connectActivate(
        _ item: UnsafeMutablePointer<GtkWidget>?,
        _ action: @escaping () -> Void
    ) {
        final class Box { let action: () -> Void; init(_ a: @escaping () -> Void) { action = a } }
        let box = Unmanaged.passRetained(Box(action)).toOpaque()

        g_signal_connect_data(
            OpaquePointer(item),
            "activate",
            unsafeBitCast(
                { (_: UnsafeMutableRawPointer?, data: UnsafeMutableRawPointer?) in
                    guard let data else { return }
                    Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().action()
                } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
                to: GCallback.self
            ),
            box,
            { data, _ in
                guard let data else { return }
                Unmanaged<Box>.fromOpaque(data).release()
            },
            GConnectFlags(rawValue: 0)
        )
    }

    /// Pango markup is XML; the reset strings are ASCII but the label comes
    /// from the API response, so escape rather than trust it.
    private func escapeMarkup(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
#endif
