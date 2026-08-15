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
/// called `run`: `update` either runs inline (when it is already being called
/// from that thread — see its doc comment) or hops over via `g_idle_add`.
/// The Swift importer gives every GTK opaque struct (`GtkWidget`, `GtkLabel`,
/// `GtkMenuShell`, `GtkContainer`, ...) its own distinct pointer type, even
/// though at the C level they are all just `GtkWidget*` upcasts/downcasts
/// through the GObject type hierarchy. `OpaquePointer` does not bridge
/// between them — it is a different family of pointer used for opaque
/// (non-pointee) C types. Reinterpreting through `UnsafeMutableRawPointer` is
/// the correct, and only, way to move between these typed pointers.
private func gcast<In, Out>(_ pointer: UnsafeMutablePointer<In>?) -> UnsafeMutablePointer<Out>? {
    guard let pointer else { return nil }
    return UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Out.self)
}

public final class AppIndicatorTray: TrayBackend, @unchecked Sendable {
    private var indicator: UnsafeMutablePointer<AppIndicator>?
    private var handlers: TrayHandlers?

    private let lock = NSLock()
    private var pending: TrayContent?
    private var shown: TrayContent?

    /// GTK thread only. True between the menu's "show" and "hide"/"deactivate"
    /// signals — i.e. while it is actually open on screen. Guards `render()`
    /// against swapping the `GtkMenu` out from under itself; see the guard
    /// there.
    private var isMenuOpen = false
    /// GTK thread only. Set alongside `isMenuOpen = true`; used by
    /// `applyPending()`'s watchdog to tell how long the menu has been open.
    /// This environment cannot verify that "hide"/"deactivate" ever fire on
    /// a real DBusMenu host (see the UNVERIFIED note on "show" in `render()`)
    /// — if they simply never do, `isMenuOpen` would otherwise stay true
    /// forever, permanently freezing the dropdown rows at whatever content
    /// was `shown` when it was last open, even though the label/icon keep
    /// updating. That is a silent, permanent functional regression, not a
    /// crash and not wrong data, but with no other symptom that would ever
    /// surface it. Two base poll intervals (this tray has no visibility into
    /// `UsageRefreshPolicy`'s current, possibly backed-off interval — see
    /// `staleMenuOpenThreshold`) is long enough that a real, brief menu
    /// session never trips it, but short enough that a stuck flag clears
    /// itself well within a user's next glance at the tray.
    private var menuOpenSince: Date?
    /// GTK thread only. Set when `render()` is asked to rebuild while
    /// `isMenuOpen` is true; consumed by `menuDidClose()` once the menu
    /// actually closes (or by the watchdog in `applyPending()`, if it
    /// doesn't).
    private var menuNeedsRebuild = false
    /// Watchdog threshold for `menuOpenSince`; see its doc comment. Not tied
    /// to the driver's actual poll interval (this class has no reference to
    /// `UsageRefreshPolicy`) — a fixed multiple of the base interval, chosen
    /// to be generous rather than exact, since this is a safety valve of
    /// last resort, not a precisely-timed mechanism.
    private static let staleMenuOpenThreshold: TimeInterval = 120

    public init() {}

    /// The thread that calls `run` and drives `gtk_main()`. Recorded so
    /// `update` can tell whether it is already executing there (e.g. called
    /// synchronously from a GTK signal handler on this same thread) versus
    /// from the background poll task, without relying on `Thread.isMainThread`
    /// meaning "the GTK thread" by coincidence.
    private var gtkThread: Thread?

    public func run(handlers: TrayHandlers) -> Never {
        self.handlers = handlers
        gtkThread = Thread.current

        var argc: Int32 = 0
        // gtk_init() aborts the process outright (exit(1)) on failure, with
        // only GTK's own unattributed "cannot open display" warning on
        // stderr — nothing naming this app, and no chance for us to add
        // context. gtk_init_check() instead reports failure so we can say
        // something a user (or a bug report) can actually act on.
        guard gtk_init_check(&argc, nil) != 0 else {
            FileHandle.standardError.write(Data(
                """
                claude-usage-bar: gtk_init_check failed — no display available. \
                Is a graphical session running, and is DISPLAY or \
                WAYLAND_DISPLAY set in this process's environment?\n
                """.utf8
            ))
            exit(1)
        }

        guard let newIndicator = app_indicator_new(
            "claude-usage-bar",
            "utilities-system-monitor",
            APP_INDICATOR_CATEGORY_APPLICATION_STATUS
        ) else {
            // Undocumented failure mode, but nothing rules it out, and the
            // silent alternative — the process runs forever with no tray and
            // no error — is worse than exiting loudly.
            FileHandle.standardError.write(Data(
                "claude-usage-bar: app_indicator_new returned NULL — could not create the tray indicator.\n".utf8
            ))
            exit(1)
        }
        indicator = newIndicator

        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
        app_indicator_set_title(indicator, "Claude usage")

        applyPending()
        gtk_main()
        // gtk_main() returns — it does not run forever — precisely because
        // the Quit menu item calls gtk_main_quit(), whose entire job is to
        // make it return. Unlike NSApplication.terminate(_:) on macOS, which
        // genuinely never returns, falling through here is the NORMAL,
        // expected path for a user-initiated quit, not a failure: a
        // fatalError() here would trap on every single Quit, producing a
        // crash report (and, on Ubuntu with apport, a "closed unexpectedly"
        // dialog) for completely ordinary use.
        exit(0)
    }

    public func update(_ content: TrayContent) {
        lock.lock()
        pending = content
        lock.unlock()

        // Drain inline when already running on the GTK thread — notably when
        // `update` is invoked synchronously from within a GTK signal handler
        // (the menu's forced republish on open, wired below). Deferring with
        // g_idle_add in that case would queue the rebuild to run AFTER GTK
        // has already finished reading the stale menu for display — the same
        // stale-menu-on-open bug that was fixed on the AppKit backend by
        // draining inline on the main thread instead of dispatching. Off the
        // GTK thread (the background poll task), keep hopping over via
        // g_idle_add, which is non-blocking and cannot re-enter the driver
        // synchronously, satisfying the TrayBackend.update contract.
        if Thread.current === gtkThread {
            applyPending()
            return
        }

        // The retained pointer is balanced by the takeRetainedValue in the
        // callback below. g_idle_add itself does not invoke the callback
        // synchronously — it only schedules it on the default main context,
        // which the GTK thread drains via gtk_main() — so this branch also
        // cannot block or re-enter the driver.
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

        // Watchdog: we do not trust `isMenuOpen` indefinitely, because we
        // cannot verify the "hide"/"deactivate" signals `render()` relies on
        // to clear it ever fire on a real DBusMenu host. If the deferral has
        // outlasted `staleMenuOpenThreshold`, treat the menu as closed and
        // let `render()` below rebuild it, rather than deferring forever.
        // See `menuOpenSince`'s doc comment for the full rationale.
        if isMenuOpen, let openSince = menuOpenSince,
           Date().timeIntervalSince(openSince) > Self.staleMenuOpenThreshold {
            isMenuOpen = false
            menuOpenSince = nil
        }

        render(next)
    }

    private func render(_ content: TrayContent) {
        // The label is the only place the percentage can appear; the icon is a
        // fixed themed glyph.
        app_indicator_set_label(indicator, content.title.text, "100%")

        // Never swap the menu out from under the user while it is open. The
        // "show" handler connected below fires INSIDE the very signal
        // emission that put the menu on screen, synchronously, on this same
        // thread — menuWillOpen() -> driver.publish(force:) -> update() ->
        // applyPending() -> render(), all still on the call stack when
        // "show" runs. Reaching app_indicator_set_menu from there would
        // release the menu (and the SignalBox whose closure is currently
        // executing) that GTK is still using to display the open dropdown —
        // a use-after-free, not merely the "grab risk" this was once
        // recorded as. Deferring the rebuild instead means the dropdown
        // rows can be up to one poll interval stale while the menu is open
        // — accepted deliberately, in exchange for removing a crash class
        // on a platform nobody running this review can test by hand.
        guard !isMenuOpen else {
            menuNeedsRebuild = true
            return
        }
        menuNeedsRebuild = false

        let menu = gtk_menu_new()

        for row in content.rows {
            // Pango <tt> keeps the columns aligned in a proportional menu font.
            let markup = "<tt>\(escapeMarkup(MenuModel.monospaceLine(row)))</tt>"
            let item = gtk_menu_item_new()
            let label = gtk_label_new(nil)
            gtk_label_set_markup(gcast(label), markup)
            gtk_label_set_xalign(gcast(label), 0)
            gtk_container_add(gcast(item), label)
            gtk_widget_set_sensitive(item, 0)
            gtk_menu_shell_append(gcast(menu), item)
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

        // Refresh-on-open: GTK has no signal literally named "about-to-show".
        // "show" is the closest local analogue, and is the technique other
        // GTK tray implementations use to detect a pending popup. Connected
        // AFTER gtk_widget_show_all() above, deliberately: show_all() itself
        // emits "show" on this menu synchronously, on this same thread — if
        // the handler were already connected, that call would immediately
        // invoke handlers.menuWillOpen() -> driver.publish(force: true),
        // which calls back into this very `update` while `render` (called
        // from `applyPending`, called from `update`) is still on the stack,
        // deadlocking on the driver's non-reentrant `publishLock`. Connecting
        // afterwards means only a later, real "show" emission — e.g. from
        // the tray host actually popping the menu open — reaches the
        // handler.
        //
        // UNVERIFIED: real desktops speak StatusNotifierItem to this
        // indicator over DBusMenu, not a local GTK popup, and libayatana's
        // AppIndicator API exposes no popup/about-to-open callback of its
        // own. Whether "show" actually fires on user-initiated open under a
        // real DBusMenu host (as opposed to only ever firing here, from our
        // own show_all() call, which this ordering deliberately excludes) is
        // not something this environment can observe. If it turns out not to
        // fire, refresh-on-open silently degrades to poll-interval staleness
        // — not a crash, not wrong data, just not as fresh as intended.
        connectSignal(UnsafeMutableRawPointer(menu), "show") { [weak self] in
            self?.isMenuOpen = true
            self?.menuOpenSince = Date()
            self?.handlers?.menuWillOpen()
        }

        // Both "hide" (fired when the popup is dismissed, e.g. by clicking
        // elsewhere or selecting an item) and "deactivate" (GtkMenuShell's
        // own signal for the same moment) are connected: whichever the
        // real DBusMenu host actually fires — see the UNVERIFIED note on
        // "show" above, the same uncertainty applies here — this clears
        // `isMenuOpen` and, if a poll landed while the menu was open,
        // performs the deferred rebuild now that it is safe.
        connectSignal(UnsafeMutableRawPointer(menu), "hide") { [weak self] in
            self?.menuDidClose()
        }
        connectSignal(UnsafeMutableRawPointer(menu), "deactivate") { [weak self] in
            self?.menuDidClose()
        }

        // app_indicator_set_menu releases the previous menu (g_object_unref)
        // and takes ownership of the new one (g_object_ref_sink) internally —
        // verified against libayatana-appindicator's app-indicator.c. Losing
        // the last reference to the old GtkMenu drops its child widgets too,
        // which runs the GDestroyNotify passed to g_signal_connect_data below
        // and frees the associated Box, for both the "activate" and "show"
        // handlers. So rebuilding the whole menu on every render (once a
        // minute) does not leak a widget per poll; no explicit teardown of
        // the previous menu is needed here. UNVERIFIED beyond that: whether
        // this is true end-to-end also depends on dbusmenu-gtk's mirrored
        // parse tree releasing its own references when the root menu is
        // replaced, which is a second library's ownership behavior this
        // review did not read — see the report's UNVERIFIED list.
        app_indicator_set_menu(indicator, gcast(menu))
    }

    /// GTK thread only, via the "hide"/"deactivate" signals connected in
    /// `render()`. Clears `isMenuOpen` immediately, then — if a poll landed
    /// (and was deferred by the guard in `render()`) while the menu was
    /// open — schedules the deferred rebuild via `g_idle_add` rather than
    /// calling `render()` directly from here.
    ///
    /// That indirection matters: this function runs FROM the old menu's own
    /// "hide"/"deactivate" handler, i.e. while that signal emission is still
    /// on the call stack, on the very menu `render()` would need to release
    /// via `app_indicator_set_menu`. Calling `render()` synchronously here
    /// would therefore unref the menu (and the `SignalBox` whose closure is
    /// currently executing) from inside its own emission — structurally the
    /// same use-after-free class the guard in `render()` exists to remove
    /// from "show", just relocated to "hide"/"deactivate" instead of
    /// eliminated. It is plausibly safe in practice (GLib holds its own ref
    /// on the emitting object across a signal emission, and the menu is
    /// being dismissed rather than displayed), but relying on that would be
    /// inconsistent with why the "show" guard exists at all, on a platform
    /// this review cannot run to check either way. `g_idle_add` schedules
    /// the rebuild to run once this emission — and the whole call stack
    /// under it — has fully unwound, closing the class rather than arguing
    /// it is unlikely. The retain/release pairing mirrors `update()`'s own
    /// `g_idle_add` use above: `passRetained` here is balanced by
    /// `takeRetainedValue` in the callback, 1:1.
    private func menuDidClose() {
        isMenuOpen = false
        menuOpenSince = nil
        guard menuNeedsRebuild else { return }
        menuNeedsRebuild = false

        let box = Unmanaged.passRetained(self).toOpaque()
        g_idle_add({ raw in
            guard let raw else { return 0 }
            let tray = Unmanaged<AppIndicatorTray>.fromOpaque(raw).takeRetainedValue()
            if let content = tray.shown {
                tray.render(content)
            }
            return 0  // G_SOURCE_REMOVE — one-shot
        }, box)
    }

    private func appendSeparator(to menu: UnsafeMutablePointer<GtkWidget>?) {
        let sep = gtk_separator_menu_item_new()
        gtk_menu_shell_append(gcast(menu), sep)
    }

    private func appendAction(
        to menu: UnsafeMutablePointer<GtkWidget>?,
        title: String,
        action: @escaping () -> Void
    ) {
        let item = gtk_menu_item_new_with_label(title)
        connectSignal(UnsafeMutableRawPointer(item), "activate", action)
        gtk_menu_shell_append(gcast(menu), item)
    }

    private func appendCheck(
        to menu: UnsafeMutablePointer<GtkWidget>?,
        title: String,
        checked: Bool,
        action: @escaping () -> Void
    ) {
        let item = gtk_check_menu_item_new_with_label(title)
        gtk_check_menu_item_set_active(gcast(item), checked ? 1 : 0)
        connectSignal(UnsafeMutableRawPointer(item), "activate", action)
        gtk_menu_shell_append(gcast(menu), item)
    }

    /// Holds a Swift closure so it can cross the C boundary as a raw pointer.
    /// Declared at class scope, not nested inside `connectSignal`, because
    /// Swift does not allow a type to be nested inside a generic function —
    /// and even without that restriction, `connectSignal` itself takes a
    /// plain `UnsafeMutableRawPointer?` rather than a generic typed pointer,
    /// sidestepping the type-inference-at-call-site problem a generic
    /// version would otherwise have where the caller supplies no other
    /// context to pin down the pointee type (as at the "show" call site
    /// below, which has no typed GTK argument to infer from).
    private final class SignalBox {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    /// Bridges a capture-free Swift closure to any zero-argument GTK signal
    /// (`(GtkWidget *, gpointer) -> void` handlers — "activate" and "show"
    /// both match this shape). The box is freed by the destroy notify when
    /// the connected widget goes away. Takes a raw pointer rather than a
    /// typed one: `g_signal_connect_data`'s target-object argument only ever
    /// needs to be an opaque `gpointer` identifying the GObject, never a
    /// specific GTK subtype, so callers pass whatever typed pointer they
    /// already have via `UnsafeMutableRawPointer(_:)`.
    private func connectSignal(
        _ widget: UnsafeMutableRawPointer?,
        _ signal: String,
        _ action: @escaping () -> Void
    ) {
        let box = Unmanaged.passRetained(SignalBox(action)).toOpaque()

        g_signal_connect_data(
            widget,
            signal,
            unsafeBitCast(
                { (_: UnsafeMutableRawPointer?, data: UnsafeMutableRawPointer?) in
                    guard let data else { return }
                    Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue().action()
                } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
                to: GCallback.self
            ),
            box,
            { data, _ in
                guard let data else { return }
                Unmanaged<SignalBox>.fromOpaque(data).release()
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
